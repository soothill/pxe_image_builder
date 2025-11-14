#!/bin/bash
#
# This script sets up a PXE boot server to serve the custom openSUSE ISO.
#

set -eo pipefail

info() {
    echo "[INFO] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  error "Please run this script with sudo or as root."
fi

# Check for openSUSE
if ! command -v zypper &> /dev/null; then
    error "This script is designed for openSUSE-based systems. Please adapt it for your distribution."
fi

# Install dependencies
info "Installing PXE boot server dependencies..."
zypper refresh
zypper install -y tftp dhcp-server syslinux

# Configure TFTP server
info "Configuring TFTP server..."
TFTP_DIR="/srv/tftpboot"
mkdir -p "$TFTP_DIR"
# On openSUSE, TFTP is often managed by xinetd or as a socket-activated service.
# We will enable the tftp service.
# The default directory is /srv/tftpboot.
cat > /etc/sysconfig/tftp <<EOF
TFTP_DIRECTORY="$TFTP_DIR"
TFTP_OPTIONS="--secure"
TFTP_ADDRESS=":69"
EOF

# Use tftp.socket for modern openSUSE systems
if systemctl list-unit-files | grep -q 'tftp.socket'; then
    systemctl restart tftp.socket
else
    systemctl restart tftp
fi


# Configure DHCP server
info "Configuring DHCP server..."
cat > /etc/dhcpd.conf <<EOF
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 192.168.1.0 netmask 255.255.255.0 {
  range 192.168.1.100 192.168.1.200;
  option routers 192.168.1.1;
  option domain-name-servers 8.8.8.8, 8.8.4.4;
  filename "pxelinux.0";
  next-server 192.168.1.10; # Replace with your server's IP
}
EOF

# Prompt for the server IP
read -p "Please enter the IP address of this server: " server_ip
sed -i "s/^\s*next-server .*/  next-server ${server_ip};/" /etc/dhcpd.conf

# Prompt for the network interface and configure it for openSUSE
read -p "Please enter the network interface for the DHCP server (e.g., eth0): " dhcp_interface
echo "DHCPD_INTERFACE=\"${dhcp_interface}\"" > /etc/sysconfig/dhcpd

systemctl restart dhcpd

# Copy ISO contents to TFTP server
info "Copying ISO contents to TFTP server..."
ISO_FILE="openSUSE-Leap-15.6-Custom.iso"
if [ ! -f "$ISO_FILE" ]; then
    error "Custom ISO not found. Please run 'make build' first."
fi

ISO_MOUNT_DIR="/mnt/iso"
mkdir -p "$ISO_MOUNT_DIR"
mount -o loop "$ISO_FILE" "$ISO_MOUNT_DIR"

rsync -av "$ISO_MOUNT_DIR/" "$TFTP_DIR/"
umount "$ISO_MOUNT_DIR"

# Configure PXE boot menu
info "Configuring PXE boot menu..."
mkdir -p "$TFTP_DIR/pxelinux.cfg"
cat > "$TFTP_DIR/pxelinux.cfg/default" <<EOF
DEFAULT openSUSE
LABEL openSUSE
  KERNEL /boot/x86_64/loader/linux
  APPEND initrd=/boot/x86_64/loader/initrd splash=silent autoyast=file:///autoinst.xml
EOF

# Install pxelinux.0
if [ -f "/usr/share/syslinux/pxelinux.0" ]; then
    cp /usr/share/syslinux/pxelinux.0 "$TFTP_DIR/"
else
    error "Could not find pxelinux.0. Please ensure 'syslinux' is installed."
fi


info "PXE boot server setup is complete."
info "Please ensure that your DHCP server is configured to point to this server."
