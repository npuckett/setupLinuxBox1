#!/bin/bash
#===============================================================================
# Linux Computer Vision Workstation Setup Script
# Ubuntu 22.04 LTS with NVIDIA GPU Support
#
# This script sets up a complete CV workstation for 24/7 operation including:
# - NVIDIA GPU drivers and CUDA
# - Python environment
# - Remote desktop (xRDP) and SSH access
# - System optimizations for CV workloads
# - Optional: Processing 4, VSCode
#
# Usage:
#   chmod +x linux_cv_setup.sh
#   ./linux_cv_setup.sh
#
# Options:
#   --skip-reboot     Don't prompt for reboot at end
#   --minimal         Skip optional software (Processing, VSCode)
#   --help            Show this help message
#
# Requirements:
#   - Ubuntu 22.04 LTS (freshly installed)
#   - NVIDIA GPU (GTX 1050 Ti or better recommended)
#   - Internet connection
#   - Sudo access
#
#===============================================================================

set -o pipefail  # Catch errors in pipes

#===============================================================================
# Configuration
#===============================================================================

SCRIPT_VERSION="1.0.0"
LOG_FILE="/tmp/cv_workstation_setup_$(date +%Y%m%d_%H%M%S).log"
PROCESSING_VERSION="4.3"
REQUIRED_SPACE_GB=20

# Network interface names (populated during setup)
WIFI_INTERFACE=""
ETH_INTERFACE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse command line arguments
SKIP_REBOOT=false
MINIMAL_INSTALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-reboot)
            SKIP_REBOOT=true
            shift
            ;;
        --minimal)
            MINIMAL_INSTALL=true
            shift
            ;;
        --help)
            head -35 "$0" | tail -30
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

#===============================================================================
# Logging Functions
#===============================================================================

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} - $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "[INFO] $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log "[SUCCESS] $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "[WARNING] $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "[ERROR] $1"
}

log_step() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log "[STEP] $1"
}

#===============================================================================
# Error Handling
#===============================================================================

error_exit() {
    log_error "$1"
    log_error "Setup failed. Check log file: $LOG_FILE"
    exit 1
}

# Trap for cleanup on error
cleanup() {
    if [ $? -ne 0 ]; then
        log_error "Script interrupted or failed"
        log_error "Partial installation may have occurred"
        log_error "Review log file: $LOG_FILE"
    fi
}
trap cleanup EXIT

#===============================================================================
# Prerequisite Checks
#===============================================================================

check_prerequisites() {
    log_step "Step 0: Checking Prerequisites"
    
    # Check if running as root (should NOT be)
    if [ "$EUID" -eq 0 ]; then
        error_exit "Do not run this script as root. Run as normal user with sudo access."
    fi
    log_success "Running as non-root user: $(whoami)"
    
    # Check sudo access
    if ! sudo -v 2>/dev/null; then
        error_exit "User does not have sudo access. Please add user to sudoers."
    fi
    log_success "Sudo access confirmed"
    
    # Check Ubuntu version
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            error_exit "This script is designed for Ubuntu. Detected: $ID"
        fi
        if [[ ! "$VERSION_ID" =~ ^22\.04 ]]; then
            log_warning "Script tested on Ubuntu 22.04. Detected: $VERSION_ID"
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
        log_success "Ubuntu version: $VERSION_ID"
    else
        error_exit "Cannot determine OS version"
    fi
    
    # Check internet connectivity
    log_info "Checking internet connectivity..."
    if ! ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
        if ! ping -c 1 -W 5 1.1.1.1 &>/dev/null; then
            error_exit "No internet connection. Please connect and try again."
        fi
    fi
    log_success "Internet connection available"
    
    # Check disk space
    local available_space=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$available_space" -lt "$REQUIRED_SPACE_GB" ]; then
        error_exit "Insufficient disk space. Need ${REQUIRED_SPACE_GB}GB, have ${available_space}GB"
    fi
    log_success "Disk space: ${available_space}GB available"
    
    # Check for NVIDIA GPU
    if lspci | grep -i nvidia &>/dev/null; then
        local gpu_name=$(lspci | grep -i nvidia | head -1 | sed 's/.*: //')
        log_success "NVIDIA GPU detected: $gpu_name"
    else
        log_warning "No NVIDIA GPU detected. CUDA acceleration will not be available."
        read -p "Continue without GPU? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    log_success "All prerequisites passed"
}

