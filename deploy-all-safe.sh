#!/bin/bash

#------------------------------------------------------------------------------
# Proxmox Home Server Deployment Script
#
# This script automates the creation of LXC containers for various services
# and deploys them using Docker Compose.
#
# Hardware Requirements:
# - RAM: 8GB Minimum
# - Storage: 1TB (ZFS pool named VMS-ST000LM035)
# - CPU: i5 6th Gen or equivalent
#
# Network Prerequisites:
# - Proxmox Host IP: 10.0.0.20/24
# - Router/Gateway: 10.0.0.10
# - Network Bridge: vmbr0
# - Template: debian-12-standard
#------------------------------------------------------------------------------

#--- Configuration ---
# Storage and Template
STORAGE_POOL="VMS-ST000LM035"
TEMPLATE="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst" # Verify with 'pveam list local'

# Network
BRIDGE="vmbr0"
GATEWAY="10.0.0.10"
NETWORK_CIDR="24"

# Container Base Config
CPU_CORES=1
RAM_MB=1024
SWAP_MB=512
DISK_GB="8G"

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
print_msg() {
    echo -e "\n\e[1;32m>> $1\e[0m\n"
}

print_err() {
    echo -e "\n\e[1;31m!! ERROR: $1\e[0m\n"
}

#--- Core Functions ---

# Creates and configures a Docker-ready LXC container
# Arguments: $1:CT_ID, $2:Hostname, $3:IP, $4:RAM, $5:CPU, $6:Disk
create_lxc() {
    local CT_ID=$1
    local HOSTNAME=$2
    local IP_ADDRESS=$3
    local RAM=$4
    local CPU=$5
    local DISK=$6
    local IP_CIDR="$IP_ADDRESS/$NETWORK_CIDR"

    print_msg "Starting setup for $HOSTNAME (CT $CT_ID)..."

    # Check if container already exists
    if pct status $CT_ID >/dev/null 2>&1;
    then
        print_msg "Container $CT_ID ($HOSTNAME) already exists."
        read -p "Do you want to (s)kip or (d)elete and recreate it? [s/d]: " choice
        case "$choice" in
            d|D )
                print_msg "Deleting container $CT_ID..."
                pct stop $CT_ID || true
                pct destroy $CT_ID
                ;;
            * )
                print_msg "Skipping $HOSTNAME."
                return 1
                ;;
        esac
    fi

    print_msg "Creating container $HOSTNAME (CT $CT_ID)..."
    pct create $CT_ID $TEMPLATE \
        --hostname $HOSTNAME \
        --storage $STORAGE_POOL \
        --rootfs $STORAGE_POOL:$DISK \
        --cores $CPU \
        --memory $RAM \
        --swap $SWAP_MB \
        --net0 name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY \
        --onboot 1 \
        --nesting 1 \
        --keyctl 1 || { print_err "Failed to create container $CT_ID."; exit 1; }

    print_msg "Starting container and waiting for network..."
    pct start $CT_ID
    sleep 5 # Give container time to boot

    # Check network connectivity
    until pct exec $CT_ID -- ping -c 1 8.8.8.8 >/dev/null 2>&1; do
        print_msg "Waiting for network in CT $CT_ID..."
        sleep 3
    done

    print_msg "Updating container and installing dependencies..."
    pct exec $CT_ID -- apt-get update
    pct exec $CT_ID -- apt-get install -y curl sudo

    print_msg "Installing Docker and Docker Compose..."
    pct exec $CT_ID -- bash -c "curl -fsSL https://get.docker.com | sh"
    pct exec $CT_ID -- apt-get install -y docker-compose

    print_msg "Container $HOSTNAME (CT $CT_ID) is ready for Docker deployments."
    return 0
}

# Deploys a service using Docker Compose
# Arguments: $1:CT_ID, $2:Service Name
deploy_service() {
    local CT_ID=$1
    local SERVICE_NAME=$2
    local COMPOSE_DIR="/opt/$SERVICE_NAME"
    local COMPOSE_FILE_HOST="./$SERVICE_NAME/docker-compose.yml"
    local COMPOSE_FILE_GUEST="$COMPOSE_DIR/docker-compose.yml"

    print_msg "Deploying $SERVICE_NAME to CT $CT_ID..."

    if [ ! -f "$COMPOSE_FILE_HOST" ]; then
        print_err "docker-compose.yml for $SERVICE_NAME not found at $COMPOSE_FILE_HOST"
        return
    fi

    pct exec $CT_ID -- mkdir -p $COMPOSE_DIR
    pct push $CT_ID $COMPOSE_FILE_HOST $COMPOSE_FILE_GUEST

    print_msg "Running docker-compose up for $SERVICE_NAME..."
    pct exec $CT_ID -- bash -c "cd $COMPOSE_DIR && docker-compose up -d"

    print_msg "$SERVICE_NAME deployed successfully!"
}

#--- Deployment Menu ---
main_menu() {
    clear
    echo "========================================"
    echo " Proxmox Home Lab Deployment"
    echo "========================================"
    echo " 1. Deploy All Services (100-104)"
    echo " 2. Deploy Pi-hole (100)"
    echo " 3. Deploy Wireguard (101)"
    echo " 4. Deploy RustDesk (102)"
    echo " 5. Deploy Samba (103)"
    echo " 6. Deploy Nginx Proxy Manager (104)"
    echo " 7. Exit"
    echo "========================================"
    read -p "Enter your choice [1-7]: " choice

    case $choice in
        1) deploy_all ;;
        2) deploy_single 0 ;;
        3) deploy_single 1 ;;
        4) deploy_single 2 ;;
        5) deploy_single 3 ;;
        6) deploy_single 4 ;;
        7) exit 0 ;;
        *) print_err "Invalid option. Please try again." && sleep 2 ;;
    esac
}

deploy_single() {
    local service_info=(${SERVICES[$1]//;/ })
    if create_lxc "${service_info[@]}"; then
        deploy_service "${service_info[0]}" "${service_info[1]}"
    fi
    read -p "Press Enter to return to the menu..."
}

deploy_all() {
    for i in "${!SERVICES[@]}"; do
        deploy_single $i
    done
    read -p "All deployments finished. Press Enter to return to the menu..."
}

#--- Script Entry Point ---
while true; do
    main_menu
done