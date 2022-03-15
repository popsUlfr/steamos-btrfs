#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
set -eux

WORKDIR="$(readlink -f "$(dirname "$0")")"
ROOTFS_DEVICE="${1:-/dev/disk/by-partsets/self/rootfs}"

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
# btrfs-convert is missing the reiserfsprogs library to work
[[ ! -f "usr/lib/libreiserfscore.so.0" ]] && curl -sSL https://archlinux.org/packages/core/x86_64/reiserfsprogs/download | tar -xJf - usr/lib
mkdir -p usr/lib/hwsupport
# patch the sdcard format script to force btrfs on sd cards
[[ -f "usr/lib/hwsupport/format-sdcard.sh" ]] && patch -Np1 -i "$WORKDIR/usr/lib/hwsupport/format-sdcard.sh.patch"
# patch the sdcard mount script to handle btrfs
[[ -f "usr/lib/hwsupport/sdcard-mount.sh" ]] && patch -Np1 -i "$WORKDIR/usr/lib/hwsupport/sdcard-mount.sh.patch"
mkdir -p usr/lib/rauc
# patch the ota post install script to reinject the payload
[[ -f "usr/lib/rauc/post-install.sh" ]] && patch -Np1 -i "$WORKDIR/usr/lib/rauc/post-install.sh.patch"
cd /
btrfs property set /mnt ro true
umount -l "$ROOTFS_DEVICE"
echo "Done. You can reboot the system now or reimage the system."
