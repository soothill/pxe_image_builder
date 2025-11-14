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
info "Checking for PXE boot server dependencies..."
packages_to_install=""
for pkg in tftp dhcp-server syslinux; do
    if ! rpm -q "$pkg" &> /dev/null; then
        packages_to_install="$packages_to_install $pkg"
    fi
done

if [ -n "$packages_to_install" ]; then
    info "Installing missing dependencies:${packages_to_install}"
    zypper refresh
    zypper install -y $packages_to_install
else
    info "All dependencies are already installed."
fi

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

# Function to convert CIDR prefix to a netmask
cidr_to_netmask() {
    local cidr=$1
    local netmask=""
    local i
    for ((i=0; i<4; i++)); do
        local n=0
        if [ $cidr -ge 8 ]; then
            n=255
            cidr=$((cidr - 8))
        elif [ $cidr -gt 0 ]; then
            n=$((256 - (1 << (8 - cidr))))
            cidr=0
        fi
        netmask="${netmask}${n}"
        [ $i -lt 3 ] && netmask="${netmask}."
    done
    echo "$netmask"
}

# Prompt for the server's IP address
read -p "Please enter the IP address of this PXE server: " server_ip

# Auto-detect network configuration from the provided IP
interface_info=$(ip -o -4 addr show | grep "inet ${server_ip}/")
if [ -z "$interface_info" ]; then
    error "Could not find an interface with the IP address ${server_ip}"
fi

dhcp_interface=$(echo "$interface_info" | awk '{print $2}')
cidr=$(echo "$interface_info" | awk '{print $4}' | cut -d'/' -f2)

netmask=$(cidr_to_netmask "$cidr")

# Calculate subnet
IFS=. read -r i1 i2 i3 i4 <<< "$server_ip"
IFS=. read -r m1 m2 m3 m4 <<< "$netmask"
subnet=$(printf "%d.%d.%d.%d" "$((i1 & m1))" "$((i2 & m2))" "$((i3 & m3))" "$((i4 & m4))")

info "Detected the following network configuration:"
info "Interface: ${dhcp_interface}"
info "IP Address: ${server_ip}"
info "Netmask: ${netmask}"
info "Subnet: ${subnet}"

# Prompt for remaining details with sane defaults
read -p "Enter the start of the IP range for leases [${subnet%.*}.150]: " range_start
range_start=${range_start:-${subnet%.*}.150}
read -p "Enter the end of the IP range for leases [${subnet%.*}.200]: " range_end
range_end=${range_end:-${subnet%.*}.200}
read -p "Enter the router/gateway IP address [${subnet%.*}.1]: " router_ip
router_ip=${router_ip:-${subnet%.*}.1}

cat > /etc/dhcpd.conf <<EOF
default-lease-time 600;
max-lease-time 7200;
authoritative;
log-facility local7;

subnet ${subnet} netmask ${netmask} {
  range ${range_start} ${range_end};
  option routers ${router_ip};
  option domain-name-servers 8.8.8.8, 8.8.4.4;
  filename "pxelinux.0";
  next-server ${server_ip};
}
EOF

# Configure DHCPD_INTERFACE for openSUSE
info "Configuring DHCP interface in /etc/sysconfig/dhcpd..."
echo "DHCPD_INTERFACE=\"${dhcp_interface}\"" > /etc/sysconfig/dhcpd

systemctl restart dhcpd

# Copy ISO contents to TFTP server
info "Copying ISO contents to TFTP server..."
ISO_FILE="openSUSE-Leap-15.6-Custom.iso"
# Check if the ISO file exists and is not empty
if [ ! -s "$ISO_FILE" ]; then
    error "Custom ISO not found or is empty. Please run 'make build' first."
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
