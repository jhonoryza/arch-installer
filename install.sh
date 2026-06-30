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

log()  { echo -e "033[1;32m[*]033[0m $*"; }
warn() { echo -e "033[1;33m[!]033[0m $*"; }
die()  { echo -e "033[1;31m[✗]033[0m $*"; exit 1; }

# Partition suffix: NVMe/MMC → p1,  SATA/VirtIO → 1
part1() { local d="$1"; [[ "$d" =~ /nvme[0-9]+n[0-9]+$ || "$d" =~ /mmcblk[0-9]+$ ]] && echo "${d}p1" || echo "${d}1"; }
part2() { local d="$1"; [[ "$d" =~ /nvme[0-9]+n[0-9]+$ || "$d" =~ /mmcblk[0-9]+$ ]] && echo "${d}p2" || echo "${d}2"; }

# Detect boot mode: UEFI if /sys/firmware/efi/efivars exists, else BIOS/Legacy
detect_boot_mode() {
  if [[ -d /sys/firmware/efi/efivars ]]; then
    UEFI=1
    log "Boot mode: UEFI (GPT + EFI System Partition)"
  else
    UEFI=0
    log "Boot mode: BIOS/Legacy (MBR)"
  fi
}

# ── Desktop environment selection ──────────────────────────────────
select_desktops() {
  echo
  warn "Select desktop environments to install:"
  echo "  1. MATE     (Ubuntu 10.10 custom theme)"
  echo "  2. Hyprland (modern dynamic tiling Wayland)"
  echo "  3. Sway     (i3-compatible tiling Wayland)"
  echo
  read -rp "Enter space-separated numbers [default: 1]: " DESKTOP_CHOICES
  DESKTOP_CHOICES="${DESKTOP_CHOICES:-1}"

  # Reset flags
  INSTALL_MATE=0 INSTALL_HYPR=0 INSTALL_SWAY=0
  for c in $DESKTOP_CHOICES; do
    case "$c" in
      1) INSTALL_MATE=1 ;;
      2) INSTALL_HYPR=1 ;;
      3) INSTALL_SWAY=1 ;;
      *) warn "Unknown option: $c — skipping" ;;
    esac
  done

  # At least one DE required
  if (( INSTALL_MATE + INSTALL_HYPR + INSTALL_SWAY == 0 )); then
    die "At least one desktop environment must be selected"
  fi

  # Show selected DEs
  echo
  log "Selected DEs:"
  (( INSTALL_MATE )) && echo "  - MATE"
  (( INSTALL_HYPR )) && echo "  - Hyprland"
  (( INSTALL_SWAY )) && echo "  - Sway"

  # Default session
  echo
  read -rp "Which should be the default? [mate/hyprland/sway]: " DEFAULT_DE
  DEFAULT_DE="${DEFAULT_DE:-mate}"

  # Validate default
  case "$DEFAULT_DE" in
    mate)     (( INSTALL_MATE )) || die "MATE not selected!" ;;
    hyprland) (( INSTALL_HYPR )) || die "Hyprland not selected!" ;;
    sway)     (( INSTALL_SWAY )) || die "Sway not selected!" ;;
    *) die "Invalid default: $DEFAULT_DE (use mate, hyprland, or sway)" ;;
  esac

  log "Default session: $DEFAULT_DE"
  export INSTALL_MATE INSTALL_HYPR INSTALL_SWAY DEFAULT_DE
}

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
  umount "$MOUNT/boot/efi" 2>/dev/null || true
  umount "$MOUNT/boot" 2>/dev/null || true
  umount "$(part1 "$DISK")" 2>/dev/null || true
  umount "$(part2 "$DISK")" 2>/dev/null || true
  umount "$MOUNT" 2>/dev/null || true

  if [[ "$UEFI" -eq 1 ]]; then
    # ── UEFI: GPT with EFI System Partition (FAT32) + root (ext4) ──
    log "Creating GPT partition table with EFI System Partition"
    (
      echo "g"           # create new GPT partition table
      echo "n"           # new partition
      echo "1"           # partition 1 (ESP)
      echo ""            # default start
      echo "+512M"       # 512MB for ESP
      echo "t"           # change type
      echo "1"           # EFI System type
      echo "n"           # new partition
      echo "2"           # partition 2 (root)
      echo ""            # default start
      echo ""            # rest of disk
      echo "w"           # write
    ) | fdisk "$DISK"
    sleep 3
    partprobe "$DISK" 2>/dev/null || true
    sleep 2
    # Wait for partition nodes to appear
    for i in $(seq 1 10); do
      [[ -b "$(part1 "$DISK")" && -b "$(part2 "$DISK")" ]] && break
      sleep 1
    done
    [[ -b "$(part1 "$DISK")" ]] || die "ESP partition $(part1 "$DISK") not found"
    [[ -b "$(part2 "$DISK")" ]] || die "Root partition $(part2 "$DISK") not found"
    # Format: ESP as FAT32, root as ext4
    mkfs.fat -F32 -n EFIBOOT "$(part1 "$DISK")"
    mkfs.ext4 -F -L archroot "$(part2 "$DISK")"
    log "ESP $(part1 "$DISK") (FAT32) + root $(part2 "$DISK") (ext4) created"
  else
    # ── BIOS/Legacy: MBR with single root partition ──
    log "Creating MBR partition table (BIOS/Legacy)"
    (
      echo "o"           # create new DOS/MBR partition table
      echo "n"           # new partition
      echo "p"           # primary
      echo "1"           # partition 1
      echo ""            # default start
      echo ""            # rest of disk
      echo "w"           # write
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
    log "Partition $(part1 "$DISK") created and formatted (MBR)"
  fi
}

