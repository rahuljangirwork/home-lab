#!/bin/bash

#------------------------------------------------------------------------------
# Proxmox Home Server Deployment Script
#
# This script automates the creation and destruction of LXC containers.
# NOTE: Configuration is hardcoded. Edit the 'Configuration' section below.
#------------------------------------------------------------------------------

#--- Configuration ---
# Set your Proxmox environment details here.
STORAGE_POOL="VMS" # IMPORTANT: Change this to your storage pool name
TEMPLATE="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst" # Verify with 'pveam list local'
BRIDGE="vmbr0"
GATEWAY="10.0.0.10"
NETWORK_CIDR="24"

#--- Service Definitions ---
# Format: "ID;Name;IP;RAM;CPU;Disk"
SERVICES=(
    "100;pihole;10.0.0.21;1024;1;8G"
    "101;wireguard;10.0.0.22;512;1;4G"
    "102;rustdesk;10.0.0.23;1024;1;8G"
    "103;samba;10.0.0.24;512;1;4G"
    "104;nginx-proxy-manager;10.0.0.25;1024;1;8G"
)

#--- Helper Functions ---
print_msg() { echo -e "\n\e[1;32m>> $1\e[0m\n"; }
print_err() { echo -e "\n\e[1;31m!! ERROR: $1\e[0m\n"; }

#--- Core Deployment Functions ---
create_lxc() {
    local CT_ID=$1 HOSTNAME=$2 IP_ADDRESS=$3 RAM=$4 CPU=$5 DISK=$6
    local IP_CIDR="$IP_ADDRESS/$NETWORK_CIDR"

    print_msg "Starting setup for $HOSTNAME (CT $CT_ID)..."
    if pct status $CT_ID &>/dev/null; then
        read -p "Container $CT_ID ($HOSTNAME) already exists. (s)kip or (d)elete and recreate? [s/d]: " c
        if [[ $c == "d" || $c == "D" ]]; then
            destroy_ct $CT_ID $HOSTNAME false
        else
            print_msg "Skipping $HOSTNAME."; return 1
        fi
    fi

    print_msg "Creating container $HOSTNAME (CT $CT_ID)..."
    pct create $CT_ID $TEMPLATE --hostname $HOSTNAME --storage $STORAGE_POOL --rootfs $STORAGE_POOL:${DISK%G} \
        --cores $CPU --memory $RAM --swap 512 --onboot 1 --unprivileged 0 \
        --net0 name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY || { print_err "Failed to create CT $CT_ID."; exit 1; }

    echo "lxc.apparmor.profile: unconfined" >> /etc/pve/lxc/${CT_ID}.conf
    print_msg "Restarting container to apply security profile..."
    pct stop $CT_ID &>/dev/null; pct start $CT_ID
    sleep 5
    until pct exec $CT_ID -- ping -c 1 8.8.8.8 &>/dev/null; do print_msg "Waiting for network..." && sleep 3; done

    print_msg "Installing Docker and dependencies..."
    pct exec $CT_ID -- apt-get update
    pct exec $CT_ID -- apt-get install -y curl sudo
    pct exec $CT_ID -- bash -c "curl -fsSL https://get.docker.com | sh"
    print_msg "Container $HOSTNAME is ready."; return 0
}

# Prepares environment files for services that need them before starting.
prepare_service_env() {
    local SERVICE_NAME=$1
    if [ "$SERVICE_NAME" == "wireguard" ]; then
        print_msg "Configuring WireGuard UI (wg-easy)..."
        local wg_host admin_pass confirm_pass
        echo "Please provide the public address for your WireGuard server."
        echo "This is the domain name or public IP that clients will use to connect."
        read -p "Enter WireGuard Host (e.g., my.domain.com or public_ip): " wg_host

        while true; do
            read -sp "Enter a password for the WireGuard web admin panel: " admin_pass; echo
            read -sp "Confirm password: " confirm_pass; echo
            [ "$admin_pass" == "$confirm_pass" ] && [ -n "$admin_pass" ] && break
            print_err "Passwords do not match or are empty. Please try again."
        done
        
        echo "WG_HOST=${wg_host}" > "./wireguard/.env"
        echo "PASSWORD=${admin_pass}" >> "./wireguard/.env"
    fi
}

