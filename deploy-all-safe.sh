#!/bin/bash

#------------------------------------------------------------------------------
# Proxmox Home Server Deployment Script (Public Version)
#
# This script automates the creation and destruction of LXC containers for
# various services, deploying them using Docker Compose. It auto-detects
# system settings and prompts for user credentials to avoid hardcoded secrets.
#------------------------------------------------------------------------------

#--- Helper Functions ---
print_msg() { echo -e "\n\e[1;32m>> $1\e[0m\n"; }
print_err() { echo -e "\n\e[1;31m!! ERROR: $1\e[0m\n"; }

#--- Auto-detection and Configuration ---
detect_storage() {
    print_msg "Detecting storage pools..."
    mapfile -t pools < <(pvesm status -content rootdir --output-format=json | grep -oP '"storage":\s*"\K[^"].*')
    if [ ${#pools[@]} -eq 0 ]; then
        print_err "No suitable storage pool found for containers."
        exit 1
    elif [ ${#pools[@]} -eq 1 ]; then
        STORAGE_POOL=${pools[0]}
        print_msg "Auto-selected storage pool: $STORAGE_POOL"
    else
        echo "Please select a storage pool:"; select pool in "${pools[@]}"; do
            [[ -n $pool ]] && { STORAGE_POOL=$pool; break; } || echo "Invalid selection."
        done
    fi
}

detect_template() {
    print_msg "Detecting Debian 12 template..."
    mapfile -t templates < <(pveam list local --output-format=json | grep -oP '"volid":\s*"\K[^"].*debian-12-standard.*')
    if [ ${#templates[@]} -eq 0 ]; then
        print_err "No Debian 12 template found. Run: pveam download local debian-12-standard"
        exit 1
    fi
    TEMPLATE=${templates[0]}
    print_msg "Auto-selected template: $TEMPLATE"
}

detect_network() {
    print_msg "Detecting network settings..."
    if [ -f /etc/network/interfaces ]; then
        BRIDGE=$(grep -oP '^iface\s+\K(vmbr[0-9]+)' /etc/network/interfaces | head -n1)
        GATEWAY=$(grep -oP '^\s+gateway\s+\K([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)' /etc/network/interfaces | head -n1)
    fi
    BRIDGE=${BRIDGE:-vmbr0}
    GATEWAY=${GATEWAY:-10.0.0.10} # Fallback
    NETWORK_CIDR="24"
    print_msg "Using Bridge: $BRIDGE, Gateway: $GATEWAY"
}

#--- Service and System Configuration ---
initialize_config() {
    detect_storage
    detect_template
    detect_network
    SERVICES=(
        "100;pihole;10.0.0.21;1024;1;8G"
        "101;wireguard;10.0.0.22;512;1;4G"
        "102;rustdesk;10.0.0.23;1024;1;8G"
        "103;samba;10.0.0.24;512;1;4G"
        "104;nginx-proxy-manager;10.0.0.25;1024;1;8G"
    )
}

#--- Core Deployment Functions ---
create_lxc() {
    local CT_ID=$1 HOSTNAME=$2 IP_ADDRESS=$3 RAM=$4 CPU=$5 DISK=$6
    local IP_CIDR="$IP_ADDRESS/$NETWORK_CIDR"
    print_msg "Starting setup for $HOSTNAME (CT $CT_ID)..."
    if pct status $CT_ID &>/dev/null; then
        read -p "Container $CT_ID ($HOSTNAME) already exists. (s)kip or (d)elete and recreate? [s/d]: " c
        if [[ $c == "d" || $c == "D" ]]; then
            destroy_single_ct $CT_ID $HOSTNAME false
        else
            print_msg "Skipping $HOSTNAME."; return 1
        fi
    fi
    print_msg "Creating container $HOSTNAME (CT $CT_ID)..."
    pct create $CT_ID $TEMPLATE --hostname $HOSTNAME --storage $STORAGE_POOL --rootfs $STORAGE_POOL:$DISK \
        --cores $CPU --memory $RAM --swap 512 --onboot 1 --nesting 1 --keyctl 1 \
        --net0 name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY || { print_err "Failed to create CT $CT_ID."; exit 1; }
    pct start $CT_ID && sleep 5
    until pct exec $CT_ID -- ping -c 1 8.8.8.8 &>/dev/null; do print_msg "Waiting for network..." && sleep 3; done
    print_msg "Installing Docker and dependencies..."
    pct exec $CT_ID -- apt-get update &>/dev/null
    pct exec $CT_ID -- apt-get install -y curl sudo docker-compose &>/dev/null
    pct exec $CT_ID -- bash -c "curl -fsSL https://get.docker.com | sh" &>/dev/null
    print_msg "Container $HOSTNAME is ready."; return 0
}

prepare_service_env() {
    local SERVICE_NAME=$1 ENV_FILE="./$SERVICE_NAME/.env"
    case $SERVICE_NAME in
        pihole) read -sp "Enter a web password for Pi-hole admin: " P; echo; echo "WEBPASSWORD=${P}" > "$ENV_FILE";;
        samba) read -p "Enter a username for Samba: " U; read -sp "Enter a password for $U: " P; echo
               echo "SAMBA_USER=${U}" > "$ENV_FILE"; echo "SAMBA_PASS=${P}" >> "$ENV_FILE";;
    esac
}

deploy_service() {
    local CT_ID=$1 SERVICE_NAME=$2 COMPOSE_DIR="/opt/$SERVICE_NAME"
    print_msg "Deploying $SERVICE_NAME to CT $CT_ID..."
    prepare_service_env $SERVICE_NAME
    pct exec $CT_ID -- mkdir -p $COMPOSE_DIR
    pct push $CT_ID "./$SERVICE_NAME/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml"
    if [ -f "./$SERVICE_NAME/.env" ]; then
        pct push $CT_ID "./$SERVICE_NAME/.env" "$COMPOSE_DIR/.env"
        rm "./$SERVICE_NAME/.env"
    fi
    pct exec $CT_ID -- bash -c "cd $COMPOSE_DIR && docker-compose up -d"
    print_msg "$SERVICE_NAME deployed successfully!"
}

#--- Core Destruction Functions ---
destroy_single_ct() {
    local CT_ID=$1 HOSTNAME=$2 CONFIRM=${3:-true}
    if ! pct status $CT_ID &>/dev/null; then
        print_err "Container $CT_ID ($HOSTNAME) does not exist."; return
    fi
    if $CONFIRM; then
        read -p "Are you sure you want to permanently destroy $HOSTNAME (CT $CT_ID)? [y/N]: " c
        [[ $c != "y" && $c != "Y" ]] && { print_msg "Destruction cancelled."; return; }
    fi
    print_msg "Destroying $HOSTNAME (CT $CT_ID)..."
    pct stop $CT_ID &>/dev/null || true
    pct destroy $CT_ID &>/dev/null
    print_msg "$HOSTNAME (CT $CT_ID) has been destroyed."
}

#--- Menus ---
main_menu() {
    clear; echo "========================================"
    echo " Proxmox Home Lab Deployment Menu"
    echo "========================================"
    echo " [DEPLOY]"
    for i in "${!SERVICES[@]}"; do printf " %s. Deploy %s\n" "$((i+1))" "$(echo ${SERVICES[$i]} | cut -d';' -f2)"; done
    echo " 6. Deploy ALL Services"
    echo " ----------------------------------------"
    echo " [CLEANUP]"
    echo " 7. Destroy Services..."
    echo " 8. Exit"
    echo "========================================"
    read -p "Enter your choice [1-8]: " choice
    case $choice in
        1|2|3|4|5) deploy_single $((choice-1));;
        6) deploy_all;; 
        7) destroy_menu;; 
        8) exit 0;; 
        *) print_err "Invalid option." && sleep 2;; 
    esac
}

