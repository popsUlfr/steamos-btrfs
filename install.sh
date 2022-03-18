#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
# Using parts of /home/deck/tools/repair_Device.sh
set -eu

WORKDIR="$(readlink -f "$(dirname "$0")")"
ROOTFS_DEVICE="${1:-/dev/disk/by-partsets/self/rootfs}"
PKGS=(f2fs-tools reiserfsprogs)
NONINTERACTIVE="${NONINTERACTIVE:-0}"

die() { echo >&2 "!! $*"; exit 1; }
readvar() { IFS= read -r -d '' "$1" || true; }

##
## Util colors and such
##

err() {
  echo >&2
  eerr "Installation error occured, see above and restart process."
  if [[ "$NONINTERACTIVE" -ne 1 ]]
  then
    sleep infinity
  fi
}
trap err ERR

_sh_c_colors=0
[[ -n $TERM && -t 1 && ${TERM,,} != dumb ]] && _sh_c_colors="$(tput colors 2>/dev/null || echo 0)"
sh_c() { [[ $_sh_c_colors -le 0 ]] || ( IFS=\; && echo -n $'\e['"${*:-0}m"; ); }

sh_quote() { echo "${@@Q}"; }
estat()    { echo >&2 "$(sh_c 32 1)::$(sh_c) $*"; }
emsg()     { echo >&2 "$(sh_c 34 1)::$(sh_c) $*"; }
ewarn()    { echo >&2 "$(sh_c 33 1);;$(sh_c) $*"; }
einfo()    { echo >&2 "$(sh_c 30 1)::$(sh_c) $*"; }
eerr()     { echo >&2 "$(sh_c 31 1)!!$(sh_c) $*"; }
die() { local msg="$*"; [[ -n $msg ]] || msg="script terminated"; eerr "$msg"; exit 1; }
showcmd() { showcmd_unquoted "${@@Q}"; }
showcmd_unquoted() { echo >&2 "$(sh_c 30 1)+$(sh_c) $*"; }
cmd() { showcmd "$@"; "$@"; }

##
## Prompt mechanics - currently using Zenity
##

# Give the user a choice between Proceed, or Cancel (which exits this script)
#  $1 Title
#  $2 Text
#
prompt_step()
{
  title="$1"
  msg="$2"
  if [[ "$NONINTERACTIVE" -ne 1 ]]
  then
    zenity --title "$title" --question --ok-label "Proceed" --cancel-label "Cancel" --no-wrap --text "$msg" || exit 1
  else
    ewarn "$title"
    ewarn "$msg"
  fi
}

prompt_reboot()
{
  prompt_step "Action Complete" "${1}\n\nChoose Proceed to reboot the Steam Deck now, or Cancel to stay." || exit 1
  if [[ "$NONINTERACTIVE" -ne 1 ]]
  then
    cmd systemctl reboot
  fi
}

onexit=()
exithandler() {
  cd /
  for func in "${onexit[@]}"; do
    "$func" || true
  done
}
trap exithandler EXIT

help()
{
  readvar HELPMSG << EOD
This script will install the payload to keep or create a btrfs home and sd cards.

First argument should be the rootfs device node or /dev/disk/by-partsets/self/rootfs by default.
EOD
  emsg "$HELPMSG"
  if [[ "$EUID" -ne 0 ]]; then
    eerr "Please run as root."
    exit 1
  fi
}

if [[ "$EUID" -ne 0 ]]
then
  help
fi

epatch()
{
  patch --dry-run -Rlfsp1 -i "$1" &>/dev/null || cmd patch -Nlfp1 -i "$1"
}

factory_pacman()
{
  cmd pacman --root . \
    --dbpath usr/share/factory/var/lib/pacman \
    --cachedir /tmp/pacman-cache \
    --gpgdir etc/pacman.d/gnupg \
    --logfile /dev/null \
    --disable-download-timeout \
    --noconfirm \
    "$@"
}

prompt_step "Install Btrfs /home converter" "This action will install the Btrfs payload.\nThis will migrate your home partition to btrfs on the next boot.\n\nThis cannot be undone.\n\nChoose Proceed only if you wish to go ahead with this, in the worst case a reimage will reset the state."
# patch the recovery install script to support btrfs
cd /
if [[ -f "home/deck/tools/repair_device.sh" ]]
then
  estat "Patching /home/deck/tools/repair_device.sh"
  epatch "$WORKDIR/home/deck/tools/repair_device.sh.patch"