deploy_service() {
    local CT_ID=$1 SERVICE_NAME=$2 COMPOSE_DIR="/opt/$SERVICE_NAME"
    print_msg "Deploying $SERVICE_NAME to CT $CT_ID..."

    # Create .env file if needed
    prepare_service_env $SERVICE_NAME

    pct exec $CT_ID -- mkdir -p $COMPOSE_DIR
    pct push $CT_ID "./$SERVICE_NAME/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml"

    # Push .env file if it was created
    if [ -f "./$SERVICE_NAME/.env" ]; then
        pct push $CT_ID "./$SERVICE_NAME/.env" "$COMPOSE_DIR/.env"
        rm "./$SERVICE_NAME/.env" # Clean up local temp file
    fi

    pct exec $CT_ID -- bash -c "cd $COMPOSE_DIR && docker compose up -d" || { print_err "Failed to deploy $SERVICE_NAME."; return 1; }

    # Post-deployment actions
    if [ "$SERVICE_NAME" == "pihole" ]; then
        print_msg "Setting Pi-hole admin password..."
        print_msg "Waiting for Pi-hole to initialize (10 seconds)..."
        sleep 10
        local new_pass confirm_pass
        while true; do
            read -sp "Enter new Pi-hole admin password: " new_pass; echo
            read -sp "Confirm new password: " confirm_pass; echo
            [ "$new_pass" == "$confirm_pass" ] && [ -n "$new_pass" ] && break
            print_err "Passwords do not match or are empty. Please try again."
        done
        pct exec $CT_ID -- docker exec pihole pihole setpassword "$new_pass" || { print_err "Failed to set Pi-hole password."; return 1; }
        print_msg "Pi-hole password has been set successfully."
    elif [ "$SERVICE_NAME" == "wireguard" ]; then
        print_msg "WireGuard UI is available at: http://10.0.0.22:51821"
    fi

    print_msg "$SERVICE_NAME deployed successfully!"
}

#--- Core Destruction Functions ---
destroy_ct() {
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
    pct destroy $CT_ID
    print_msg "$HOSTNAME (CT $CT_ID) has been destroyed."
}

#--- Menus ---
main_menu() {
    clear; echo "========================================"
    echo " Proxmox Home Lab Deployment Menu"
    echo "========================================"
    echo " 1. Deploy All Services"
    echo " 2. Deploy Pi-hole (100)"
    echo " 3. Deploy Wireguard (101)"
    echo " 4. Deploy RustDesk (102)"
    echo " 5. Deploy Samba (103)"
    echo " 6. Deploy Nginx Proxy Manager (104)"
    echo " ----------------------------------------"
    echo " 7. Destroy Services..."
    echo " 8. Exit"
    echo "========================================"
    read -p "Enter your choice [1-8]: " choice
    case $choice in
        1) deploy_all;; 2) deploy_single 0;; 3) deploy_single 1;; 4) deploy_single 2;;
        5) deploy_single 3;; 6) deploy_single 4;; 7) destroy_menu;; 8) exit 0;; 
        *) print_err "Invalid option." && sleep 2;; 
    esac
}

deploy_single() { local i=(${SERVICES[$1]//;/ }); if create_lxc "${i[@]}"; then deploy_service "${i[0]}" "${i[1]}"; fi; read -p "Press Enter..." ;}
deploy_all() { for i in "${!SERVICES[@]}"; do deploy_single $i; done; read -p "Press Enter..."; }

destroy_menu() {
    clear; echo "========================================"
    echo " Destroy Services Menu"
    echo "========================================"
    echo " 1. Destroy Pi-hole (100)"
    echo " 2. Destroy Wireguard (101)"
    echo " 3. Destroy RustDesk (102)"
    echo " 4. Destroy Samba (103)"
    echo " 5. Destroy Nginx Proxy Manager (104)"
    echo " 6. Destroy ALL Services"
    echo " 7. Back to Main Menu"
    echo "========================================"
    read -p "Enter your choice [1-7]: " choice
    case $choice in
        1|2|3|4|5) local i=(${SERVICES[$((choice-1))]//;/ }); destroy_ct "${i[0]}" "${i[1]}";;
        6) read -p "Destroy ALL services? This is IRREVERSIBLE. [y/N]: " c
           [[ $c == "y" || $c == "Y" ]] && for i in "${!SERVICES[@]}"; do local j=(${SERVICES[$i]//;/ }); destroy_ct "${j[0]}" "${j[1]}" false; done;; 
        7) return;; 
        *) print_err "Invalid option." && sleep 2;; 
    esac
    read -p "Press Enter to return..."
}

#--- Script Entry Point ---
while true; do main_menu; done