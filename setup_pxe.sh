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

# Check for Debian/Ubuntu
if ! command -v apt &> /dev/null; then
    error "This script is designed for Debian/Ubuntu-based systems. Please adapt it for your distribution."
fi

# Install dependencies
info "Installing PXE boot server dependencies..."
apt update
apt install -y tftpd-hpa isc-dhcp-server

# Configure TFTP server
info "Configuring TFTP server..."
TFTP_DIR="/srv/tftp"
mkdir -p "$TFTP_DIR"
cat > /etc/default/tftpd-hpa <<EOF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="$TFTP_DIR"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure"
EOF
systemctl restart tftpd-hpa

# Configure DHCP server
info "Configuring DHCP server..."
cat > /etc/dhcp/dhcpd.conf <<EOF
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
sed -i "s/next-server .*/next-server ${server_ip};/" /etc/dhcp/dhcpd.conf

systemctl restart isc-dhcp-server

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
if [ -f "/usr/lib/PXELINUX/pxelinux.0" ]; then
    cp /usr/lib/PXELINUX/pxelinux.0 "$TFTP_DIR/"
elif [ -f "/usr/lib/syslinux/modules/bios/pxelinux.0" ]; then
    cp /usr/lib/syslinux/modules/bios/pxelinux.0 "$TFTP_DIR/"
else
    error "Could not find pxelinux.0. Please install it or adjust the path."
fi


info "PXE boot server setup is complete."
info "Please ensure that your DHCP server is configured to point to this server."