#===============================================================================
# System Update
#===============================================================================

system_update() {
    log_step "Step 1: System Update"
    
    log_info "Updating package lists..."
    if ! sudo apt update 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "Failed to update package lists"
    fi
    
    log_info "Upgrading installed packages..."
    if ! sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "Failed to upgrade packages"
    fi
    
    log_success "System updated successfully"
}

#===============================================================================
# Remove Bloatware
#===============================================================================

remove_bloatware() {
    log_step "Step 2: Removing Unnecessary Packages"
    
    local packages_to_remove=(
        aisleriot
        gnome-mahjongg
        gnome-mines
        gnome-sudoku
        thunderbird
        rhythmbox
        shotwell
        totem
        cheese
    )
    
    # Remove LibreOffice (uses glob pattern)
    log_info "Removing LibreOffice suite..."
    sudo apt remove -y libreoffice-* 2>/dev/null || true
    
    for pkg in "${packages_to_remove[@]}"; do
        if dpkg -l | grep -q "^ii.*$pkg"; then
            log_info "Removing $pkg..."
            sudo apt remove -y "$pkg" 2>/dev/null || log_warning "Could not remove $pkg"
        fi
    done
    
    log_info "Cleaning up..."
    sudo apt autoremove -y 2>&1 | tee -a "$LOG_FILE"
    sudo apt autoclean 2>&1 | tee -a "$LOG_FILE"
    
    log_success "Bloatware removal complete"
}

#===============================================================================
# Install Essential Tools
#===============================================================================

install_essential_tools() {
    log_step "Step 3: Installing Essential Tools"
    
    local essential_packages=(
        build-essential
        git
        curl
        wget
        vim
        nano
        htop
        tmux
        screen
        net-tools
        openssh-server
        software-properties-common
        neofetch
        unzip
        ca-certificates
        gnupg
        lsb-release
    )
    
    log_info "Installing essential packages..."
    if ! sudo apt install -y "${essential_packages[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "Failed to install essential packages"
    fi
    
    # Enable SSH
    log_info "Enabling SSH server..."
    sudo systemctl enable ssh 2>/dev/null || true
    sudo systemctl start ssh 2>/dev/null || true
    
    log_success "Essential tools installed"
}

#===============================================================================
# Install Python
#===============================================================================

install_python() {
    log_step "Step 4: Installing Python Development Environment"
    
    local python_packages=(
        python3.10
        python3-pip
        python3-venv
        python3-dev
        python-is-python3
    )
    
    log_info "Installing Python packages..."
    if ! sudo apt install -y "${python_packages[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "Failed to install Python"
    fi
    
    # Upgrade pip
    log_info "Upgrading pip..."
    python3 -m pip install --upgrade pip 2>&1 | tee -a "$LOG_FILE" || log_warning "Could not upgrade pip"
    
    # Verify installation
    local python_version=$(python3 --version 2>&1)
    local pip_version=$(pip3 --version 2>&1)
    
    log_success "Python installed: $python_version"
    log_success "Pip installed: $pip_version"
}

#===============================================================================
# Install NVIDIA Drivers
#===============================================================================

