# openSUSE Leap 15.6 Custom ISO Builder

This utility creates a customized, bootable openSUSE Leap 15.6 ISO for fully automated installations. The generated ISO is ideal for PXE booting environments and for provisioning multiple machines with a consistent configuration.

## Features

- **Fully Automated Installation**: Uses AutoYaST to perform a hands-off installation.
- **Pre-Patched Image**: The final ISO is fully updated with the latest security patches and software updates.
- **Dynamic Disk Selection**: Automatically installs to the smallest available disk on the target machine.
- **Dynamic Network Configuration**: Automatically configures the network to use the same interface the installer booted from.
- **Customizable Configuration**: Allows you to configure users, passwords, SSH keys, additional packages, and systemd services via simple text files.

## Prerequisites

This utility is designed to be run on a Linux-based build machine. The following dependencies are required:

- `wget`
- `xorriso`
- `unsquashfs` (from `squashfs-tools` or `squashfs`)
- `mksquashfs` (from `squashfs-tools` or `squashfs`)
- `rsync`
- `createrepo_c`

## Quick Start

A `Makefile` is provided to streamline the process. You can view all available commands by running:

```bash
make
```

### 1. Install Dependencies

To install the required dependencies, run the following command:

```bash
make deps
```

### 2. Configure Your Custom ISO

The ISO is configured using several text files in the root of the project directory:

- **`credentials.txt`**: A list of users and their passwords in the format `username:password`, one per line.
- **`users.txt`**: A list of users and the URLs to their public SSH keys in the format `username,key_url`, one per line.
- **`packages.txt`**: A list of additional packages to install, one per line.
- **`services.txt`**: A list of systemd services to enable and start on boot, one per line.

Example configuration files with the `.example` extension are provided. You can copy these and modify them to suit your needs.

### 3. Build the ISO

Once you have configured your ISO, you can build it by running the following command:

```bash
make build
```

The script will download the base openSUSE Leap 15.6 ISO, apply your customizations, and create a new, bootable ISO file named `openSUSE-Leap-15.6-Custom.iso` in the project directory.

### 4. Set Up PXE Boot Server (Optional)

A script is provided to set up a PXE boot server to serve the custom ISO over the network. This will install and configure a TFTP and DHCP server.

**Note:** This will make changes to your system's network configuration. Please review the `setup_pxe.sh` script before running it.

To set up the PXE server, run:

```bash
make pxe-setup
```

### 5. Clean Up

To remove all build artifacts, including the downloaded ISO and the final custom ISO, run:

```bash
make clean
```

## How It Works

The `create_iso.sh` script automates the entire process of creating the custom ISO:

1.  **Downloads the Base ISO**: It fetches the official openSUSE Leap 15.6 ISO from the official mirrors.
2.  **Prepares the Workspace**: It mounts the downloaded ISO and copies its contents to a working directory.
3.  **Generates AutoYaST Configuration**: It creates a dynamic `autoinst.xml` file based on your configuration in the `credentials.txt`, `users.txt`, `packages.txt`, and `services.txt` files.
4.  **Updates the Filesystem**: It unpacks the main filesystem from the ISO, uses a `chroot` environment to apply all the latest `zypper` updates, and then repacks the updated filesystem.
5.  **Creates the Final ISO**: It modifies the bootloader to make the automated installation the default option and then uses `xorriso` to create the final, bootable `.iso` file.
