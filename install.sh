#!/usr/bin/env bash
set -euo pipefail

# Arch Linux → MATE + Ubuntu 10.10 look (Ambiance / Humanity)
# Usage (from live ISO):  bash install.sh
# or piped:                curl -sL <url> | bash

# Defaults (can be overridden by env or during interactive run)
DISK="${DISK:-/dev/sda}"
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

# Partition suffix: NVMe/MMC → p1,  SATA/VirtIO → 1
part1() { local d="$1"; [[ "$d" =~ /nvme[0-9]+n[0-9]+$ || "$d" =~ /mmcblk[0-9]+$ ]] && echo "${d}p1" || echo "${d}1"; }

checks() {
  [[ $EUID -eq 0 ]] || die "Must run as root"
  command -v pacstrap &>/dev/null || die "Not an Arch live ISO (no pacstrap)"
  command -v arch-chroot &>/dev/null || die "No arch-chroot found"

  log "Checking internet connection..."
  if ping -c1 -W5 archlinux.org &>/dev/null; then
    log "Internet OK"
  else
    die "No internet — pacstrap needs a working connection"
  fi

  warn "This script will take approximately 30–60 minutes to complete."
  warn "Make sure you have a stable internet connection."
  echo
  read -rp "Press ENTER to continue or Ctrl+C to abort... " _
  log "Running as root on Arch live ISO"
}

select_disk() {
  echo
  warn "Available disks on this system:"
  # List only whole disks, skip loop devices
  lsblk -d -o NAME,SIZE,TYPE | awk 'NR==1 || $3=="disk"'
  echo
  read -rp "Enter target disk (default: $DISK): " INPUT
  DISK="${INPUT:-$DISK}"
  DISK="${DISK%/}"
  if [[ ! -b "$DISK" ]]; then
    die "Disk $DISK does not exist or is not a block device"
  fi
  # Get size
  SIZE=$(lsblk -d -o SIZE "$DISK" | tail -1)
  warn "Target disk: $DISK ($SIZE)"
  echo
  warn "WARNING: All data on $DISK will be PERMANENTLY ERASED!"
  read -rp "Type 'YES' to confirm: " CONFIRM
  [[ "$CONFIRM" == "YES" ]] || die "Aborted by user"
  export DISK
}

partition_disk() {
  log "Partitioning $DISK (full disk)"
  # Unmount any leftover mounts
  umount "$(part1 "$DISK")" 2>/dev/null || true
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
    [[ -b "$(part1 "$DISK")" ]] && break
    sleep 1
  done
  [[ -b "$(part1 "$DISK")" ]] || die "Partition $(part1 "$DISK") not found"
  mkfs.ext4 -F -L archroot "$(part1 "$DISK")"
  log "Partition $(part1 "$DISK") created and formatted"
}

mount_system() {
  log "Mounting $(part1 "$DISK") -> $MOUNT"
  mkdir -p "$MOUNT"
  mount "$(part1 "$DISK")" "$MOUNT"
  timedatectl set-ntp true
}

pacstrap_base() {
  log "Installing base system (~1.3 GB download)"
  # Pre-install providers to avoid interactive prompts
  pacman -S --noconfirm iptables mkinitcpio pciutils 2>/dev/null || true
  # NOTE: groups (xorg, mate, mate-extra) are installed later in chroot
  # to avoid interactive group-member prompts that --noconfirm does not skip.
  pacstrap "$MOUNT" \
    base linux linux-firmware base-devel nano grub sudo \
    reflector \
    networkmanager network-manager-applet \
    lightdm lightdm-gtk-greeter \
    ttf-ubuntu-font-family xcursor-vanilla-dmz \
    adwaita-icon-theme \
    iptables mkinitcpio \
    mesa pciutils xdg-utils \
    xf86-video-intel xf86-video-amdgpu xf86-video-ati xf86-video-nouveau \
    vlc \
    nvim vim \
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
  if [[ -f "$SRC" && "$SRC" != "/dev/stdin" ]]; then
    cp "$SRC" "$MOUNT/root/install.sh"
  else
    # Piped from stdin — re-fetch from URL if available
    curl -sL "https://raw.githubusercontent.com/$(git config --get remote.origin.url 2>/dev/null | sed 's|.*/||' 2>/dev/null || true)/master/install.sh" -o "$MOUNT/root/install.sh" 2>/dev/null || true
    # Fallback: write the script content directly (best-effort)
    cat > "$MOUNT/root/install.sh" << 'SCRIPTEOF'
#!/usr/bin/env bash
# install.sh was originally piped — re-run from a file for full support
SCRIPTEOF
    chmod +x "$MOUNT/root/install.sh" 2>/dev/null || true
  fi
  log "Script copied to /root/install.sh in installed system"
}