install_nvidia_drivers() {
    log_step "Step 5: Installing NVIDIA Drivers"
    
    # Check if NVIDIA GPU exists
    if ! lspci | grep -i nvidia &>/dev/null; then
        log_warning "No NVIDIA GPU detected, skipping driver installation"
        return 0
    fi
    
    # Check if drivers already installed
    if command -v nvidia-smi &>/dev/null; then
        local current_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "unknown")
        log_info "NVIDIA drivers already installed (version: $current_version)"
        read -p "Reinstall drivers? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Keeping existing drivers"
            return 0
        fi
    fi
    
    log_info "Detecting recommended NVIDIA drivers..."
    sudo ubuntu-drivers devices 2>&1 | tee -a "$LOG_FILE"
    
    log_info "Installing recommended NVIDIA drivers..."
    if ! sudo ubuntu-drivers autoinstall 2>&1 | tee -a "$LOG_FILE"; then
        log_warning "Automatic driver installation failed. Trying manual installation..."
        
        # Try installing specific driver version
        if ! sudo apt install -y nvidia-driver-535 2>&1 | tee -a "$LOG_FILE"; then
            error_exit "Failed to install NVIDIA drivers"
        fi
    fi
    
    log_success "NVIDIA drivers installed"
    log_warning "REBOOT REQUIRED for drivers to take effect"
}

#===============================================================================
# Install OpenCV Dependencies
#===============================================================================

install_opencv_deps() {
    log_step "Step 6: Installing OpenCV Dependencies"
    
    local opencv_packages=(
        libopencv-dev
        python3-opencv
        ffmpeg
        libavcodec-dev
        libavformat-dev
        libswscale-dev
        libv4l-dev
        libxvidcore-dev
        libx264-dev
        libjpeg-dev
        libpng-dev
        libtiff-dev
        libgtk-3-dev
        libatlas-base-dev
        gfortran
    )
    
    log_info "Installing OpenCV system dependencies..."
    if ! sudo apt install -y "${opencv_packages[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log_warning "Some OpenCV dependencies failed to install"
    fi
    
    log_success "OpenCV dependencies installed"
}

#===============================================================================
# Install Remote Desktop (xRDP)
#===============================================================================

install_remote_desktop() {
    log_step "Step 7: Installing Remote Desktop (xRDP)"
    
    log_info "Installing xRDP..."
    if ! sudo apt install -y xrdp 2>&1 | tee -a "$LOG_FILE"; then
        error_exit "Failed to install xRDP"
    fi
    
    # Add xrdp user to ssl-cert group
    sudo adduser xrdp ssl-cert 2>/dev/null || true
    
    # Configure xRDP for better performance
    log_info "Configuring xRDP..."
    
    # Create polkit rule for color management (fixes common error)
    sudo tee /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla > /dev/null << 'EOF'
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
    
    # Enable and start xRDP
    sudo systemctl enable xrdp 2>&1 | tee -a "$LOG_FILE"
    sudo systemctl start xrdp 2>&1 | tee -a "$LOG_FILE"
    
    log_success "xRDP installed and enabled on port 3389"
}

#===============================================================================
# Install Optional Software
#===============================================================================

install_optional_software() {
    if [ "$MINIMAL_INSTALL" = true ]; then
        log_info "Skipping optional software (--minimal flag set)"
        return 0
    fi
    
    log_step "Step 8: Installing Optional Software"
    
    # Install Processing 4
    install_processing
    
    # Install VSCode
    install_vscode
    
    # Install Chrome
    install_chrome
}

install_processing() {
    log_info "Installing Processing ${PROCESSING_VERSION}..."
    
    local processing_dir="/opt/processing"
    local processing_url="https://github.com/processing/processing4/releases/download/processing-1293-${PROCESSING_VERSION}/processing-${PROCESSING_VERSION}-linux-x64.tgz"
    
    # Check if already installed
    if [ -d "$processing_dir" ]; then
        log_info "Processing already installed at $processing_dir"
        return 0
    fi
    
    cd /tmp
    
    # Download
    if ! wget -q --show-progress "$processing_url" -O processing.tgz 2>&1; then
        log_warning "Could not download Processing. Skipping."
        return 0
    fi
    
    # Extract and install
    tar -xzf processing.tgz 2>&1 | tee -a "$LOG_FILE"
    sudo mv processing-${PROCESSING_VERSION} "$processing_dir" 2>/dev/null || true
    
    # Create desktop entry
    sudo tee /usr/share/applications/processing.desktop > /dev/null << EOF
[Desktop Entry]
Name=Processing
Comment=Processing Development Environment
Exec=${processing_dir}/processing
Icon=${processing_dir}/lib/icons/pde-256.png
Terminal=false
Type=Application
Categories=Development;IDE;
EOF
    
    # Cleanup
    rm -f /tmp/processing.tgz
    
    log_success "Processing ${PROCESSING_VERSION} installed"
}

