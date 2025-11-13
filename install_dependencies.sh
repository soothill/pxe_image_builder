#!/bin/bash
#
# This script installs the required dependencies for the ISO creation utility.
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

# Detect package manager and install dependencies
if command -v apt &> /dev/null; then
    info "Detected Debian-based system (apt)."
    apt update
    apt install -y wget xorriso squashfs-tools rsync createrepo-c kmod
elif command -v dnf &> /dev/null; then
    info "Detected Fedora-based system (dnf)."
    dnf install -y wget xorriso squashfs-tools rsync createrepo_c
elif command -v zypper &> /dev/null; then
    info "Detected openSUSE-based system (zypper)."
    zypper --non-interactive install wget xorriso squashfs rsync createrepo_c
else
    error "Could not detect a supported package manager (apt, dnf, or zypper). Please install the dependencies manually."
fi

info "All dependencies have been installed successfully."
