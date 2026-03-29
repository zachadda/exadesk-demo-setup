#!/bin/bash

# Define color variables for easier use
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
RESET="\e[0m"  # Reset to default color

# Exit immediately if a command exits with a non-zero status
set -e

# Force non-interactive mode for package installations
export DEBIAN_FRONTEND=noninteractive

# Variables
INSTALL_USER="mrexasol"
INSTALL_PASSWORD="exasol"
ADMIN_PASSWORD="Exasol123!"
C4_BINARY="/home/$INSTALL_USER/c4"
CONFIG_FILE="/home/$INSTALL_USER/config"
C4_VERSION="4.23.0"
EXASOL_VERSION="2025.2.1"
EXASOL_PACKAGE="/home/$INSTALL_USER/exasol-$EXASOL_VERSION.tar.gz"
LICENSE_FILE="/home/$INSTALL_USER/v8_unlimited_lic_2407000925.exasol_license"
#DISK_PATHS="/dev/sdb"
DISK_PATHS="/dev/nvme0n1p3 /dev/nvme0n1p4 /dev/nvme0n1p5 /dev/nvme0n1p6"

echo -e "${CYAN}=== Setting up installation user ===${RESET}"

# Check if the user already exists
if id "$INSTALL_USER" &>/dev/null; then
    echo -e "${GREEN}User '$INSTALL_USER' already exists. Skipping user creation.${RESET}"
else
    sudo adduser --gecos "" --disabled-password "$INSTALL_USER"
    echo "$INSTALL_USER:$INSTALL_PASSWORD" | sudo chpasswd
    sudo usermod -aG sudo "$INSTALL_USER"
    echo -e "${GREEN}User '$INSTALL_USER' created and added to sudo group.${RESET}"
fi

echo -e "${CYAN}=== Ensuring SSH password authentication is enabled ===${RESET}"
# Enable SSH password authentication
sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart sshd
echo -e "${GREEN}SSH password authentication enabled.${RESET}"

echo -e "${CYAN}=== Checking and preparing data disks ===${RESET}"

# Iterate over each disk in the DISK_PATHS variable and check permissions
for disk in $DISK_PATHS; do
    if [ -b "$disk" ]; then
        echo -e "${GREEN}Data disk '$disk' exists and is a block device.${RESET}"

        # Wipe the disk if it contains any data
        if ! sudo file -s "$disk" | grep -q 'data'; then
            echo -e "${YELLOW}Disk '$disk' is not raw — wiping first 100MB...${RESET}"
            sudo dd if=/dev/zero of="$disk" bs=1M count=100 status=none
            echo -e "${GREEN}Disk '$disk' wiped.${RESET}"
        else
            echo -e "${GREEN}Disk '$disk' is already raw.${RESET}"
        fi

        # Set permissions for the install user
        echo -e "${YELLOW}Setting permissions on '$disk' for the '$INSTALL_USER' user.${RESET}"
        sudo chown "$INSTALL_USER:$INSTALL_USER" "$disk"
        sudo chmod 660 "$disk"

        # Verify permissions
        echo -e "${YELLOW}Permissions set. Verifying...${RESET}"
        if ls -l "$disk" | grep -q "$INSTALL_USER"; then
            echo -e "${GREEN}Permissions are correctly set for the '$INSTALL_USER' user.${RESET}"
        else
            echo -e "${RED}Failed to set permissions for '$disk'.${RESET}"
            exit 1
        fi
    else
        echo -e "${RED}Error: Disk '$disk' does not exist or is not a block device.${RESET}"
        exit 1
    fi
done

echo -e "${CYAN}=== Ensuring SSH server is installed ===${RESET}"
if ! dpkg -l | grep -q openssh-server; then
    echo -e "${YELLOW}Installing openssh-server...${RESET}"
    sudo apt-get update
    sudo apt-get install -y openssh-server
    echo -e "${GREEN}SSH server installed.${RESET}"
else
    echo -e "${GREEN}SSH server already installed.${RESET}"
fi

echo -e "${CYAN}=== Setting up SSH keys ===${RESET}"
SSH_KEY_DIR="/home/$INSTALL_USER/.ssh"
SSH_KEY="$SSH_KEY_DIR/id_rsa"

# Create .ssh directory if it doesn't exist
sudo -u "$INSTALL_USER" mkdir -p "$SSH_KEY_DIR"
sudo chmod 700 "$SSH_KEY_DIR"

# Overwrite SSH key if it already exists
if [ -f "$SSH_KEY" ]; then
    echo -e "${YELLOW}SSH key already exists at '$SSH_KEY'. Overwriting...${RESET}"
    sudo rm -f "$SSH_KEY" "$SSH_KEY.pub"
fi

# Generate a new SSH key
echo -e "${YELLOW}Generating new SSH keys for user '$INSTALL_USER'...${RESET}"
sudo -u "$INSTALL_USER" ssh-keygen -t rsa -b 2048 -f "$SSH_KEY" -q -N ""
echo -e "${GREEN}SSH keys generated.${RESET}"