chroot_configure() {
  log "Entering chroot for system configuration..."
  arch-chroot "$MOUNT" env ROOT_PASS="$ROOT_PASS" PASSWORD="$PASSWORD" DISK="$DISK" bash << INCHROOT
set -e

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" >> /etc/vconsole.conf
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

# Update mirrors via reflector
reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null || true

# Users
useradd -m -s /bin/bash -c "MATE User" -G wheel,audio,video,optical,storage mateuser
echo "root:$ROOT_PASS" | chpasswd
echo "mateuser:$PASSWORD" | chpasswd
echo "mateuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/mateuser
chmod 0440 /etc/sudoers.d/mateuser

# Desktop groups (installed here to avoid interactive prompts during pacstrap)
pacman -S --noconfirm xorg-server xorg-xinit xorg-xset xdg-utils pciutils mime-types 2>&1 | tail -3 || true
pacman -S --noconfirm mate 2>&1 | tail -3 || true
pacman -S --noconfirm mate-extra 2>&1 | tail -3 || true

# Services
systemctl enable NetworkManager
systemctl enable lightdm
systemctl enable sshd

# LightDM
mkdir -p /etc/lightdm
cat > /etc/lightdm/lightdm.conf << LIGHTDM
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=mate
autologin-user=mateuser
autologin-user-timeout=0
session-wrapper=/etc/lightdm/Xsession
LIGHTDM

cat > /etc/lightdm/lightdm-gtk-greeter.conf << GREETER
[greeter]
theme-name = Ambiance
icon-theme-name = Humanity
font-name = Ubuntu 10
cursor-theme-name = Vanilla-DMZ
GREETER

# Theme config for mateuser
su -s /bin/bash mateuser << USERCFG
mkdir -p ~/.config/gtk-3.0

cat > ~/.config/gtk-3.0/settings.ini << GTK3
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

cat > ~/.gtkrc-2.0 << GTK2
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

# MATE / Marco window manager — Ubuntu 10.10 style (buttons left, Ambiance)
mkdir -p ~/.config
cat > ~/.config/marco-settings.ini << MARCO
[Settings]
theme=Ambiance
titlebar-font=Ubuntu Bold 10
button-layout=close,minimize,maximize:
MARCO

# Set via gsettings as well (overrides the file)
gsettings set org.mate.Marco.general theme Ambiance 2>/dev/null || true
gsettings set org.mate.Marco.general titlebar-font "Ubuntu Bold 10" 2>/dev/null || true
gsettings set org.mate.Marco.general button-layout "close,minimize,maximize:" 2>/dev/null || true

# Desktop background — solid orange-brown like Ubuntu 10.10
gsettings set org.mate.background picture-filename "" 2>/dev/null || true
gsettings set org.mate.background primary-color "#48170E" 2>/dev/null || true
gsettings set org.mate.background color-shading-type "solid" 2>/dev/null || true

# Cursor theme system-wide
gsettings set org.mate.peripherals-mouse cursor-theme "Vanilla-DMZ" 2>/dev/null || true

# MATE panel — Ubuntu 10.10 layout:
#   top panel: menu + clock
#   bottom panel: window list + workspace switcher
gsettings set org.mate.panel default-layout true 2>/dev/null || true
gsettings set org.mate.Marco.general compositing-manager false 2>/dev/null || true

echo "=== Theme configured ==="
USERCFG

# Video driver
pacman -S --noconfirm xf86-video-qxl xf86-video-fbdev xf86-video-vesa

# Swap file (1 GB)
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap defaults 0 0" >> /etc/fstab

# nvim as default editor (it's in /usr/bin from official repo)
ln -sf /usr/bin/nvim /usr/local/bin/vi || true

echo "=== Chroot configuration done ==="
INCHROOT
}

