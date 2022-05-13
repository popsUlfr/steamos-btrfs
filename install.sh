#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
# Using parts of /home/deck/tools/repair_Device.sh
set -eu

WORKDIR="$(realpath "$(dirname "$0")")"
ROOTFS_DEVICE="${1:-/dev/disk/by-partsets/self/rootfs}"
ROOTFS_MOUNTPOINT="/mnt"
VAR_MOUNTPOINT="/tmp/var"
HOME_DEVICE="/dev/disk/by-partsets/shared/home"
HOME_MOUNTPOINT="/home"
PKGS=(f2fs-tools reiserfsprogs)
NONINTERACTIVE="${NONINTERACTIVE:-0}"
NOAUTOUPDATE="${NOAUTOUPDATE:-0}"

if [[ -f /etc/default/steamos-btrfs ]]
then
  source /etc/default/steamos-btrfs
elif [[ -f "$WORKDIR/files/etc/default/steamos-btrfs" ]]
then
  source "$WORKDIR/files/etc/default/steamos-btrfs"
fi

HOME_MOUNT_OPTS="${STEAMOS_BTRFS_HOME_MOUNT_OPTS:-defaults,nofail,x-systemd.growfs,noatime,lazytime,compress-force=zstd,space_cache=v2,autodefrag}"
HOME_MOUNT_SUBVOL="${STEAMOS_BTRFS_HOME_MOUNT_SUBVOL:-@}"

die() { echo >&2 "!! $*"; exit 1; }
readvar() { IFS= read -r -d '' "$1" || true; }

##
## Util colors and such
##

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

onexiterr=()
err() {
  echo >&2
  eerr "Installation error occured, see above and restart process."
  estat "Cleaning up"
  for func in "${onexiterr[@]}"
  do
    "$func" || true
  done
  onexiterr=()
  if [[ "$NONINTERACTIVE" -ne 1 ]]
  then
    zenity --error --title='Installation error occured' --text='An installation error occured, look at the log and report any issues.' &>/dev/null
    sleep infinity
  fi
}
trap err ERR

quit() {
  echo >&2
  ewarn "Quit signal received."
  estat "Cleaning up"
  for func in "${onexiterr[@]}"
  do
    "$func" || true
  done
  onexiterr=()
}
trap quit SIGINT SIGQUIT SIGTERM

##
## Prompt mechanics - currently using Zenity
##

# Give the user a choice between Proceed, or Cancel (which exits this script)
#  $1 Title
#  $2 Text
#  $3 OK Label
#  $4 Cancel Label
#
prompt_step()
{
  title="$1"
  msg="$2"
  oklabel="${3:-}"
  cancellabel="${4:-}"
  if [[ "$NONINTERACTIVE" -ne 1 ]]
  then
    #Parameterable prompt
    if [[ -n "${oklabel}" ]] && [[ -n "${cancellabel}" ]]; then
      if zenity --title "$title" --question --ok-label "${oklabel}" --cancel-label "${cancellabel}" --no-wrap --text "$msg" &>/dev/null
      then
        return 0
      else
        return 1
      fi
    else
      zenity --title "$title" --question --ok-label "Proceed" --cancel-label "Cancel" --no-wrap --text "$msg" &>/dev/null || exit 1
    fi

  else
    ewarn "$title"
    ewarn "$msg"
  fi
}

prompt_reboot()
{
  prompt_step "Installation Complete" "${1}\n\nChoose Proceed to reboot the Steam Deck now, or Cancel to stay.\nThe conversion of the /home partition will happen on the next reboot. Once it is done, it will reboot just one more time." || exit 1
  if [[ "$NONINTERACTIVE" -ne 1 ]]
  then
    cmd systemctl reboot
  fi
}

