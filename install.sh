#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
set -eux

WORKDIR="$(readlink -f "$(dirname "$0")")"
ROOTFS_DEVICE="${1:-/dev/disk/by-partsets/self/rootfs}"
PKGS=(f2fs-tools reiserfsprogs)

help()
{
  cat << EOD
This script will install the payload to keep or create a btrfs home and sd cards.

First argument should be the rootfs device node or /dev/disk/by-partsets/self/rootfs by default.
EOD
  if [[ "$EUID" -ne 0 ]]; then
    echo "Please run as root." 1>&2
    exit 1
  fi
}

[[ "$EUID" -ne 0 ]] && help

# patch the recovery install script to support btrfs
cd /
[[ -f "home/deck/tools/repair_device.sh" ]] && patch -Np1 -i "$WORKDIR/home/deck/tools/repair_device.sh.patch"
# mount rootfs and make it writable
mount "$ROOTFS_DEVICE" /mnt
btrfs property set /mnt ro false
cd /mnt
# patch /etc/fstab to use btrfs /home
[[ -f "etc/fstab" ]] && sed -i 's#^\(\S\+\s\+/home\s\+\)ext4\(\s\+\S\+\).*$#\1btrfs\2,noatime,lazytime,compress-force=zstd,space_cache=v2,autodefrag,subvol=@ 0 0#' etc/fstab
# copy systemd service to set up the ext4 to btrfs conversion if needed
mkdir -p etc/systemd/system
cp -r "$WORKDIR/etc/systemd/system/." etc/systemd/system/
mkdir -p usr/lib/steamos
cp "$WORKDIR/usr/lib/steamos/steamos-convert-home-to-btrfs" usr/lib/steamos/
mkdir -p usr/lib/hwsupport
# patch the sdcard format script to force btrfs on sd cards
[[ -f "usr/lib/hwsupport/format-sdcard.sh" ]] && patch -Np1 -i "$WORKDIR/usr/lib/hwsupport/format-sdcard.sh.patch"
# patch the sdcard mount script to handle btrfs
[[ -f "usr/lib/hwsupport/sdcard-mount.sh" ]] && patch -Np1 -i "$WORKDIR/usr/lib/hwsupport/sdcard-mount.sh.patch"
mkdir -p usr/lib/rauc
# patch the ota post install script to reinject the payload
[[ -f "usr/lib/rauc/post-install.sh" ]] && patch -Np1 -i "$WORKDIR/usr/lib/rauc/post-install.sh.patch"
# patch swapfile script to handle btrfs filesystem
[[ -f "usr/bin/mkswapfile" ]] && patch -Np1 -i "$WORKDIR/usr/bin/mkswapfile.patch"
# install the needed arch packages
mkdir -p /tmp/pacman-cache
pacman --dbpath usr/share/factory/var/lib/pacman --root . --cachedir /tmp/pacman-cache --gpgdir etc/pacman.d/gnupg -Sy --needed --noconfirm "${PKGS[@]}"
rm -rf /tmp/pacman-cache
# patch the /usr/lib/manifest.pacman with the new packages
echo '#Package[:Architecture] #Version' > usr/lib/manifest.pacman
pacman --dbpath usr/share/factory/var/lib/pacman --root . --cachedir /tmp/pacman-cache --gpgdir etc/pacman.d/gnupg -Qiq | \
  sed -n 's/^\(Name\|Version\)\s*:\s*\(\S\+\)\s*$/\2/p' | \
  xargs -d'\n' -n 2 printf '%s %s\n' >> usr/lib/manifest.pacman
# synchronize the /var partition with the new pacman state if needed
mkdir -p var
mount "$(dirname "$ROOTFS_DEVICE")/var" var
[[ -d var/lib/pacman ]] && cp -a -r -u usr/share/factory/var/lib/pacman/. var/lib/pacman/
umount -l var
cd /
btrfs property set /mnt ro true
umount -l "$ROOTFS_DEVICE"
echo "Done. You can reboot the system now or reimage the system."
