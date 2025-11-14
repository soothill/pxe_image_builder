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

cleanup_chroot_mounts() {
    local path
    for path in "$@"; do
        if [ -n "$path" ] && mountpoint -q "$path" 2>/dev/null; then
            sudo umount "$path"
        fi
    done
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

# Wait for network to be available (with timeout and backoff)
NETWORK_CHECK_URL="\${NETWORK_CHECK_URL:-https://download.opensuse.org}"
max_attempts=20
attempt=1
wait_time=2
while (( attempt <= max_attempts )); do
  if curl --silent --head --connect-timeout 5 --max-time 10 "\$NETWORK_CHECK_URL" >/dev/null; then
    break
  fi

  if (( attempt == max_attempts )); then
    echo "Warning: Unable to confirm network connectivity after \${max_attempts} attempts, continuing." >&2
    break
  fi

  sleep "\$wait_time"
  if (( wait_time < 60 )); then
    wait_time=\$(( wait_time * 2 ))
    if (( wait_time > 60 )); then
      wait_time=60
    fi
  fi
  attempt=\$(( attempt + 1 ))
done

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

    local -a packages=()
    mapfile -t packages < <( { grep -Ev '^\s*(#|$)' packages.txt || true; } )
    if [ ${#packages[@]} -eq 0 ]; then
        return
    fi

    local -a quoted_packages=()
    local pkg
    for pkg in "${packages[@]}"; do
        quoted_packages+=("$(printf '%q' "$pkg")")
    done

    local zypper_cmd="zypper --non-interactive info -t package ${quoted_packages[*]}"
    local output
    if ! output=$(sudo chroot "$1" /bin/bash -c "$zypper_cmd" 2>&1); then
        info "  zypper reported issues while validating packages; analyzing output for missing entries."
    fi

    local -a missing_packages=()
    for pkg in "${packages[@]}"; do
        if grep -Fq "Information for package ${pkg}:" <<<"$output"; then
            info "  - $pkg: OK"
        else
            info "  - $pkg: Not Found"
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -ne 0 ]; then
        error "The following packages are not available: ${missing_packages[*]}. Please correct packages.txt and try again."
    fi
}

validate_services() {
    info "Validating services..."
    if [ ! -f "services.txt" ]; then
        return
    fi

    local -a services=()
    mapfile -t services < <( { grep -Ev '^\s*(#|$)' services.txt || true; } )
    if [ ${#services[@]} -eq 0 ]; then
        return
    fi

    local root="$1"
    local -A available_services=()
    local systemctl_output
    if systemctl_output=$(sudo systemctl --root "$root" --no-legend --no-pager list-unit-files --type=service 2>/dev/null); then
        while read -r unit _; do
            [ -z "$unit" ] && continue
            unit="${unit%.service}"
            available_services["$unit"]=1
        done <<< "$systemctl_output"
    else
        info "systemctl --root unavailable, falling back to service file scan."
        local dir
        for dir in "$root/usr/lib/systemd/system" "$root/etc/systemd/system" "$root/lib/systemd/system"; do
            if [ -d "$dir" ]; then
                while IFS= read -r file; do
                    local unit
                    unit=$(basename "$file")
                    unit="${unit%.service}"
                    [ -n "$unit" ] && available_services["$unit"]=1
                done < <(sudo find "$dir" -type f -name '*.service' 2>/dev/null)
            fi
        done
    fi

    local -a missing_services=()
    local service
    for service in "${services[@]}"; do
        local normalized="${service%.service}"
        if [[ -n "${available_services[$normalized]}" ]]; then
            info "  - $service: OK"
        else
            info "  - $service: Not Found"
            missing_services+=("$service")
        fi
    done

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
    trap "cleanup_chroot_mounts '$squashfs_root/proc' '$squashfs_root/dev' '$squashfs_root/sys'" EXIT INT TERM

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
    cleanup_chroot_mounts "$squashfs_root/proc" "$squashfs_root/dev" "$squashfs_root/sys"
    trap - EXIT INT TERM

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
