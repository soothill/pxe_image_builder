#!/bin/bash
#
# This script creates a customized openSUSE Leap 15.6 ISO.
#

set -eo pipefail

# --- Configuration ---
ISO_URL="http://download.opensuse.org/distribution/leap/15.6/iso/openSUSE-Leap-15.6-DVD-x86_64-Current.iso"
ISO_FILENAME="openSUSE-Leap-15.6-DVD-x86_64-Current.iso"
WORKDIR="build"
ISO_MOUNT_DIR="$WORKDIR/iso_mount"
CUSTOM_ISO_DIR="$WORKDIR/custom_iso"
FINAL_ISO_NAME="openSUSE-Leap-15.6-Custom.iso"

# --- Helper Functions ---
info() {
    echo "[INFO] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

check_dependencies() {
    info "Checking for required dependencies..."
    local missing_deps=()
    for cmd in wget xorriso unsquashfs mksquashfs rsync createrepo_c; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        error "The following dependencies are missing: ${missing_deps[*]}. Please install them and try again."
    fi
    info "All dependencies are satisfied."
}

download_iso() {
    if [ ! -f "$ISO_FILENAME" ]; then
        info "Downloading openSUSE Leap 15.6 ISO..."
        wget -c "$ISO_URL"
    else
        info "ISO file already exists. Skipping download."
    fi
}

setup_workspace() {
    info "Setting up the workspace..."
    mkdir -p "$WORKDIR" "$ISO_MOUNT_DIR" "$CUSTOM_ISO_DIR"

    info "Extracting the original ISO..."
    xorriso -osirrox on -indev "$ISO_FILENAME" -extract / "$CUSTOM_ISO_DIR"
    info "Workspace is ready."
}

# --- AutoYaST Generation ---
generate_autoyast_xml() {
    info "Generating AutoYaST XML configuration..."

    # Read user credentials from credentials.txt
    if [ ! -f "credentials.txt" ] || [ ! -s "credentials.txt" ]; then
        error "credentials.txt is missing or empty. Please create it in the format 'username:password'."
    fi

    local users_xml=""
    while IFS=':' read -r user password; do
        if [ -n "$user" ]; then
            users_xml+=$(cat <<EOF
    <user>
      <username>$user</username>
      <user_password>$password</user_password>
      <fullname>$user</fullname>
      <home>/home/$user</home>
      <shell>/bin/bash</shell>
    </user>
EOF
)
        fi
    done < credentials.txt

    # Read additional packages
    local packages_xml=""
    if [ -f "packages.txt" ]; then
        while IFS= read -r pkg; do
            if [ -n "$pkg" ]; then
                packages_xml+="    <package>$pkg</package>\\n"
            fi
        done < packages.txt
    fi

    # Read services to enable
    local services_xml=""
    if [ -f "services.txt" ]; then
        while IFS= read -r service; do
            if [ -n "$service" ]; then
                services_xml+="      <service>${service}</service>\\n"
            fi
        done < services.txt
    fi

    # Read SSH key configuration from users.txt
    local post_script_ssh_fetches=""
    if [ -f "users.txt" ]; then
        while IFS=',' read -r user key_url; do
            if [ -n "$user" ]; then
                post_script_ssh_fetches+="fetch_keys \\"$user\\" \\"$key_url\\"\\n"
            fi
        done < users.txt
    fi

    cat > "$CUSTOM_ISO_DIR/autoinst.xml" <<EOF
<?xml version="1.0"?>
<!DOCTYPE profile>
<profile xmlns="http://www.suse.com/yast/autoinstallation/4.0">
  <general>
    <mode>
      <confirm config:type="boolean">false</confirm>
    </mode>
  </general>

  <networking>
    <interfaces config:type="list">
      <interface>
        <bootproto>dhcp</bootproto>
        <device>bootif</device>
        <startmode>onboot</startmode>
      </interface>
    </interfaces>
  </networking>

  <partitioning config:type="list">
    <drive>
      <device>/dev/install_disk</device>
      <disklabel>gpt</disklabel>
      <use>all</use>
      <partitions config:type="list">
        <partition>
          <create config:type="boolean">true</create>
          <format config:type="boolean">true</format>
          <filesystem config:type="symbol">ext4</filesystem>
          <mount>/</mount>
          <size>100%</size>
        </partition>
      </partitions>
    </drive>
  </partitioning>

  <scripts>
    <pre-scripts config:type="list">
      <script>
        <filename>select_disk.sh</filename>
        <interpreter>shell</interpreter>
        <source>
<![CDATA[
#!/bin/bash
# Find the smallest disk and create a symlink to it
smallest_disk=\$(lsblk -d -o NAME,SIZE -n | sort -k2 -h | head -n 1 | awk '{print \$1}')
ln -s /dev/\$smallest_disk /dev/install_disk
]]>
        </source>
      </script>
    </pre-scripts>
    <post-scripts config:type="list">
      <script>
        <filename>post_install.sh</filename>
        <interpreter>shell</interpreter>
        <source>
<![CDATA[
#!/bin/bash
# Fetch SSH keys and perform updates.

# Wait for network connectivity with a bounded retry loop
NETWORK_CHECK_TARGET="\${NETWORK_CHECK_TARGET:-https://download.opensuse.org}"
NETWORK_CHECK_MAX_ATTEMPTS="\${NETWORK_CHECK_MAX_ATTEMPTS:-30}"
NETWORK_CHECK_SLEEP_SECONDS="\${NETWORK_CHECK_SLEEP_SECONDS:-5}"

attempt=1
while [ \$attempt -le \$NETWORK_CHECK_MAX_ATTEMPTS ]; do
  if curl --silent --head --connect-timeout 5 --max-time 10 "\$NETWORK_CHECK_TARGET" >/dev/null 2>&1; then
    echo "[INFO] Network connectivity confirmed to \$NETWORK_CHECK_TARGET"
    break
  fi

  echo "[INFO] Waiting for network connectivity (attempt \$attempt/\$NETWORK_CHECK_MAX_ATTEMPTS)..."
  sleep "\$NETWORK_CHECK_SLEEP_SECONDS"
  attempt=\$((attempt + 1))
done

if [ \$attempt -gt \$NETWORK_CHECK_MAX_ATTEMPTS ]; then
  echo "[WARN] Unable to confirm network connectivity to \$NETWORK_CHECK_TARGET after \$NETWORK_CHECK_MAX_ATTEMPTS attempts." >&2
fi

function fetch_keys() {
    local user=\$1
    local url=\$2
    local ssh_dir="/home/\$user/.ssh"
    local auth_keys="\$ssh_dir/authorized_keys"

    mkdir -p "\$ssh_dir"
    chown "\$user:\$user" "\$ssh_dir"
    chmod 700 "\$ssh_dir"

    curl -sL "\$url" >> "\$auth_keys"

    chown "\$user:\$user" "\$auth_keys"
    chmod 600 "\$auth_keys"
}

${post_script_ssh_fetches}

#
]]>
        </source>
      </script>
    </post-scripts>
  </scripts>

  <software>
    <packages config:type="list">
      <package>basesystem</package>
      <package>enhanced_base</package>
      <package>yast2_basis</package>
      <package>documentation</package>
      ${packages_xml}
    </packages>
  </software>

  <users config:type="list">
    ${users_xml}
  </users>

  <services-manager>
    <services>
      <enable config:type="list">
        ${services_xml}
      </enable>
    </services>
  </services-manager>
</profile>
EOF

    info "AutoYaST XML file has been generated at $CUSTOM_ISO_DIR/autoinst.xml"
}

# --- Validation ---
validate_packages() {
    info "Validating packages..."
    if [ ! -f "packages.txt" ]; then
        return
    fi

    local packages=()
    while IFS= read -r pkg; do
        if [ -n "$pkg" ]; then
            packages+=("$pkg")
        fi
    done < packages.txt

    if [ ${#packages[@]} -eq 0 ]; then
        info "No packages to validate."
        return
    fi

    local zypper_output
    zypper_output=$(sudo chroot "$1" /usr/bin/zypper --non-interactive install --dry-run "${packages[@]}" 2>&1)
    local zypper_status=$?

    local missing_packages=()
    for pkg in "${packages[@]}"; do
        if grep -q "Package '$pkg' not found." <<<"$zypper_output" || \
           grep -q "No provider of '$pkg' found." <<<"$zypper_output"; then
            info "  - $pkg: Not Found"
            missing_packages+=("$pkg")
        else
            info "  - $pkg: OK"
        fi
    done

    if [ ${#missing_packages[@]} -ne 0 ]; then
        error "The following packages are not available: ${missing_packages[*]}. Please correct packages.txt and try again."
    elif [ $zypper_status -ne 0 ]; then
        error "zypper returned a non-zero exit status ($zypper_status). Output: $zypper_output"
    fi
}

validate_services() {
    info "Validating services..."
    if [ ! -f "services.txt" ]; then
        return
    fi

    local squashfs_root="$1"
    declare -A available_services=()
    local service_list_obtained=false

    if command -v systemctl >/dev/null 2>&1; then
        local systemctl_output
        if systemctl_output=$(sudo systemctl --root "$squashfs_root" --no-legend --no-pager list-unit-files --type=service 2>/dev/null); then
            service_list_obtained=true
            while IFS= read -r line; do
                local unit_file="${line%% *}"
                if [[ -z "$unit_file" || "$unit_file" != *.service ]]; then
                    continue
                fi
                local base_unit="${unit_file%.service}"
                available_services["$unit_file"]=1
                available_services["$base_unit"]=1
            done <<< "$systemctl_output"
        fi
    fi

    if ! $service_list_obtained; then
        local systemd_dir="$squashfs_root/usr/lib/systemd/system"
        if [ -d "$systemd_dir" ]; then
            while IFS= read -r service_path; do
                local unit_file="$(basename "$service_path")"
                local base_unit="${unit_file%.service}"
                available_services["$unit_file"]=1
                available_services["$base_unit"]=1
            done < <(sudo find "$systemd_dir" -maxdepth 1 -type f -name '*.service' -print)
            service_list_obtained=true
        fi
    fi

    local missing_services=()
    while IFS= read -r service || [[ -n "$service" ]]; do
        service="${service%%#*}"
        service="${service#${service%%[![:space:]]*}}"
        service="${service%${service##*[![:space:]]}}"
        if [ -n "$service" ]; then
            local found=false
            local lookup_candidates=()
            lookup_candidates+=("$service")
            if [[ $service == *.service ]]; then
                lookup_candidates+=("${service%.service}")
            else
                lookup_candidates+=("$service.service")
            fi

            for candidate in "${lookup_candidates[@]}"; do
                if [[ -n "${available_services[$candidate]}" ]]; then
                    found=true
                    break
                fi
            done

            if [ "$found" = true ]; then
                info "  - $service: OK"
            else
                info "  - $service: Not Found"
                missing_services+=("$service")
            fi
        fi
    done < services.txt

    if [ ${#missing_services[@]} -ne 0 ]; then
        error "The following services are not available: ${missing_services[*]}. Please correct services.txt and try again."
    fi
}

# --- Filesystem Update ---
update_iso_filesystem() {
    info "Updating the ISO's internal filesystem..."

    local squashfs_root="$WORKDIR/squashfs_root"
    local squashfs_file=$(find "$CUSTOM_ISO_DIR" -name 'openSUSE-Leap-15.6-x86_64-*.squashfs' | head -n 1)

    if [ -z "$squashfs_file" ]; then
        # Look for the root image if squashfs isn't found
        squashfs_file=$(find "$CUSTOM_ISO_DIR" -name 'root' -type f | head -n 1)
        if [ -z "$squashfs_file" ]; then
            error "Could not find the SquashFS or root image file in the ISO."
        fi
    fi


    info "Unpacking the filesystem..."
    sudo rm -rf "$squashfs_root"
    mkdir -p "$squashfs_root"
    sudo unsquashfs -d "$squashfs_root" "$squashfs_file"

    info "Preparing chroot environment..."
    sudo mkdir -p "$squashfs_root/proc" "$squashfs_root/dev" "$squashfs_root/sys"
    sudo mount --bind /proc "$squashfs_root/proc"
    sudo mount --bind /dev "$squashfs_root/dev"
    sudo mount --bind /sys "$squashfs_root/sys"

    cleanup_chroot_mounts() {
        local mounts=(
            "$squashfs_root/proc"
            "$squashfs_root/dev"
            "$squashfs_root/sys"
        )

        local mountpoint
        for mountpoint in "${mounts[@]}"; do
            if awk -v m="$mountpoint" '$2==m { exit 0 } END { exit 1 }' /proc/mounts; then
                sudo umount "$mountpoint"
            fi
        done
    }
    trap cleanup_chroot_mounts EXIT ERR

    # Copy resolv.conf for network access inside chroot
    sudo cp /etc/resolv.conf "$squashfs_root/etc/resolv.conf"

    # Validate packages and services before updating
    validate_packages "$squashfs_root"
    validate_services "$squashfs_root"

    info "Updating repositories and packages inside chroot..."
    sudo chroot "$squashfs_root" /bin/bash -c "
        set -e
        zypper --non-interactive refresh
        zypper --non-interactive update -y
        # Clean up zypper cache
        zypper --non-interactive clean --all
    "

    info "Unmounting chroot environment..."
    cleanup_chroot_mounts
    trap - EXIT ERR

    info "Repacking the filesystem..."
    sudo mksquashfs "$squashfs_root" "$squashfs_file" -no-xattrs -comp xz

    info "Filesystem update complete."
}


# --- ISO Creation ---
create_final_iso() {
    info "Creating the final customized ISO..."

    # Modify bootloader configuration for automated installation
    local grub_cfg="$CUSTOM_ISO_DIR/boot/x86_64/loader/grub.cfg"
    if [ -f "$grub_cfg" ]; then
        info "Modifying bootloader configuration..."
        # Add a new menu entry for AutoYaST and make it the default
        sed -i 's/set default=.*/set default="autoyast"/' "$grub_cfg"
        sed -i '/### END /i menuentry "AutoYaST Installation" --id autoyast { \\\n  linuxefi /boot/x86_64/loader/linux autoyast=file:///autoinst.xml \\\n  initrdefi /boot/x86_64/loader/initrd \\\n}' "$grub_cfg"
    else
        error "Could not find grub.cfg at $grub_cfg"
    fi

    # Create the ISO
    sudo xorriso -as mkisofs \
      -iso-level 3 \
      -full-iso9660-filenames \
      -volid "openSUSE-Leap-15.6-Custom" \
      -eltorito-boot boot/x86_64/loader/eltorito.bin \
      -eltorito-catalog boot/x86_64/loader/boot.cat \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      -eltorito-alt-boot \
      -e boot/x86_64/efi \
      -no-emul-boot \
      -o "$FINAL_ISO_NAME" \
      "$CUSTOM_ISO_DIR"

    info "Successfully created custom ISO: $FINAL_ISO_NAME"
}

# --- Cleanup ---
cleanup() {
    info "Cleaning up the workspace..."
    sudo rm -rf "$WORKDIR"
    info "Cleanup complete."
}


# --- Main Execution ---
main() {
    check_dependencies
    download_iso
    setup_workspace
    generate_autoyast_xml
    update_iso_filesystem
    create_final_iso
    cleanup

    info "Custom ISO creation process finished successfully."
}

main "$@"
