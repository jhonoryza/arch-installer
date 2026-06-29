#!/usr/bin/env bash
set -euo pipefail

# Arch Linux → MATE + Ubuntu 10.10 look (Ambiance / Humanity)
# Usage (from live ISO):  curl -sL <url> | bash
# or save as install.sh and run: bash install.sh

DISK="/dev/sda"
MOUNT="/mnt"
USERNAME="mateuser"
PASSWORD="mateuser"
ROOT_PASS="arch"
LOCALE="en_US.UTF-8"
KEYMAP="us"
HOSTNAME="arch-ubuntu"
TIMEZONE="Asia/Jakarta"

log()  { echo -e "\033[1;32m[*]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[✗]\033[0m $*"; exit 1; }

checks() {
  [[ $EUID -eq 0 ]] || die "Must run as root"
  command -v pacstrap &>/dev/null || die "Not an Arch live ISO (no pacstrap)"
  command -v arch-chroot &>/dev/null || die "No arch-chroot found"
  log "Running as root on Arch live ISO"
}

partition_disk() {
  log "Partitioning $DISK (full disk)"
  # Unmount any leftover mounts
  umount "${DISK}1" 2>/dev/null || true
  umount "$MOUNT" 2>/dev/null || true
  # Use fdisk (MBR)
  (
    echo "o"
    echo "n"
    echo "p"
    echo "1"
    echo ""
    echo ""
    echo "w"
  ) | fdisk "$DISK"
  sleep 3
  partprobe "$DISK" 2>/dev/null || true
  sleep 2
  # Wait for partition node to appear
  for i in $(seq 1 10); do
    [[ -b "${DISK}1" ]] && break
    sleep 1
  done
  [[ -b "${DISK}1" ]] || die "Partition ${DISK}1 not found"
  mkfs.ext4 -F -L archroot "${DISK}1"
  log "Partition ${DISK}1 created and formatted"
}

mount_system() {
  log "Mounting ${DISK}1 -> $MOUNT"
  mkdir -p "$MOUNT"
  mount "${DISK}1" "$MOUNT"
  timedatectl set-ntp true
}

pacstrap_base() {
  log "Installing base system (~920 MB download)"
  # Pre-install providers to avoid interactive prompts
  pacman -S --noconfirm iptables mkinitcpio 2>/dev/null || true
  pacstrap "$MOUNT" \
    base linux linux-firmware base-devel nano grub sudo \
    reflector \
    networkmanager network-manager-applet \
    xorg xorg-xinit xorg-xset \
    lightdm lightdm-gtk-greeter \
    mate mate-extra \
    ttf-ubuntu-font-family xcursor-vanilla-dmz \
    adwaita-icon-theme \
    iptables mkinitcpio \
    --noconfirm
  log "Base system installed"
}

generate_fstab() {
  genfstab -U "$MOUNT" >> "$MOUNT/etc/fstab"
  log "fstab generated"
}

copy_self() {
  # Copy this script into chroot so it can run post-install steps
  local SRC="${BASH_SOURCE[0]}"
  [[ -f "$SRC" ]] && cp "$SRC" "$MOUNT/root/install.sh"
  log "Script copied to /root/install.sh in installed system"
}