fi
# mount rootfs and make it writable
estat "Mount '$ROOTFS_DEVICE' and make it writable"
unrootfs() { cmd btrfs property set /mnt ro true || true; cmd umount -l "$ROOTFS_DEVICE" || true; }
onexit+=(unrootfs)
cmd mount "$ROOTFS_DEVICE" /mnt
cmd btrfs property set /mnt ro false
cd /mnt
# patch /etc/fstab to use btrfs /home
if [[ -f "etc/fstab" ]]
then
  estat "Patch /etc/fstab to use btrfs /home"
  sed -i 's#^\(\S\+\s\+/home\s\+\)ext4\(\s\+\S\+\).*$#\1btrfs\2,noatime,lazytime,compress-force=zstd,space_cache=v2,autodefrag,subvol=@ 0 0#' etc/fstab
fi
# copy systemd service to set up the ext4 to btrfs conversion if needed
estat "Copy systemd service to set up the ext4 to btrfs conversion if needed"
cmd mkdir -p etc/systemd/system
cmd cp -r "$WORKDIR/etc/systemd/system/." etc/systemd/system/
cmd mkdir -p usr/lib/steamos
cmd cp -r "$WORKDIR/usr/lib/steamos/." usr/lib/steamos/
cmd mkdir -p usr/lib/hwsupport
# patch the sdcard format script to force btrfs on sd cards
if [[ -f "usr/lib/hwsupport/format-sdcard.sh" ]]
then
  estat "Patch the sdcard format script to force btrfs on sd cards"
  epatch "$WORKDIR/usr/lib/hwsupport/format-sdcard.sh.patch"
fi
# patch the sdcard mount script to handle btrfs
if [[ -f "usr/lib/hwsupport/sdcard-mount.sh" ]]
then
  estat "Patch the sdcard mount script to handle btrfs"
  epatch "$WORKDIR/usr/lib/hwsupport/sdcard-mount.sh.patch"
fi
cmd mkdir -p usr/lib/rauc
# patch the ota post install script to reinject the payload
if [[ -f "usr/lib/rauc/post-install.sh" ]]
then
  estat "Patch the ota post install script to reinject the payload"
  epatch "$WORKDIR/usr/lib/rauc/post-install.sh.patch"
fi
# patch swapfile script to handle btrfs filesystem
if [[ -f "usr/bin/mkswapfile" ]]
then
  estat "Patch swapfile script to handle btrfs filesystem"
  epatch "$WORKDIR/usr/bin/mkswapfile.patch"
fi
# install the needed arch packages
estat "Install the needed arch packages: ${PKGS[*]}"
unpacman() { if [[ -d /tmp/pacman-cache ]]; then cmd rm -rf /tmp/pacman-cache; fi; }
onexit+=(unpacman)
cmd mkdir -p /tmp/pacman-cache
factory_pacman --cachedir /tmp/pacman-cache -Sy --needed "${PKGS[@]}"
# patch the /usr/lib/manifest.pacman with the new packages
if [[ -f usr/lib/manifest.pacman ]]
then
  estat "Patch the /usr/lib/manifest.pacman with the new packages"
  head -n 1 usr/lib/manifest.pacman | wc -c | xargs -I'{}' truncate -s '{}' usr/lib/manifest.pacman
  factory_pacman -Qiq | \
    sed -n 's/^\(Name\|Version\)\s*:\s*\(\S\+\)\s*$/\2/p' | \
    xargs -d'\n' -n 2 printf '%s %s\n' >> usr/lib/manifest.pacman
fi
unpacman
# synchronize the /var partition with the new pacman state if needed
estat "Synchronize the /var partition with the new pacman state if needed"
unvar() { if [[ -d /tmp/var ]]; then cmd umount -l /tmp/var || true; cmd rmdir /tmp/var || true; fi; }
onexit+=(unvar)
cmd mkdir -p /tmp/var
cmd mount "$(dirname "$ROOTFS_DEVICE")/var" /tmp/var
if [[ -d /tmp/var/lib/pacman ]]
then
  cmd cp -a -r -u usr/share/factory/var/lib/pacman/. /tmp/var/lib/pacman/
fi
unvar
cd /
unrootfs
onexit=()
prompt_reboot "Done. You can reboot the system now or reimage the system."
