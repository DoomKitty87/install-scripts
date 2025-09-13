# Function definitions

# Microcode detector from easy-arch.
microcode_detector () {
    CPU=$(grep vendor_id /proc/cpuinfo)
    if [[ "$CPU" == *"AuthenticAMD"* ]]; then
        echo "An AMD CPU has been detected, the AMD microcode will be installed."
        microcode="amd-ucode"
    else
        echo "An Intel CPU has been detected, the Intel microcode will be installed."
        microcode="intel-ucode"
    fi
}

# This version is intended to install alongside an existing OS, using rEFInd as the boot manager.

# Main

# Clear the terminal
clear

# Welcome message
echo "Arch Installer v1"

# Get data from user

# Ask for LUKS password
echo "Please enter the LUKS password to use for the installation:"
read -r -s lukspass

# Ask for hostname
echo "Please enter the hostname to use for the installation:"
read -r hostname

# Ask for root password
echo "Please enter the root password to use for the installation:"
read -r -s rootpass

# Ask for username
echo "Please enter the username to create for the installation:"
read -r username

# Ask for user password
echo "Please enter the password for the user $username to use for the installation:"
read -r -s userpass

echo "Enter ESP partition (e.g. nvme0n1p1 or sda1):"
read -r ESP_PART
ESP="/dev/$ESP_PART"
echo "Using $ESP as ESP partition"

echo "Enter Windows partition (e.g. nvme0n1p3 or sda3):"
read -r WIN_PART
WIN="/dev/$WIN_PART"
echo "Using $WIN as Windows partition"

echo "How much space would you like to allocate to this installation (in MiB)?"
read -r SIZE

WIN_NUM=$(echo "$WIN_PART" | grep -o '[0-9]*$')
WIN_END=$(parted -sm "$DISK" unit MiB print | awk -F: -v num=$WIN_NUM '$1==num {print $3}' | sed 's/MiB//')
CRYPTROOT_START=$((WIN_END + 1))

echo "Creating CRYPTROOT partition..."
parted -s "$DISK" \
    mkpart CRYPTROOT "${CRYPTROOT_START}MiB" "$((CRYPTROOT_START + SIZE))MiB"

CRYPTROOT="/dev/disk/by-partlabel/CRYPTROOT"

# Refresh partition table in kernel
partprobe "$DISK"

# Create LUKS container
echo "Creating LUKS container"
echo -n "$lukspass" | cryptsetup luksFormat "$CRYPTROOT" -d - &>/dev/null
echo -n "$lukspass" | cryptsetup open "$CRYPTROOT" cryptroot -d -
BTRFS="/dev/mapper/cryptroot"

# Format LUKS container
echo "Formatting LUKS container with BTRFS"
mkfs.btrfs "$BTRFS" &>/dev/null
mount "$BTRFS" /mnt

# Create BTRFS subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
# ^ This is the recommended layout by Snapper that people seem to agree with. It should work with Timeshift
# Uses more space than necessary I think, because only var/log is excluded from snapshots when you can exclude other directories too (according to the wiki)

# Unmount BTRFS root
umount /mnt

# Mount BTRFS subvolumes
mountopts="ssd,noatime,compress-force=zstd:3,discard=async"
mount -o "$mountopts",subvol=@ "$BTRFS" /mnt

mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -o "$mountopts",subvol=@home "$BTRFS" /mnt/home
mount -o "$mountopts",subvol=@snapshots "$BTRFS" /mnt/.snapshots
mount -o "$mountopts",subvol=@var_log "$BTRFS" /mnt/var/log

# Set No_COW for var/log (idk I saw this somewhere. It might be a good thing I guess)
chattr +C /mnt/var/log

# Mount ESP
mount "$ESP" /mnt/boot/

# Installation

# Arch wiki says that you should check the mirror list. I'm not doing that now but I don't want to forget it.

# Check which microcode to install
microcode_detector

# Install base system
echo "Installing base system"
kernel="linux"
pacstrap -K /mnt base linux linux-firmware $microcode &>/dev/null

# Set hostname
echo "Setting hostname to $hostname"
echo "$hostname" > /mnt/etc/hostname

# Set hosts file
echo "Setting up /etc/hosts"
cat > /mnt/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $hostname.localdomain $hostname
EOF

# Install networkmanager
echo "Installing NetworkManager"
pacstrap -K /mnt networkmanager &>/dev/null
systemctl enable NetworkManager --root=/mnt &>/dev/null

# Install some utilities
pacstrap -K /mnt vim sudo git openssh reflector &>/dev/null

# Fstab generation
echo "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# Configure /etc/mkinitcpio.conf
echo "Configuring mkinitcpio"
cat > /mnt/etc/mkinitcpio.conf <<EOF
HOOKS=(systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems)
EOF

# rEFInd
echo "Setting up rEFInd"
pacstrap -K /mnt refind &>/dev/null
refind-install --root /mnt # &>/dev/null

# Set rEFInd kernel options
echo "Setting rEFInd kernel options"
UUID=$(blkid -s UUID -o value $CRYPTROOT)
cat > /mnt/boot/refind_linux.conf <<EOF
    "Standard" "root=/dev/mapper/cryptroot rd.luks.name=$UUID=cryptroot rootflags=subvol=@ rw quiet loglevel=3"
EOF

# Chroot into new system
arch-chroot /mnt /bin/bash <<EOF
    # Setting timezone
    ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
    hwclock --systohc

    # Enable systemd-timesyncd
    echo "Enabling systemd-timesyncd"
    systemctl enable systemd-timesyncd.service

    # Set locale
    sed -i "/^#en_US.UTF-8/s/^#//" /etc/locale.gen
    locale-gen &>/dev/null
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    echo "KEYMAP=us" > /etc/vconsole.conf

    # Generating a new initramfs.
    mkinitcpio -P &>/dev/null
EOF

# Set root password
echo "Setting root password"
echo "root:$rootpass" | arch-chroot /mnt chpasswd

# Create user
echo "Creating user $username"
echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$username"
echo "$username:$userpass" | arch-chroot /mnt chpasswd

# Enable services
services=(reflector.timer btrfs-scrub@-.timer btrfs-scrub@home.timer btrfs-scrub@var-log.timer btrfs-scrub@\\x2esnapshots.timer systemd-oomd)
for service in "${services[@]}"; do
    systemctl enable "$service" --root=/mnt &>/dev/null
done

# Consider doing zram later idk

# Done
echo "Installation finished"
exit