mount_system() {
  if [[ "$UEFI" -eq 1 ]]; then
    # UEFI: mount root, then ESP at /boot/efi
    log "Mounting $(part2 "$DISK") -> $MOUNT, $(part1 "$DISK") -> $MOUNT/boot/efi"
    mkdir -p "$MOUNT"
    mount "$(part2 "$DISK")" "$MOUNT"
    mkdir -p "$MOUNT/boot/efi"
    mount "$(part1 "$DISK")" "$MOUNT/boot/efi"
  else
    # BIOS: single partition
    log "Mounting $(part1 "$DISK") -> $MOUNT"
    mkdir -p "$MOUNT"
    mount "$(part1 "$DISK")" "$MOUNT"
  fi
  timedatectl set-ntp true
}

pacstrap_base() {
  log "Installing base system (~1.3 GB download)"
  # Pre-install providers to avoid interactive prompts
  pacman -S --noconfirm iptables mkinitcpio pciutils 2>/dev/null || true
  # NOTE: groups (xorg, mate, mate-extra) are installed later in chroot
  # to avoid interactive group-member prompts that --noconfirm does not skip.
  # UEFI-only packages (efibootmgr for boot entries, dosfstools for FAT32)
  local uefi_pkgs=""
  [[ "$UEFI" -eq 1 ]] && uefi_pkgs="efibootmgr dosfstools"
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
    $uefi_pkgs \
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
  arch-chroot "$MOUNT" env ROOT_PASS="$ROOT_PASS" PASSWORD="$PASSWORD" DISK="$DISK" \
    INSTALL_MATE="$INSTALL_MATE" INSTALL_HYPR="$INSTALL_HYPR" \
    INSTALL_SWAY="$INSTALL_SWAY" DEFAULT_DE="$DEFAULT_DE" \
    bash << 'INCHROOT'
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

# ── Desktop Environments ──────────────────────────────────────────
# Xorg (needed by MATE)
if [ "$INSTALL_MATE" -eq 1 ]; then
  echo ">>> Installing Xorg + MATE..."
  pacman -S --noconfirm xorg-server xorg-xinit xorg-xset xdg-utils pciutils mime-types 2>&1 | tail -3 || true
  pacman -S --noconfirm mate 2>&1 | tail -3 || true
  pacman -S --noconfirm mate-extra 2>&1 | tail -3 || true
fi

# Hyprland (Wayland)
if [ "$INSTALL_HYPR" -eq 1 ]; then
  echo ">>> Installing Hyprland..."
  pacman -S --noconfirm hyprland kitty waybar wofi dunst swaybg 2>&1 | tail -3 || true
fi

# Sway (Wayland)
if [ "$INSTALL_SWAY" -eq 1 ]; then
  echo ">>> Installing Sway..."
  pacman -S --noconfirm sway foot waybar wofi dunst swaybg 2>&1 | tail -3 || true
fi

# Hyprland config
if [ "$INSTALL_HYPR" -eq 1 ]; then
  echo ">>> Writing Hyprland config..."
  mkdir -p /home/mateuser/.config/hypr
  cat > /home/mateuser/.config/hypr/hyprland.conf << 'HYPRCFG'
monitor=,preferred,auto,1
exec-once=waybar & swaybg -i /usr/share/backgrounds/walls/sample.png 2>/dev/null &
input {
    kb_layout=us
    follow_mouse=1
}
general {
    gaps_in=5
    gaps_out=10
    border_size=2
    col.active_border=rgba(ff6600ee)
    col.inactive_border=rgba(595959aa)
}
decoration { rounding=8 }
bind=SUPER,RETURN,exec,kitty
bind=SUPER,Q,killactive
bind=SUPER,M,exit
bind=SUPER,E,exec,wofi --show drun
bind=SUPER,R,exec,wofi --show run
bind=SUPER,V,togglefloating
bind=SUPER,F,fullscreen
bind=SUPER,1,workspace,1
bind=SUPER,2,workspace,2
bind=SUPER,3,workspace,3
bind=SUPER,4,workspace,4
HYPRCFG
  chown -R mateuser:mateuser /home/mateuser/.config/hypr
fi

# Sway config
if [ "$INSTALL_SWAY" -eq 1 ]; then
  echo ">>> Writing Sway config..."
  mkdir -p /home/mateuser/.config/sway
  # Copy default config as base, then customize
  if [ -f /etc/sway/config ]; then
    cp /etc/sway/config /home/mateuser/.config/sway/config
  else
    cat > /home/mateuser/.config/sway/config << 'SWAYCFG'
set $mod Mod4
font pango:monospace 10
set $term foot
bindsym $mod+Return exec $term
bindsym $mod+q kill
bindsym $mod+d exec wofi --show drun
bindsym $mod+r exec wofi --show run
bindsym $mod+v floating toggle
bindsym $mod+f fullscreen
bindsym $mod+Shift+e exit
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bar { position top; status_command waybar }
exec swaybg -i /usr/share/backgrounds/walls/sample.png 2>/dev/null
SWAYCFG
  fi
  chown -R mateuser:mateuser /home/mateuser/.config/sway
fi
echo ">>> Desktop environments installed"

# Services
systemctl enable NetworkManager
systemctl enable lightdm
systemctl enable sshd

# LightDM
mkdir -p /etc/lightdm
cat > /etc/lightdm/lightdm.conf << LIGHTDM
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=${DEFAULT_DE}
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

# MATE theme via dbus-run-session (works in chroot with temporary D-Bus)
# GTK config files already set above — these configure MATE-specific schemas
dbus-run-session bash -c '
  # Interface theme (Ambiance + Humanity + Ubuntu font)
  gsettings set org.mate.interface gtk-theme "Ambiance"
  gsettings set org.mate.interface icon-theme "Humanity"
  gsettings set org.mate.interface cursor-theme "Vanilla-DMZ"
  gsettings set org.mate.interface font-name "Ubuntu 10"

  # Marco window decorations: Ambiance, buttons left (Ubuntu style)
  gsettings set org.mate.Marco.general theme "Ambiance"
  gsettings set org.mate.Marco.general titlebar-font "Ubuntu Bold 10"
  gsettings set org.mate.Marco.general button-layout "close,minimize,maximize:"
  gsettings set org.mate.Marco.general compositing-manager false

  # Desktop background — solid aubergine (#300A24 = Ubuntu 10.10 purple)
  gsettings set org.mate.background picture-filename ""
  gsettings set org.mate.background primary-color "#300A24"
  gsettings set org.mate.background secondary-color "#300A24"
  gsettings set org.mate.background color-shading-type "solid"

  # Cursor (global)
  gsettings set org.mate.peripherals-mouse cursor-theme "Vanilla-DMZ"

  # Panel: default two-panel layout (top + bottom, Ubuntu-style)
  gsettings set org.mate.panel default-layout true

  # === MATE Terminal: white text on aubergine (NOT green!) ===
  TERM_PROF=$(gsettings get org.mate.terminal.global default-profile 2>/dev/null)
  TERM_PROF=$(echo "$TERM_PROF" | tr -dc "[:alnum:]_-")
  if [ -n "$TERM_PROF" ]; then
    gsettings set "org.mate.terminal.profile:/org/mate/terminal/profiles/$TERM_PROF/" 
      background-color "#300A24"
    gsettings set "org.mate.terminal.profile:/org/mate/terminal/profiles/$TERM_PROF/" 
      foreground-color "#FFFFFF"
    gsettings set "org.mate.terminal.profile:/org/mate/terminal/profiles/$TERM_PROF/" 
      use-theme-colors false
  fi
' 2>/dev/null || true

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
# Patches the PKGBUILD (via sed), then builds with --skipinteg
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
build_pkg_patched palemoon-bin 
  "sed -i 's/34.1.0/34.3.1/g' PKGBUILD"

# sublime-text-4 (replaces deleted 'sublime-text'; Provides: sublime-text)
build_pkg sublime-text-4

# ghostty-nightly-bin (replaces deleted 'ghostty-bin'; Provides: ghostty)
# This is a split package base: building it also produces ghostty-terminfo
# and ghostty-shell-integration, so no separate dep builds are needed.
build_pkg ghostty-nightly-bin

# murrine engine
build_pkg gtk-engine-murrine

# humanity-icon-theme
build_pkg humanity-icon-theme

# ubuntu-themes (Ambiance & Radiance)
build_pkg ubuntu-themes

# cloudflare-warp-bin (1.1.1.1 VPN/DNS client)
build_pkg cloudflare-warp-bin

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

install_devtools() {
  log "Installing development tools (go, rust, node, bun, deno, java, php, C/C++, cmake, scrcpy + AI CLI tools)..."
  
  # ── 1. System packages via pacman ──
  arch-chroot "$MOUNT" bash << 'DEVTOOLS1'
set -e
echo "=== Installing system dev packages ==="
pacman -S --noconfirm 
  go cmake deno scrcpy php jdk-openjdk 
  nodejs npm rustup btop nvtop tmux 
  docker docker-compose postgresql mariadb-clients 
  bitwarden-cli

# Sublime Merge (Git GUI from Sublime HQ)
echo ">>> Installing Sublime Merge..."
(
  cd /tmp
  curl -fsSLO https://download.sublimetext.com/sublimehq-pub.gpg || exit 1
  pacman-key --add sublimehq-pub.gpg 2>/dev/null || exit 1
  pacman-key --lsign-key 8A8F901A 2>/dev/null || exit 1
  rm -f sublimehq-pub.gpg
  cat >> /etc/pacman.conf << 'REPO'
[sublime-text]
Server = https://download.sublimetext.com/arch/stable/x86_64
REPO
  pacman -Sy --noconfirm sublime-merge
) || echo "  SKIP: sublime-merge"

# MinIO client (mc) — direct binary download
echo ">>> Installing MinIO client (mc)..."
curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc \
  -o /usr/local/bin/mc 2>/dev/null && {
  chmod +x /usr/local/bin/mc
  echo "  -> mc OK"
} || echo "  SKIP: mc"

# Docker: enable service, add mateuser to docker group
echo ">>> Setting up Docker..."
systemctl enable docker 2>/dev/null || true
usermod -aG docker mateuser 2>/dev/null || true
echo ">>> Docker setup done"

# Wallpaper collection (dharmx/walls)
echo ">>> Cloning wallpaper collection..."
mkdir -p /usr/share/backgrounds
git clone --depth 1 https://github.com/dharmx/walls.git 
  /usr/share/backgrounds/walls 2>/dev/null && echo "  -> walls OK" || echo "  SKIP: walls"

echo "=== System dev packages done ==="
DEVTOOLS1

  # ── Copy tmux config ──
  local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${SCRIPT_DIR}/tmux.conf" ]]; then
    cp "${SCRIPT_DIR}/tmux.conf" "$MOUNT/home/mateuser/.tmux.conf"
    arch-chroot "$MOUNT" chown mateuser:mateuser /home/mateuser/.tmux.conf
    log "tmux config copied"
  else
    warn "tmux.conf not found — using default tmux config"
  fi

  # ── 2. User-level tools (curl + npm installers) ──
  arch-chroot "$MOUNT" su -s /bin/bash mateuser << 'DEVTOOLS2'
cd ~

# === Node Version Manager (nvm) + Node LTS ===
echo ">>> Installing nvm..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash 2>/dev/null || true
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install --lts 2>/dev/null || true
nvm use --lts 2>/dev/null || true
echo ">>> nvm done"

# === Bun ===
echo ">>> Installing bun..."
curl -fsSL https://bun.sh/install | bash 2>/dev/null || echo "  SKIP: bun"
echo ">>> bun done"

# === Rust stable toolchain ===
echo ">>> Installing Rust stable..."
rustup toolchain install stable 2>/dev/null || true
rustup default stable 2>/dev/null || true
echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bashrc
echo ">>> Rust done"

# === npm global CLI tools ===
echo ">>> Installing wrangler (Cloudflare)..."
npm install -g wrangler 2>/dev/null && echo "  OK" || echo "  SKIP"

echo ">>> Installing netlify-cli..."
npm install -g netlify-cli 2>/dev/null && echo "  OK" || echo "  SKIP"

echo ">>> Installing Claude Code (large ~400MB)..."
npm install -g @anthropic-ai/claude-code 2>/dev/null && echo "  OK" || echo "  SKIP"

echo ">>> Installing Cline CLI..."
npm install -g cline 2>/dev/null && echo "  OK" || echo "  SKIP"

echo ">>> Installing Freebuff..."
npm install -g freebuff 2>/dev/null && echo "  OK" || echo "  SKIP"

echo ">>> Installing Mimo..."
npm install -g @mimo-ai/cli 2>/dev/null && echo "  OK" || echo "  SKIP"
echo ">>> npm globals done"

# === Curl/bash installer tools ===
echo ">>> Installing OpenCode..."
curl -fsSL https://opencode.ai/install | bash 2>/dev/null || echo "  SKIP"

echo ">>> Installing Antigravity..."
curl -fsSL https://antigravity.google/cli/install.sh | bash 2>/dev/null || echo "  SKIP"

echo ">>> Installing Kimchi..."
curl -fsSL https://github.com/getkimchi/kimchi/releases/latest/download/install.sh | bash 2>/dev/null || echo "  SKIP"

# === nvim config (jhonoryza) ===
echo ">>> Installing nvim config..."
if [ -d ~/.config/nvim ]; then
  echo "  SKIP: ~/.config/nvim already exists"
else
  git clone https://github.com/jhonoryza/nvim.git ~/.config/nvim 2>/dev/null && echo "  OK" || echo "  SKIP: clone failed"
fi

echo "=== All dev tools attempted ==="
DEVTOOLS2

  log "Development tools installation finished"
}

cleanup() {
  log "Final disk usage:"
  df -h "$MOUNT" | tail -1
}

main() {
  checks
  select_desktops
  detect_boot_mode
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

  if [[ "$UEFI" -eq 1 ]]; then
    # UEFI: install GRUB for x86_64-efi, ESP at /boot/efi
    log "Installing GRUB (UEFI/x86_64-efi)..."
    arch-chroot "$MOUNT" grub-install --target=x86_64-efi \
      --efi-directory=/boot/efi --bootloader-id=GRUB
  else
    # BIOS/Legacy: install GRUB for i386-pc (MBR)
    log "Installing GRUB (BIOS/i386-pc)..."
    arch-chroot "$MOUNT" grub-install "$DISK" --target=i386-pc
  fi
  arch-chroot "$MOUNT" grub-mkconfig -o /boot/grub/grub.cfg

  umount "$MOUNT/dev" "$MOUNT/proc" "$MOUNT/sys" 2>/dev/null || true
  # Lazy-unmount anything still busy (arch-chroot may leave /proc, /sys active)
  umount -l "$MOUNT/dev"  2>/dev/null || true
  umount -l "$MOUNT/proc" 2>/dev/null || true
  umount -l "$MOUNT/sys"  2>/dev/null || true
  log "GRUB installed"

  build_aur
  configure_default_apps
  install_devtools
  cleanup

  log "=========================================="
  log "  INSTALL COMPLETE"
  log "=========================================="
  log "Reboot and remove the live ISO."
  log "Login: $USERNAME / $PASSWORD"
  log "Root password: $ROOT_PASS"
}

main "$@"
