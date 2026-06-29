# Build Linux — Arch Linux Live Installer

Script installer Arch Linux dari live ISO, dengan desktop **MATE + tema Ubuntu 10.10** (Ambiance, Humanity, Ubuntu font, DMZ cursor).

## Disk

Minimal **20 GB** kosong pada `/dev/sda`.

## Jalankan

Booting Arch Linux Live ISO → login sebagai root → lalu:

```bash
# opsi 1
curl -sL <URL install.sh> | bash

# opsi 2
scp install.sh root@IP:/root/
ssh root@
bash /root/install.sh
```

##Yang diinstall

- Arch Linux base + kernel
- MATE desktop + Xorg
- LightDM + GTK Greeter (autologin)
- Theme: Ambiance + Humanity icons + Ubuntu font
- gtk-engine-murrine (dari AUR)
- GRUB bootloader di `/dev/sda`
- NetworkManager + sshd
- User `mateuser` (password: `mateuser`)
- Root password: `arch`

## Catatan

Script **menghapus seluruh partisi** `/dev/sda` dan membentuk ulang jadi satu partisi ext4.
Pastikan tidak ada data penting di dalamnya.