build_aur() {
  log "Building AUR packages (brave, palemoon, sublime-text, ghostty)"
  arch-chroot "$MOUNT" bash << 'AURBUILD'
set -e
set -o pipefail

pacman -S --noconfirm base-devel git curl

useradd -m -s /bin/bash builder 2>/dev/null || true
echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder

mkdir -p /aur
cd /aur

# ── Helper: download, extract, and build an AUR package ──────────────
# Non-fatal: prints a warning and continues on any failure.
build_pkg() {
  local name="$1"
  local extra_flags="${2:-}"
  if pacman -Q "$name" &>/dev/null; then
    echo "=== $name already installed, skipping ==="
    return 0
  fi
  echo "=== Building $name ==="
  if ! curl -sfL -o "$name.tar.gz" "https://aur.archlinux.org/cgit/aur.git/snapshot/$name.tar.gz"; then
    echo "WARNING: Failed to download $name AUR snapshot, skipping..."
    return 1
  fi
  if ! tar xzf "$name.tar.gz"; then
    echo "WARNING: Failed to extract $name (package may not exist on AUR), skipping..."
    rm -f "$name.tar.gz"
    return 1
  fi
  cd "$name"
  chown -R builder:builder .
  if su builder -s /bin/bash -c "cd /aur/$name && makepkg -sic --noconfirm --skippgpcheck $extra_flags" 2>&1 | tail -10; then
    echo "=== $name built successfully ==="
  else
    echo "WARNING: $name makepkg failed, continuing with next package..."
  fi
  cd /aur
}

# ── Helper: build with PKGBUILD patching before makepkg ──────────────
# Patches the PKGBUILD (via sed), then builds with --skipintegrity
# since patching invalidates checksums.
build_pkg_patched() {
  local name="$1"
  local patch_sed="$2"
  if pacman -Q "$name" &>/dev/null; then
    echo "=== $name already installed, skipping ==="
    return 0
  fi
  echo "=== Building $name (patched) ==="
  if ! curl -sfL -o "$name.tar.gz" "https://aur.archlinux.org/cgit/aur.git/snapshot/$name.tar.gz"; then
    echo "WARNING: Failed to download $name AUR snapshot, skipping..."
    return 1
  fi
  if ! tar xzf "$name.tar.gz"; then
    echo "WARNING: Failed to extract $name, skipping..."
    rm -f "$name.tar.gz"
    return 1
  fi
  cd "$name"
  # Apply patch to PKGBUILD
  eval "$patch_sed"
  # Rename any versioned source files to match the patched version
  for f in *34.1.0*; do
    [[ -e "$f" ]] && mv "$f" "${f/34.1.0/34.3.1}" 2>/dev/null || true
  done
  chown -R builder:builder .
  # Use --skipinteg because patching invalidates checksums/GPG sigs
  if su builder -s /bin/bash -c "cd /aur/$name && makepkg -sic --noconfirm --skipinteg" 2>&1 | tail -10; then
    echo "=== $name built successfully ==="
  else
    echo "WARNING: $name makepkg failed, continuing with next package..."
  fi
  cd /aur
}

# ── Package builds (non-fatal: one failure does not abort the rest) ──
set +e

# gtk2 (AUR — needed by themes & palemoon)
build_pkg gtk2

# brave-bin
build_pkg brave-bin

# palemoon-bin — AUR package is flagged out-of-date (34.1.0);
# bump to 34.3.1 (latest) so the mirror URL resolves.
build_pkg_patched palemoon-bin \
  "sed -i 's/34\\.1\\.0/34.3.1/g' PKGBUILD"

# sublime-text-4 (replaces deleted 'sublime-text'; Provides: sublime-text)
build_pkg sublime-text-4

# ghostty-nightly-bin (replaces deleted 'ghostty-bin'; Provides: ghostty)
# Must build its two AUR dependencies first.
build_pkg ghostty-terminfo-nightly-bin
build_pkg ghostty-shell-integration-nightly-bin
build_pkg ghostty-nightly-bin

# murrine engine
build_pkg gtk-engine-murrine

# humanity-icon-theme
build_pkg humanity-icon-theme

# ubuntu-themes (Ambiance & Radiance)
build_pkg ubuntu-themes

set -e

echo "=== All AUR packages attempted ==="
AURBUILD

  # Clean up any leftover chroot mounts (arch-chroot may leave /proc,
  # /sys, /dev busy if a build was interrupted).
  umount -l "$MOUNT/proc" 2>/dev/null || true
  umount -l "$MOUNT/sys"  2>/dev/null || true
  umount -l "$MOUNT/dev"  2>/dev/null || true
}

