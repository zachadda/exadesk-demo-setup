#!/bin/bash

# Define color variables for easier use
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
RESET="\e[0m"  # Reset to default color

#DISK_PATHS="/dev/sdb /dev/sdc /dev/sdd /dev/sde"  # Define disk paths
DISK_PATHS="/dev/nvme0n1p3 /dev/nvme0n1p4 /dev/nvme0n1p5 /dev/nvme0n1p6"

# Display title screen
echo -e "${CYAN}=============================${RESET}"
echo -e "${CYAN} Exasol Installer Setup Script${RESET}"
echo -e "${CYAN}=============================${RESET}"

# Function to retry commands
retry_command() {
    local cmd="$1"
    local retries=3
    local count=0
    until $cmd; do
        exit_code=$?
        count=$((count + 1))
        if [ $count -lt $retries ]; then
            echo -e "${YELLOW}[WARN] Command failed. Retrying ($count/$retries)...${RESET}"
            sleep 3
        else
            echo -e "${RED}[ERROR] Command failed after $retries attempts.${RESET}"
            return $exit_code
        fi
    done
    return 0
}

# System Update and Prerequisites Installation
update_system() {
    echo -e "${CYAN}=== Checking for system updates ===${RESET}"

    # Check if there are any available upgrades
    UPGRADABLE=$(sudo apt list --upgradable 2>/dev/null | grep -v "Listing...")

    if [ -z "$UPGRADABLE" ]; then
        echo -e "${GREEN}[INFO] Your system is already up to date. No upgrade needed.${RESET}"
    else
        echo -e "${CYAN}=== Updating the system ===${RESET}"
        sudo apt-get update -y
        sudo apt-get upgrade -y
    fi

    echo -e "${CYAN}=== Installing prerequisites ===${RESET}"
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release netcat wget
}

# Disable SELinux if installed
disable_selinux() {
    if command -v sestatus &> /dev/null; then
        selinux_status=$(sestatus | grep 'SELinux status' | awk '{print $3}')
        if [[ "$selinux_status" == "enabled" ]]; then
            sudo setenforce 0
            sudo sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
            echo -e "${GREEN}[INFO] SELinux has been disabled.${RESET}"
        else
            echo -e "${YELLOW}[INFO] SELinux is not enabled.${RESET}"
        fi
    else
        echo -e "${BLUE}[INFO] SELinux is not installed.${RESET}"
    fi
}

# Disable UFW and Firewalld if they are running
disable_firewall() {
    sudo systemctl stop ufw
    sudo systemctl disable ufw
    echo -e "${GREEN}[INFO] UFW has been disabled.${RESET}"

    sudo systemctl stop firewalld
    sudo systemctl disable firewalld
    echo -e "${GREEN}[INFO] Firewalld has been disabled.${RESET}"
}

# Disable common antivirus scanners
disable_antivirus() {
    sudo systemctl stop clamav-daemon
    sudo systemctl disable clamav-daemon
    echo -e "${GREEN}[INFO] ClamAV has been disabled.${RESET}"
}

# Configure NTP
configure_ntp() {
    retry_command "sudo apt-get install -y chrony"
    sudo systemctl enable chrony
    sudo systemctl start chrony
    echo -e "${GREEN}[INFO] NTP has been configured using chrony.${RESET}"
}

# Check and install Python
install_python() {
    python_version=$(python3 --version 2>&1 | awk '{print $2}')
    if [[ "$python_version" =~ ^([3-9]\.[9-9]|[4-9]\.) ]]; then
        echo -e "${YELLOW}[INFO] Compatible Python version ${python_version} is already installed globally.${RESET}"
        return 0
    fi

    if ! command -v python3 &> /dev/null; then
        echo -e "${YELLOW}[INFO] Installing the latest available Python version...${RESET}"
        retry_command "sudo apt-get install -y python3 --fix-missing"
        echo -e "${GREEN}[INFO] The latest Python version has been installed.${RESET}"
    else
        echo -e "${GREEN}[INFO] Python 3 is already installed and up to date.${RESET}"
    fi
}