deploy_single() { local i=(${SERVICES[$1]//;/ }); if create_lxc "${i[@]}"; then deploy_service "${i[0]}" "${i[1]}"; fi; read -p "Press Enter..." ;}
deploy_all() { for i in "${!SERVICES[@]}"; do local j=(${SERVICES[$i]//;/ }); if create_lxc "${j[@]}"; then deploy_service "${j[0]}" "${j[1]}"; fi; done; read -p "Press Enter..."; }

destroy_menu() {
    clear; echo "========================================"
    echo " Destroy Services Menu"
    echo "========================================"
    for i in "${!SERVICES[@]}"; do printf " %s. Destroy %s\n" "$((i+1))" "$(echo ${SERVICES[$i]} | cut -d';' -f2)"; done
    echo " 6. Destroy ALL Services"
    echo " 7. Back to Main Menu"
    echo "========================================"
    read -p "Enter your choice [1-7]: " choice
    case $choice in
        1|2|3|4|5) local i=(${SERVICES[$((choice-1))]//;/ }); destroy_single_ct "${i[0]}" "${i[1]}";;
        6) read -p "Destroy ALL services? This is IRREVERSIBLE. [y/N]: " c
           [[ $c == "y" || $c == "Y" ]] && for i in "${!SERVICES[@]}"; do local j=(${SERVICES[$i]//;/ }); destroy_single_ct "${j[0]}" "${j[1]}" false; done;; 
        7) return;; 
        *) print_err "Invalid option." && sleep 2;; 
    esac
    read -p "Press Enter to return..."
}

#--- Script Entry Point ---
initialize_config
while true; do main_menu; done