configure_default_apps() {
  log "Configuring default applications..."
  arch-chroot "$MOUNT" bash << 'DEFAULTS'
set -e

# Set nvim as default vi/vim
ln -sf /usr/bin/nvim /usr/local/bin/vim 2>/dev/null || true
ln -sf /usr/bin/nvim /usr/local/bin/vi 2>/dev/null || true

su -s /bin/bash mateuser << 'APPS'
# Brave as default browser
xdg-mime default brave-browser.desktop x-scheme-handler/http 2>/dev/null || true
xdg-mime default brave-browser.desktop x-scheme-handler/https 2>/dev/null || true
xdg-mime default brave-browser.desktop text/html 2>/dev/null || true

# VLC as default video/music
xdg-mime default vlc.desktop video/* 2>/dev/null || true
xdg-mime default vlc.desktop audio/* 2>/dev/null || true

# Sublime Text as default text editor
xdg-mime default sublime_text.desktop text/plain 2>/dev/null || true

# Ghostty as default terminal in MATE
gsettings set org.mate.applications-terminal exec ghostty 2>/dev/null || true
gsettings set org.mate.applications-terminal exec-arg -e 2>/dev/null || true
mkdir -p ~/.config/gtk-3.0

echo "=== Default apps configured ==="
APPS
DEFAULTS
  log "Default applications configured"
}

cleanup() {
  log "Final disk usage:"
  df -h "$MOUNT" | tail -1
}

main() {
  checks
  select_disk
  partition_disk
  mount_system
  pacstrap_base
  generate_fstab
  copy_self
  chroot_configure

  log "Installing GRUB bootloader to $DISK..."
  mount --bind /dev "$MOUNT/dev"
  mount --bind /proc "$MOUNT/proc"
  mount --bind /sys "$MOUNT/sys"
  arch-chroot "$MOUNT" grub-install "$DISK" --target=i386-pc
  arch-chroot "$MOUNT" grub-mkconfig -o /boot/grub/grub.cfg
  umount "$MOUNT/dev" "$MOUNT/proc" "$MOUNT/sys" 2>/dev/null || true
  # Lazy-unmount anything still busy (arch-chroot may leave /proc, /sys active)
  umount -l "$MOUNT/dev"  2>/dev/null || true
  umount -l "$MOUNT/proc" 2>/dev/null || true
  umount -l "$MOUNT/sys"  2>/dev/null || true
  log "GRUB installed"

  build_aur
  configure_default_apps
  cleanup

  log "=========================================="
  log "  INSTALL COMPLETE"
  log "=========================================="
  log "Reboot and remove the live ISO."
  log "Login: $USERNAME / $PASSWORD"
  log "Root password: $ROOT_PASS"
}

main "$@"