# Set permissions and ownership
sudo chmod 600 "$SSH_KEY"
sudo chown "$INSTALL_USER:$INSTALL_USER" "$SSH_KEY"
sudo chmod 644 "$SSH_KEY.pub"
sudo chown "$INSTALL_USER:$INSTALL_USER" "$SSH_KEY.pub"

# Ensure the public key is in the authorized_keys
AUTHORIZED_KEYS="$SSH_KEY_DIR/authorized_keys"
sudo -u "$INSTALL_USER" touch "$AUTHORIZED_KEYS"
sudo chmod 600 "$AUTHORIZED_KEYS"
sudo chown "$INSTALL_USER:$INSTALL_USER" "$AUTHORIZED_KEYS"

# Add public key to authorized_keys if not already present
sudo -u "$INSTALL_USER" bash -c 'grep -qxF "$(cat ~/.ssh/id_rsa.pub)" ~/.ssh/authorized_keys || cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys'

echo -e "${CYAN}=== Configuring c4 ===${RESET}"

# Navigate to the directory where `c4` is expected to exist
cd /home/$INSTALL_USER

# Check if the `c4` binary exists and is executable
if [ -f "./c4" ] && [ -x "./c4" ]; then
    echo -e "${GREEN}c4 is already installed and executable.${RESET}"
else
    # Download and install c4 using the correct URL
    echo -e "${YELLOW}c4 not found. Downloading c4...${RESET}"
    wget "https://x-up.s3.amazonaws.com/releases/c4/linux/x86_64/$C4_VERSION/c4" -O "./c4"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error downloading c4 binary.${RESET}"
        exit 1
    fi

    # Make the c4 binary executable
    chmod +x "./c4"
    echo -e "${GREEN}c4 binary downloaded and made executable.${RESET}"
fi

# Get the IP address of the VM
VM_IP=$(hostname -I | awk '{print $1}')

# Join disks into a comma-separated string for CCC_HOST_DATADISK
CCC_HOST_DATADISK=$(echo $DISK_PATHS | sed 's/ /,/g')

# Create c4 configuration file using only required parameters
sudo -u "$INSTALL_USER" bash -c "cat <<EOF > '$CONFIG_FILE'
CCC_HOST_ADDRS=$VM_IP
CCC_HOST_EXTERNAL_ADDRS=$VM_IP
CCC_HOST_IMAGE_USER=$INSTALL_USER
CCC_HOST_IMAGE_PASSWORD=$INSTALL_PASSWORD
CCC_HOST_DATADISK=$CCC_HOST_DATADISK
CCC_HOST_KEY_PAIR_FILE=id_rsa
CCC_PLAY_WORKING_COPY=@exasol-$EXASOL_VERSION
CCC_PLAY_FROM_FILE=$EXASOL_PACKAGE
CCC_PLAY_DB_PASSWORD=$ADMIN_PASSWORD
CCC_PLAY_ADMIN_PASSWORD=$ADMIN_PASSWORD
CCC_USER_PASSWORD=$ADMIN_PASSWORD
CCC_PLAY_CCC=this
EOF"

echo -e "${CYAN}=== Generating Admin UI auth key (before deploy so EXAConf picks it up) ===${RESET}"
ADMINUI_AUTH_KEY="/home/$INSTALL_USER/.ccc/adminui_auth_key"
sudo -u "$INSTALL_USER" mkdir -p "/home/$INSTALL_USER/.ccc"
sudo -u "$INSTALL_USER" openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ADMINUI_AUTH_KEY" 2>/dev/null
sudo -u "$INSTALL_USER" openssl pkey -pubout -in "$ADMINUI_AUTH_KEY" -out "${ADMINUI_AUTH_KEY}.pub" 2>/dev/null
chmod 600 "$ADMINUI_AUTH_KEY"
echo -e "${GREEN}Admin UI auth key generated.${RESET}"

echo -e "${CYAN}=== Starting Exasol deployment using local c4 binary ===${RESET}"
sudo -u "$INSTALL_USER" ./c4 host diag -i "$CONFIG_FILE"

# Run playbook using the local c4 binary
sudo -u "$INSTALL_USER" ./c4 host play -i "$CONFIG_FILE"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: c4 playbook execution failed.${RESET}"
    exit 2
fi

# Wait for deployment to finish (stage 'd' = database running)
echo -e "${YELLOW}Waiting for Exasol deployment to complete. This may take several minutes...${RESET}"

while true; do
    deployment_status=$(sudo -u "$INSTALL_USER" ./c4 ps | awk 'NR==2 { print ($9 == "d") ? "complete" : "incomplete" }')
    if [[ "$deployment_status" == "complete" ]]; then
        echo -e "${GREEN}Exasol deployment is complete!${RESET}"
        break
    else
        echo -e "${YELLOW}Exasol deployment is still in progress...${RESET}"
        sleep 30
    fi
done