onexit=()
exithandler() {
  estat "Cleaning up"
  for func in "${onexit[@]}"; do
    "$func" || true
  done
  onexit=()
  onexiterr=()
}

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
  if [[ "$NONINTERACTIVE" -eq 1 ]]
  then
    eerr "Please run as root."
    exit 1
  fi
  # not root, ask for password if needed
  if [[ -z "${SUDO_ASKPASS:-}" ]]
  then
      for ap in ksshaskpass ssh-askpass zenity
      do
          if apc="$(command -v "$ap")"
          then
              if [[ "$ap" = "zenity" ]]
              then
                echo -e '#!/bin/sh\nexec zenity --password --title="$1"' > /tmp/zenity-askpass
                chmod +x /tmp/zenity-askpass
                apc="/tmp/zenity-askpass"
              fi
              export SUDO_ASKPASS="$apc"
              break
          fi
      done
  fi
  exec sudo "$0" "$@"
fi

epatch()
{
  patches=()
  for p in "$1".old.*
  do
    if [[ -f "$p" ]]
    then
      patches=("$p" "${patches[@]}")
    fi
  done
  patches=("$1" "${patches[@]}")
  for p in "${patches[@]}"
  do
    if patch --dry-run -Rlfsp1 -i "$p" &>/dev/null
    then
        patch --no-backup-if-mismatch -Rlfsp1 -i "$p"
        break
    fi
  done
  for p in "${patches[@]}"
  do
    if patch --dry-run -Nlfsp1 -i "$p" &>/dev/null
    then
        cmd patch --no-backup-if-mismatch -Nlfp1 -i "$p"
        return 0
    fi
  done
  if cmd patch --no-backup-if-mismatch -Nlfp1 -i "$p"
  then
    return 0
  fi
  return 1
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

# mount rootfs and make it writable
estat "Mount '$ROOTFS_DEVICE' on '$ROOTFS_MOUNTPOINT' and make it writable"

cmd mkdir -p "$ROOTFS_MOUNTPOINT"
cmd mount "$ROOTFS_DEVICE" "$ROOTFS_MOUNTPOINT"
exit_rootfs_umount() { cd / ; cmd umount -l "$ROOTFS_MOUNTPOINT" || true ; }
onexiterr=(exit_rootfs_umount "${onexiterr[@]}")
onexit=(exit_rootfs_umount "${onexit[@]}")

cmd btrfs property set "$ROOTFS_MOUNTPOINT" ro false
exit_rootfs_ro() { cmd btrfs property set "$ROOTFS_MOUNTPOINT" ro true || true ; }
onexiterr=(exit_rootfs_ro "${onexiterr[@]}")
onexit=(exit_rootfs_ro "${onexit[@]}")

cd "$ROOTFS_MOUNTPOINT"

# patch /etc/fstab to use temporary tmpfs /home
if [[ -f "etc/fstab" ]]
then
  if [[ ! -f "etc/fstab.orig" ]]
  then
    estat "Backing up '/etc/fstab' to '/etc/fstab.orig'"
    cmd cp -a "etc/fstab"{,.orig}
  fi
  exit_fstab_orig() { cmd mv -vf "etc/fstab"{.orig,} || true ; }
  onexiterr=(exit_fstab_orig "${onexiterr[@]}")
  if [[ "$(blkid -o value -s TYPE "$HOME_DEVICE")" != "ext4" ]]
  then
    estat "Patch /etc/fstab to use btrfs for $HOME_MOUNTPOINT"
    sed -i 's#^\S\+\s\+'"$HOME_MOUNTPOINT"'\s\+\(ext4\|tmpfs\)\s\+.*$#'"$HOME_DEVICE"' '"$HOME_MOUNTPOINT"' btrfs '"${HOME_MOUNT_OPTS}"',subvol='"${HOME_MOUNT_SUBVOL}"' 0 0#' etc/fstab
  else
    estat "Patch /etc/fstab to use temporary $HOME_MOUNTPOINT in tmpfs"
    sed -i 's#^\S\+\s\+'"$HOME_MOUNTPOINT"'\s\+ext4\s\+.*$#tmpfs '"$HOME_MOUNTPOINT"' tmpfs defaults,nofail,noatime,lazytime 0 0#' etc/fstab
  fi
fi

# patch existing files
estat "Patching existing files"

exit_patches_orig() {
  find "$WORKDIR/files" -type f -name '*.patch' -print0 | while IFS= read -r -d '' p
  do
    pf="$(realpath -s --relative-to="$WORKDIR/files" "${p%.*}")"
    if [[ "$pf" =~ ^home/ ]]
    then
      pf="/$pf"
    fi
    cmd mv -vf "$pf"{.orig,} || true
  done
}
onexiterr=(exit_patches_orig "${onexiterr[@]}")
find "$WORKDIR/files" -type f -name '*.patch' -print0 | while IFS= read -r -d '' p
do
  pf="$(realpath -s --relative-to="$WORKDIR/files" "${p%.*}")"
  # /home patches use the current root
  if [[ "$pf" =~ ^home/ ]]
  then
    pf="/$pf"
  fi
  if [[ -f "$pf" ]]
  then
    if [[ ! -f "$pf.orig" ]]
    then
      estat "Backing up '/$pf' to '/$pf.orig'"
      cmd cp -a "$pf"{,.orig}
    fi
    if [[ "$pf" =~ ^/ ]]
    then
      estat "Patching '$pf'"
      (cd / ; epatch "$p")
    else
      estat "Patching '/$pf'"
      epatch "$p"
    fi
  fi
done

estat "Copy needed files"
exit_file_copy() {
  find "$WORKDIR/files" -type f,l -not -name '*.patch*' -exec realpath -s -z --relative-to="$WORKDIR/files" '{}' + | while IFS= read -r -d '' p
  do
    cmd rm -f "$p" || true
    cmd rmdir -p --ignore-fail-on-non-empty "$(dirname "$p")" || true
  done
}
onexiterr=(exit_file_copy "${onexiterr[@]}")
find "$WORKDIR/files" -type f,l -not -name '*.patch*' -exec realpath -s -z --relative-to="$WORKDIR/files" '{}' + | \
  xargs -0 tar -cf - -C "$WORKDIR/files" | tar -xvf - --no-same-owner

# try to remount /etc overlay to refresh the lowerdir otherwise the files look corrupted
estat "Remount /etc overlay to refresh the installed files"
cmd mount -o remount /etc || true

# install the needed arch packages
estat "Install the needed arch packages: ${PKGS[*]}"
exit_pacman_cache() { if [[ -d /tmp/pacman-cache ]]; then cmd rm -rf /tmp/pacman-cache; fi; }
onexiterr=(exit_pacman_cache "${onexiterr[@]}")
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
exit_pacman_cache

# synchronize the /var partition with the new pacman state if needed
estat "Synchronize the /var partition with the new pacman state if needed"
exit_var() { if [[ -d "$VAR_MOUNTPOINT" ]]; then cmd umount -l "$VAR_MOUNTPOINT" || true; cmd rmdir "$VAR_MOUNTPOINT" || true; fi; }
onexiterr=(exit_var "${onexiterr[@]}")
cmd mkdir -p "$VAR_MOUNTPOINT"
cmd mount "$(dirname "$ROOTFS_DEVICE")/var" "$VAR_MOUNTPOINT"
if [[ -d "$VAR_MOUNTPOINT"/lib/pacman ]]
then
  cmd cp -a -r -u usr/share/factory/var/lib/pacman/. "$VAR_MOUNTPOINT"/lib/pacman/
fi
exit_var

# determine if the user wants to automatically pull updates from gitlab
if [[ "$NONINTERACTIVE" -ne 1 ]] ; then
  #Only update environment variable if interactive as to not overwrite it
  if prompt_step "Auto-update" "Do you wish to have the script auto-update?\n This will automatically fetch the latest script bundle from gitlab when SteamOS performs an update\n(Recommended to leave enabled in case of needed future changes)" "Enable Auto-update" "Disable Auto-update"
  then
    NOAUTOUPDATE=0
  else
    NOAUTOUPDATE=1
  fi
fi

if [[ "$NOAUTOUPDATE" -eq 1 ]] ; then
  estat "Auto-update disabled"
  cmd mkdir -p usr/share/steamos-btrfs
  tar -cf - -C "$WORKDIR" --exclude=.git . | tar -xvf - --no-same-owner -C usr/share/steamos-btrfs
  cmd touch usr/share/steamos-btrfs/disableautoupdate
fi

exithandler

prompt_reboot "Done. You can reboot the system now or reimage the system."