install_vscode() {
    log_info "Installing Visual Studio Code..."
    
    # Check if already installed
    if command -v code &>/dev/null; then
        log_info "VSCode already installed"
        return 0
    fi
    
    cd /tmp
    
    # Download
    if ! wget -q --show-progress "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64" -O vscode.deb 2>&1; then
        log_warning "Could not download VSCode. Skipping."
        return 0
    fi
    
    # Install
    if ! sudo apt install -y ./vscode.deb 2>&1 | tee -a "$LOG_FILE"; then
        log_warning "Could not install VSCode"
    fi
    
    rm -f /tmp/vscode.deb
    
    log_success "VSCode installed"
}

install_chrome() {
    log_info "Installing Google Chrome..."
    
    # Check if already installed
    if command -v google-chrome &>/dev/null; then
        log_info "Chrome already installed"
        return 0
    fi
    
    cd /tmp
    
    if ! wget -q --show-progress "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" -O chrome.deb 2>&1; then
        log_warning "Could not download Chrome. Skipping."
        return 0
    fi
    
    if ! sudo apt install -y ./chrome.deb 2>&1 | tee -a "$LOG_FILE"; then
        log_warning "Could not install Chrome"
    fi
    
    rm -f /tmp/chrome.deb
    
    log_success "Chrome installed"
}

#===============================================================================
# Configure Internet Sharing (WiFi to Ethernet)
#===============================================================================