# Install pip3 globally
install_pip() {
    if ! pip3 --version &> /dev/null; then
        echo -e "${YELLOW}[INFO] Installing pip3...${RESET}"
        retry_command "sudo apt-get install -y python3-pip --fix-missing"
        echo -e "${GREEN}[INFO] pip3 has been installed globally.${RESET}"
    else
        pip_version=$(pip3 --version)
        echo -e "${YELLOW}[INFO] pip3 is already installed. Version: $pip_version${RESET}"
    fi
}

# Install urwid package globally
install_urwid() {
    if ! python3 -m pip show urwid &> /dev/null; then
        echo -e "${YELLOW}[INFO] Installing urwid Python package globally...${RESET}"
        if retry_command "sudo python3 -m pip install urwid"; then
            echo -e "${GREEN}[INFO] urwid has been installed globally.${RESET}"
        else
            echo -e "${RED}[ERROR] Failed to install urwid globally.${RESET}"
            exit 1
        fi
    else
        echo -e "${YELLOW}[INFO] urwid is already installed globally.${RESET}"
    fi
}

# Install Docker if it's not already installed
install_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}[INFO] Docker not found. Installing Docker...${RESET}"

        # Add Docker's official GPG key
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/docker-archive-keyring.gpg

        # Set up the Docker repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
            https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        # Install Docker
        sudo apt-get update -y
        if sudo apt-get install -y docker-ce docker-ce-cli containerd.io; then
            # Add the user to the Docker group
            sudo usermod -aG docker "$INSTALL_USER"
            echo -e "${GREEN}[INFO] Docker installed and user '$INSTALL_USER' added to the Docker group.${RESET}"
        else
            echo -e "${RED}[ERROR] Failed to install Docker.${RESET}"
            exit 1
        fi
    else
        echo -e "${GREEN}[INFO] Docker is already installed.${RESET}"
    fi
}



# List all disks and show only their maximum sizes
check_all_disks() {
    echo -e "${MAGENTA}Listing all disks and their maximum sizes:${RESET}"

    for disk in $(lsblk -dno NAME | grep -E "^sd"); do
        max_size=$(sudo blockdev --getsize64 /dev/$disk)  # Max potential size in bytes
        max_gb=$(echo "scale=2; $max_size / 1024 / 1024 / 1024" | bc)  # Convert bytes to GiB

        echo -e "${GREEN}[INFO] Disk: /dev/$disk | Max Size: ${max_gb} GiB${RESET}"
    done
}


# Check if required files exist and make them executable
make_files_executable() {
    files=(
        "/home/exasol/install.sh"
#        "/home/exasol/exasol_gui.py"
    )

    echo -e "${CYAN}Checking for necessary files and applying chmod +x...${RESET}"

    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            echo -e "${GREEN}[INFO] Found $file. Applying chmod +x...${RESET}"
            chmod +x "$file"
            echo -e "${GREEN}[INFO] $file is now executable.${RESET}"
        else
            echo -e "${YELLOW}[WARNING] $file not found.${RESET}"
        fi
    done
}


# Configure shutdown service for Exasol
setup_shutdown_service() {
    echo -e "${CYAN}=== Configuring Exasol shutdown service ===${RESET}"
    sudo tee /usr/local/bin/exasol_shutdown.sh > /dev/null <<EOF
#!/bin/bash
if ! /usr/local/bin/c4 ps &> /dev/null; then
    echo "Exasol not running or c4 not configured."
    exit 0
fi
/usr/local/bin/c4 connect -t1/cos -- 'confd_client db_stop db_name: Exasol'
EOF
    sudo chmod +x /usr/local/bin/exasol_shutdown.sh
    sudo tee /etc/systemd/system/exasol_shutdown.service > /dev/null <<EOF
[Unit]
Description=Stop Exasol Database on Shutdown
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/exasol_shutdown.sh

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable exasol_shutdown.service
    echo -e "${GREEN}[INFO] Shutdown service configured.${RESET}"
}

# Main script logic
echo -e "${CYAN}=============================${RESET}"
echo -e "${CYAN} Starting automated setup...${RESET}"
echo -e "${CYAN}=============================${RESET}"

update_system
disable_selinux
disable_firewall
disable_antivirus
configure_ntp
install_python
install_pip
#install_urwid
install_docker
check_all_disks
#make_files_executable
#setup_automatic_login
setup_shutdown_service

echo -e "${CYAN}=============================${RESET}"
echo -e "${GREEN} All steps completed successfully!${RESET}"
echo -e "${CYAN}=============================${RESET}"