chroot_configure() {
  log "Entering chroot for system configuration..."
  arch-chroot "$MOUNT" env ROOT_PASS="$ROOT_PASS" PASSWORD="$PASSWORD" bash << 'INCHROOT'
set -e

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
export LANG=en_US.UTF-8

ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
hwclock --systohc

echo "arch-ubuntu" > /etc/hostname

cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   arch-ubuntu
HOSTS

# Users
useradd -m -s /bin/bash -c "MATE User" -G wheel,audio,video,optical,storage mateuser
echo "root:$ROOT_PASS" | chpasswd
echo "mateuser:$PASSWORD" | chpasswd
echo "mateuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/mateuser
chmod 0440 /etc/sudoers.d/mateuser

# GRUB
grub-install "$DISK" --target=i386-pc
grub-mkconfig -o /boot/grub/grub.cfg

# Services
systemctl enable NetworkManager
systemctl enable lightdm
systemctl enable sshd

# LightDM
mkdir -p /etc/lightdm
cat > /etc/lightdm/lightdm.conf << 'LIGHTDM'
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=mate
autologin-user=mateuser
autologin-user-timeout=0
session-wrapper=/etc/lightdm/Xsession
LIGHTDM

cat > /etc/lightdm/lightdm-gtk-greeter.conf << 'GREETER'
[greeter]
theme-name = Ambiance
icon-theme-name = Humanity
font-name = Ubuntu 10
cursor-theme-name = Vanilla-DMZ
GREETER

# Theme config for mateuser
su -s /bin/bash mateuser << 'USERCFG'
mkdir -p ~/.config/gtk-3.0

cat > ~/.config/gtk-3.0/settings.ini << 'GTK3'
[Settings]
gtk-theme-name = Ambiance
gtk-icon-theme-name = Humanity
gtk-font-name = Ubuntu 10
gtk-cursor-theme-name = Vanilla-DMZ
gtk-toolbar-style = GTK_TOOLBAR_BOTH_HORIZ
gtk-toolbar-icon-size = GTK_ICON_SIZE_LARGE_TOOLBAR
gtk-button-images = 1
gtk-menu-images = 1
gtk-enable-event-sounds = 1
gtk-enable-input-feedback-sounds = 1
gtk-xft-antialias = 1
gtk-xft-hinting = 1
gtk-xft-hintstyle = hintfull
GTK3

cat > ~/.gtkrc-2.0 << 'GTK2'
include "/usr/share/themes/Ambiance/gtk-2.0/gtkrc"
gtk-icon-theme-name = "Humanity"
gtk-theme-name = "Ambiance"
gtk-font-name = "Ubuntu 10"
gtk-toolbar-style = "GTK_TOOLBAR_BOTH_HORIZ"
gtk-toolbar-icon-size = "GTK_ICON_SIZE_LARGE_TOOLBAR"
gtk-button-images = 1
gtk-menu-images = 1
gtk-cursor-theme-name = "Vanilla-DMZ"
GTK2

echo "=== Theme configured ==="
USERCFG

# Video driver
pacman -S --noconfirm xf86-video-qxl xf86-video-fbdev xf86-video-vesa

echo "=== Chroot configuration done ==="
INCHROOT
}

build_aur() {
  log "Building AUR packages in chroot (gtk-engine-murrine)"
  arch-chroot "$MOUNT" bash << 'AURBUILD'
set -e
pacman -S --noconfirm base-devel git

useradd -m -s /bin/bash builder 2>/dev/null || true
echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder

mkdir -p /aur
cd /aur

# murrine engine
curl -L -o gtk-engine-murrine.tar.gz \
  "https://aur.archlinux.org/cgit/aur.git/snapshot/gtk-engine-murrine.tar.gz"
tar xzf gtk-engine-murrine.tar.gz
cd gtk-engine-murrine
chown -R builder:builder .
su builder -s /bin/bash -c "cd /aur/gtk-engine-murrine && makepkg -sic --noconfirm --skippgpcheck"

echo "=== AUR packages installed ==="
AURBUILD
}

cleanup() {
  log "Final disk usage:"
  df -h "$MOUNT" | tail -1
}

main() {
  checks
  partition_disk
  mount_system
  pacstrap_base
  generate_fstab
  copy_self
  chroot_configure
  build_aur
  cleanup

  log "=========================================="
  log "  INSTALL COMPLETE"
  log "=========================================="
  log "Reboot and remove the live ISO."
  log "Login: $USERNAME / $PASSWORD"
  log "Root password: $ROOT_PASS"
}

main "$@"