configure_internet_sharing() {
    log_step "Step 9: Configuring Internet Sharing (WiFi → Ethernet)"
    
    # Detect WiFi interface
    local wifi_iface=$(ip link show | grep -E "wl[a-z0-9]+" -o | head -1)
    if [ -z "$wifi_iface" ]; then
        wifi_iface=$(ip link show | grep -oP "wlp\d+s\d+" | head -1)
    fi
    
    # Detect Ethernet interface
    local eth_iface=$(ip link show | grep -E "^[0-9]+: (eth|enp|eno)" | awk -F': ' '{print $2}' | head -1)
    
    if [ -z "$wifi_iface" ]; then
        log_warning "No WiFi interface detected. Skipping internet sharing setup."
        log_info "You can configure this manually later. See documentation."
        return 0
    fi
    
    if [ -z "$eth_iface" ]; then
        log_warning "No Ethernet interface detected. Skipping internet sharing setup."
        return 0
    fi
    
    log_info "Detected WiFi interface: $wifi_iface"
    log_info "Detected Ethernet interface: $eth_iface"
    
    # Enable IP forwarding permanently
    log_info "Enabling IP forwarding..."
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
    fi
    sudo sysctl -w net.ipv4.ip_forward=1 2>&1 | tee -a "$LOG_FILE"
    
    # Install dnsmasq for DHCP
    log_info "Installing dnsmasq for DHCP server..."
    if ! sudo apt install -y dnsmasq 2>&1 | tee -a "$LOG_FILE"; then
        log_warning "Failed to install dnsmasq. Internet sharing may not work."
        return 0
    fi
    
    # Stop dnsmasq while configuring
    sudo systemctl stop dnsmasq 2>/dev/null || true
    
    # Configure dnsmasq for ethernet DHCP
    log_info "Configuring DHCP server on ethernet..."
    sudo tee /etc/dnsmasq.d/ethernet-share.conf > /dev/null << EOF
# Internet sharing configuration
# Share WiFi ($wifi_iface) to Ethernet ($eth_iface)

# Only listen on ethernet interface
interface=$eth_iface
bind-interfaces

# DHCP range for connected devices (cameras, etc.)
dhcp-range=10.42.0.10,10.42.0.250,255.255.255.0,24h

# Gateway (this machine)
dhcp-option=option:router,10.42.0.1

# DNS servers
dhcp-option=option:dns-server,8.8.8.8,8.8.4.4

# Faster lease for testing
dhcp-lease-max=50
EOF
    
    # Create netplan configuration for static ethernet IP
    log_info "Configuring static IP on ethernet..."
    
    # Check if using netplan (Ubuntu 18.04+)
    if [ -d /etc/netplan ]; then
        # Backup existing config
        sudo cp /etc/netplan/*.yaml /etc/netplan/*.yaml.backup 2>/dev/null || true
        
        # Create ethernet sharing config
        sudo tee /etc/netplan/99-ethernet-share.yaml > /dev/null << EOF
network:
  version: 2
  ethernets:
    $eth_iface:
      addresses:
        - 10.42.0.1/24
      dhcp4: false
EOF
        
        # Apply netplan
        sudo netplan apply 2>&1 | tee -a "$LOG_FILE" || log_warning "Netplan apply had warnings"
    else
        # Fallback: use ip commands directly
        sudo ip addr add 10.42.0.1/24 dev "$eth_iface" 2>/dev/null || true
        sudo ip link set "$eth_iface" up
    fi
    
    # Configure iptables for NAT
    log_info "Configuring NAT (masquerading)..."
    
    # Flush existing NAT rules to avoid duplicates
    sudo iptables -t nat -F POSTROUTING 2>/dev/null || true
    
    # Add masquerading rule
    sudo iptables -t nat -A POSTROUTING -o "$wifi_iface" -j MASQUERADE
    
    # Allow forwarding
    sudo iptables -A FORWARD -i "$wifi_iface" -o "$eth_iface" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    sudo iptables -A FORWARD -i "$eth_iface" -o "$wifi_iface" -j ACCEPT 2>/dev/null || true
    
    # Save iptables rules to persist across reboots
    log_info "Saving iptables rules..."
    sudo apt install -y iptables-persistent 2>&1 | tee -a "$LOG_FILE" || true
    sudo sh -c 'iptables-save > /etc/iptables/rules.v4' 2>/dev/null || true
    
    # Create systemd service for ethernet IP (backup method)
    log_info "Creating startup service for internet sharing..."
    sudo tee /etc/systemd/system/ethernet-share.service > /dev/null << EOF
[Unit]
Description=Internet Sharing - Ethernet Static IP and NAT
After=network.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'ip addr add 10.42.0.1/24 dev $eth_iface 2>/dev/null || true; ip link set $eth_iface up; sysctl -w net.ipv4.ip_forward=1; iptables -t nat -C POSTROUTING -o $wifi_iface -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o $wifi_iface -j MASQUERADE'

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable ethernet-share.service 2>&1 | tee -a "$LOG_FILE"
    
    # Start dnsmasq
    sudo systemctl enable dnsmasq 2>&1 | tee -a "$LOG_FILE"
    sudo systemctl start dnsmasq 2>&1 | tee -a "$LOG_FILE"
    
    # Store interface names for system info
    WIFI_INTERFACE="$wifi_iface"
    ETH_INTERFACE="$eth_iface"
    
    log_success "Internet sharing configured"
    log_info "  WiFi interface: $wifi_iface (internet)"
    log_info "  Ethernet interface: $eth_iface (10.42.0.1)"
    log_info "  DHCP range: 10.42.0.10 - 10.42.0.250"
    log_info "  Connected devices will get IPs in 10.42.0.x range"
}

#===============================================================================
# System Optimization
#===============================================================================

optimize_system() {
    log_step "Step 10: Optimizing System for CV Workloads"
    
    # Increase file watchers
    log_info "Increasing file watcher limit..."
    if ! grep -q "fs.inotify.max_user_watches" /etc/sysctl.conf; then
        echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.conf > /dev/null
    fi
    
    # Network optimizations for RTSP
    log_info "Optimizing network buffers for RTSP..."
    if ! grep -q "net.core.rmem_max=26214400" /etc/sysctl.conf; then
        sudo tee -a /etc/sysctl.conf > /dev/null << 'EOF'

# Network optimizations for RTSP streaming
net.core.rmem_max=26214400
net.core.rmem_default=26214400
net.core.wmem_max=26214400
net.core.wmem_default=26214400
EOF
    fi
    
    # Apply sysctl changes
    sudo sysctl -p 2>&1 | tee -a "$LOG_FILE" || true
    
    # Disable automatic sleep
    log_info "Disabling automatic sleep..."
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0 2>/dev/null || true
    gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
    
    # Disable automatic updates (for production stability)
    log_info "Disabling automatic updates..."
    sudo systemctl disable unattended-upgrades 2>/dev/null || true
    
    # Install and configure CPU performance governor
    log_info "Setting CPU governor to performance..."
    if sudo apt install -y cpufrequtils 2>&1 | tee -a "$LOG_FILE"; then
        echo 'GOVERNOR="performance"' | sudo tee /etc/default/cpufrequtils > /dev/null
        sudo systemctl enable cpufrequtils 2>/dev/null || true
        sudo systemctl restart cpufrequtils 2>/dev/null || true
    fi
    
    # Disable unnecessary services
    log_info "Disabling unnecessary services..."
    local services_to_disable=(
        bluetooth.service
        cups.service
        avahi-daemon.service
    )
    
    for service in "${services_to_disable[@]}"; do
        sudo systemctl disable "$service" 2>/dev/null || true
        sudo systemctl stop "$service" 2>/dev/null || true
    done
    
    log_success "System optimizations applied"
}

#===============================================================================
# Configure Firewall
#===============================================================================

configure_firewall() {
    log_step "Step 11: Configuring Firewall"
    
    log_info "Configuring UFW firewall..."
    
    # Enable UFW if not already
    sudo ufw --force enable 2>&1 | tee -a "$LOG_FILE" || true
    
    # Allow essential ports
    sudo ufw allow 22/tcp comment 'SSH' 2>&1 | tee -a "$LOG_FILE"
    sudo ufw allow 3389/tcp comment 'RDP' 2>&1 | tee -a "$LOG_FILE"
    sudo ufw allow 554/tcp comment 'RTSP' 2>&1 | tee -a "$LOG_FILE"
    
    log_success "Firewall configured"
}

#===============================================================================
# Create System Info
#===============================================================================

create_system_info() {
    log_step "Step 12: Creating System Information"
    
    local my_ip=$(hostname -I | awk '{print $1}')
    local username=$(whoami)
    local hostname=$(hostname)
    
    # Create info file on desktop
    mkdir -p ~/Desktop
    
    cat > ~/Desktop/SYSTEM_INFO.txt << EOF
================================================================================
Computer Vision Workstation - System Information
================================================================================

Setup Date:     $(date)
Hostname:       $hostname
IP Address:     $my_ip
Username:       $username
Setup Script:   v${SCRIPT_VERSION}

--------------------------------------------------------------------------------
Remote Access
--------------------------------------------------------------------------------
SSH:            ssh ${username}@${my_ip}
RDP:            ${my_ip}:3389 (username: ${username})

--------------------------------------------------------------------------------
Internet Sharing (WiFi → Ethernet)
--------------------------------------------------------------------------------
WiFi Interface:     ${WIFI_INTERFACE:-"(detect with: ip link show)"}
Ethernet Interface: ${ETH_INTERFACE:-"(detect with: ip link show)"}
Ethernet IP:        10.42.0.1
DHCP Range:         10.42.0.10 - 10.42.0.250

Connected cameras will receive IPs in the 10.42.0.x range.
View connected devices: cat /var/lib/misc/dnsmasq.leases

--------------------------------------------------------------------------------
Important Commands
--------------------------------------------------------------------------------
GPU Status:       nvidia-smi
System Monitor:   htop
Network Info:     ip addr show
DHCP Leases:      cat /var/lib/misc/dnsmasq.leases
Restart Sharing:  sudo systemctl restart dnsmasq

--------------------------------------------------------------------------------
After Reboot - Verification Steps
--------------------------------------------------------------------------------
1. Verify NVIDIA drivers:
   nvidia-smi

2. Verify CUDA with PyTorch (after installing):
   python3 -c "import torch; print(torch.cuda.is_available())"

3. Test remote desktop connection from another computer

4. Verify internet sharing:
   - Connect camera/device to ethernet/PoE switch
   - Check for DHCP lease: cat /var/lib/misc/dnsmasq.leases
   - Ping the device: ping 10.42.0.x

--------------------------------------------------------------------------------
Python Environment Setup (for your projects)
--------------------------------------------------------------------------------
1. Create project directory:
   mkdir -p ~/projects/your-project
   cd ~/projects/your-project

2. Create virtual environment:
   python3 -m venv venv
   source venv/bin/activate

3. Install PyTorch with CUDA:
   pip3 install torch torchvision --index-url https://download.pytorch.org/whl/cu118

--------------------------------------------------------------------------------
Log File: ${LOG_FILE}
================================================================================
EOF

    log_success "System info saved to ~/Desktop/SYSTEM_INFO.txt"
}

#===============================================================================
# Final Summary
#===============================================================================

print_summary() {
    local my_ip=$(hostname -I | awk '{print $1}')
    
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    SETUP COMPLETE!                           ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BLUE}Hostname:${NC}    $(hostname)"
    echo -e "  ${BLUE}IP Address:${NC}  ${my_ip}"
    echo -e "  ${BLUE}Python:${NC}      $(python3 --version 2>&1)"
    echo ""
    echo -e "  ${BLUE}Remote Access:${NC}"
    echo -e "    SSH: ${GREEN}ssh $(whoami)@${my_ip}${NC}"
    echo -e "    RDP: ${GREEN}${my_ip}:3389${NC}"
    echo ""
    echo -e "  ${BLUE}Log File:${NC}    ${LOG_FILE}"
    echo ""
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  ⚠️  IMPORTANT: You MUST REBOOT for NVIDIA drivers to work!  ${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  After reboot, verify with: ${GREEN}nvidia-smi${NC}"
    echo ""
    
    log_success "Setup completed successfully"
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}       Computer Vision Workstation Setup v${SCRIPT_VERSION}              ${NC}"
    echo -e "${GREEN}       Ubuntu 22.04 LTS + NVIDIA GPU Support                  ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "This script will configure your system for 24/7 CV operation."
    echo "Log file: $LOG_FILE"
    echo ""
    
    read -p "Continue with setup? (Y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
    
    log_info "Starting setup at $(date)"
    
    # Run all setup steps
    check_prerequisites
    system_update
    remove_bloatware
    install_essential_tools
    install_python
    install_nvidia_drivers
    install_opencv_deps
    install_remote_desktop
    install_optional_software
    configure_internet_sharing
    optimize_system
    configure_firewall
    create_system_info
    print_summary
    
    # Prompt for reboot
    if [ "$SKIP_REBOOT" = false ]; then
        echo ""
        read -p "Reboot now to complete driver installation? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            log_info "Rebooting system..."
            sudo reboot
        else
            echo ""
            echo -e "${YELLOW}Remember to reboot before using GPU acceleration!${NC}"
            echo ""
        fi
    fi
}

# Run main function
main "$@"