echo -e "${CYAN}=== Fixing c4_cloud_command network startup order ===${RESET}"
sudo sed -i 's/After=network.target/After=network-online.target\nWants=network-online.target/' /etc/systemd/system/c4_cloud_command.service
sudo systemctl daemon-reload
echo -e "${GREEN}c4_cloud_command will now wait for network-online before starting.${RESET}"

echo -e "${CYAN}=== Upgrading c4 to bundled version ===${RESET}"

CCC_C4_BIN=$(find "/home/$INSTALL_USER/.ccc/x/u/branchr" -name 'c4' -path '*/ccc+*/bin/c4' 2>/dev/null | head -1)

if [ -n "$CCC_C4_BIN" ]; then
    cp "$CCC_C4_BIN" /tmp/c4_new && mv /tmp/c4_new /usr/local/bin/c4
    chmod +x /usr/local/bin/c4
    echo -e "${GREEN}c4 upgraded to $(/usr/local/bin/c4 version).${RESET}"
else
    echo -e "${YELLOW}Bundled c4 binary not found, keeping existing version.${RESET}"
    CCC_C4_BIN="$C4_BINARY"
fi

echo -e "${CYAN}=== Setting up Admin UI ===${RESET}"

ADMINUI_DIST=$(find "/home/$INSTALL_USER/.ccc/x/u/branchr" -path '*/dist/apps/admin' -type d 2>/dev/null | head -1)
CCC_ETC_DIR="$(dirname "$CCC_C4_BIN")/../etc"
CCC_ETC_DIR=$(realpath "$CCC_ETC_DIR" 2>/dev/null || echo "$CCC_ETC_DIR")
ADMINUI_AUTH_KEY="/home/$INSTALL_USER/.ccc/adminui_auth_key"

if [ -z "$ADMINUI_DIST" ]; then
    echo -e "${RED}Admin UI dist not found in deployed packages. Skipping Admin UI setup.${RESET}"
else
    # Link TLS certs and c4 socket from the deployed c4 etc dir
    mkdir -p "$CCC_ETC_DIR"
    ln -sf /var/lib/ccc/etc/server.crt "$CCC_ETC_DIR/server.crt"
    ln -sf /var/lib/ccc/etc/server.key "$CCC_ETC_DIR/server.key"
    ln -sf /var/lib/ccc/etc/c4_socket "$CCC_ETC_DIR/c4_socket"
    echo -e "${GREEN}TLS certs and c4 socket linked.${RESET}"

    # Generate base64-encoded SHA-512 crypt hash of admin password
    ADMINUI_HASH=$(echo "$ADMIN_PASSWORD" | "$CCC_C4_BIN" pwdhash -c -i | tr -d '\n' | base64 -w 0)
    echo -e "${GREEN}Admin password hash generated.${RESET}"

    # Write Admin UI systemd service file
    cat > /etc/systemd/system/exasol-admin-ui.service <<EOF
[Unit]
Description=Admin UI server
ConditionPathExists=$CCC_C4_BIN
PartOf=c4.service

[Service]
Type=simple
Environment=HOME=/home/$INSTALL_USER
Environment=CCC_ADMINUI_ADMIN_PASSWORD_HASH=$ADMINUI_HASH
Environment=CCC_ADMINUI_AUTH_KEY_PATH=$ADMINUI_AUTH_KEY
ExecStart=$CCC_C4_BIN admin-ui serve --ui-path $ADMINUI_DIST
TimeoutSec=0
TimeoutStopSec=2

[Install]
EOF

    systemctl daemon-reload
    systemctl restart exasol-admin-ui.service
    sleep 2

    if systemctl is-active --quiet exasol-admin-ui.service; then
        echo -e "${GREEN}Admin UI is running at https://$VM_IP:8443${RESET}"
        echo -e "${GREEN}  Username: admin  |  Password: $ADMIN_PASSWORD${RESET}"
    else
        echo -e "${RED}Admin UI failed to start. Check: journalctl -u exasol-admin-ui.service${RESET}"
    fi
fi

echo -e "${CYAN}=== Installing license ===${RESET}"
if [ -f "$LICENSE_FILE" ]; then
    PLAY_LICENSE=$(sudo find "/home/$INSTALL_USER/.ccc/play/local" -name "license.exasol_license" 2>/dev/null | head -1)
    if [ -n "$PLAY_LICENSE" ]; then
        sudo cp "$LICENSE_FILE" "$PLAY_LICENSE"
        echo -e "${GREEN}License installed (expires $(grep expiration_date "$PLAY_LICENSE" | awk -F= '{print $2}' | tr -d ' ')).${RESET}"
    else
        echo -e "${YELLOW}Could not find license path in deployment. Install license manually.${RESET}"
    fi
else
    echo -e "${YELLOW}License file not found at $LICENSE_FILE. Using default license.${RESET}"
fi

echo -e "${CYAN}=== Exasol Deployment Complete ===${RESET}"
echo -e "${GREEN}  Database IP : $VM_IP:8563${RESET}"
echo -e "${GREEN}  Admin UI    : https://$VM_IP:8443${RESET}"
echo -e "${GREEN}  Username    : admin  |  Password: $ADMIN_PASSWORD${RESET}"
