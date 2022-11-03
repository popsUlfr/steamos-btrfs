#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
set -euo pipefail

NONINTERACTIVE="${NONINTERACTIVE:-}"
NOGUI="${NOGUI:-}"
NOAUTOUPDATE="${NOAUTOUPDATE:-}"
NOCONVERTHOME="${NOCONVERTHOME:-}"
CUSTOMPROMPT="${CUSTOMPROMPT:-}"
STEAMOS_BTRFS_HOME_MOUNT_OPTS="${STEAMOS_BTRFS_HOME_MOUNT_OPTS:-}"
STEAMOS_BTRFS_HOME_MOUNT_SUBVOL="${STEAMOS_BTRFS_HOME_MOUNT_SUBVOL:-}"
STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS="${STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS:-}"

# Defaults
STEAMOS_BTRFS_INSTALL_PATH='/usr/share/steamos-btrfs'
NONINTERACTIVE_DEFAULT=0
NOGUI_DEFAULT=0
NOAUTOUPDATE_DEFAULT=0
NOAUTOUPDATE_FILE_FLAG="$STEAMOS_BTRFS_INSTALL_PATH/disableautoupdate"
NOCONVERTHOME_DEFAULT=0
NOCONVERTHOME_FILE_FLAG="$STEAMOS_BTRFS_INSTALL_PATH/disableconverthome"
STEAMOS_BTRFS_HOME_MOUNT_OPTS_DEFAULT='defaults,nofail,x-systemd.growfs,noatime,lazytime,compress-force=zstd,space_cache=v2,autodefrag'
STEAMOS_BTRFS_HOME_MOUNT_SUBVOL_DEFAULT='@'
STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS_DEFAULT=''
CONFIGFILE='/etc/default/steamos-btrfs'
LOGFILE='/var/log/steamos-btrfs.log'
PKGS=(f2fs-tools reiserfsprogs kdialog wmctrl patch)
PKGS_SIZE="${#PKGS[@]}"
ROOTFS_DEVICES=('/dev/disk/by-partsets/self/rootfs')
ROOTFS_DEVICE='/dev/disk/by-partsets/self/rootfs'
ROOTFS_MOUNTPOINT=''
VAR_DEVICE=''
VAR_MOUNTPOINT=''
HOME_DEVICE='/dev/disk/by-partsets/shared/home'
HOME_MOUNTPOINT='/home'
PACMAN_CACHE=''
GIT_BRANCH='wip'
UPDATER_PATH=''

SCRIPT="$0"
SCRIPT_ARGS=("$@")
WORKDIR="$(realpath "$(dirname "$0")")"

eprint() {
  echo -e ":: $*" >&2
}

cmd() {
  eprint '[$]' "${@@Q}"
}

is_true() {
  local v="${1:-}"
  v="${v//[[:space:]]/}"
  v="${v,,}"
  if [[ -n "$v" && "$v" != '0' && "$v" != 'n' && "$v" != 'no' && "$v" != 'false' ]]; then
    return 0
  else
    return 1
  fi
}

# Prompt the user for input
# $1 Title
# $2 Message
# $3 Yes label (optional)
# $4 No label (optional)
# $5 Cancel label (optional)
#
# env var EPROMPT_VALUE_DEFAULT to specify the default truth value that is asked for
#
# Returns 0 => OK
#         1 => No
#         2 => Cancel
eprompt() {
  local title="${1:-}"
  if [[ -n "$title" ]]; then
    title="SteamOS Btrfs - $title"
  else
    title='SteamOS Btrfs'
  fi
  local msg="${2:-}"
  local yeslabel="${3:-Yes}"
  local nolabel="${4:-No}"
  local cancellabel="${5:-Cancel}"
  local defaultvalue="${EPROMPT_VALUE_DEFAULT:-1}"
  local resp
  eprint "($title) $msg"
  if is_true "$NONINTERACTIVE" || [[ ! -t 0 ]]; then
    if is_true "$defaultvalue"; then
      eprint '[Y/n]: y'
      return 0
    else
      eprint '[N/y]: n'
      return 1
    fi
  elif [[ -n "$CUSTOMPROMPT" ]]; then
    if EPROMPT_VALUE_DEFAULT="$defaultvalue" "$CUSTOMPROMPT" "$title" "$msg" "$yeslabel" "$nolabel" "$cancellabel" ; then
      return 0
    elif [[ "$?" -eq 1 ]]; then
      return 1
    else
      return 2
    fi
  elif is_true "$NOGUI" || [[ -z "$DISPLAY" ]]; then
    local prompt
    if is_true "$defaultvalue"; then
      prompt='[Y/n]: '
    else
      prompt='[N/y]: '
    fi
    if read -r -p "$prompt" resp; then
      if [[ -z "${resp//[[:space:]]/}" ]]; then
        if is_true "$defaultvalue"; then
          return 0
        else
          return 1
        fi
      elif is_true "$resp"; then
        return 0
      else
        return 1
      fi
    else
      return 2
    fi
  elif command -v kdialog &>/dev/null; then
    if kdialog --title "$title" --yesnocancel --yes-label "$yeslabel" --no-label "$nolabel" --cancel-label "$cancellabel" "$msg"; then
      return 0
    elif [[ "$?" -eq 1 ]]; then
      return 1
    else
      return 2
    fi
  elif command -v zenity &>/dev/null; then
    if resp="$(zenity --title "$title" --question --ok-label "$yeslabel" --cancel-label "$nolabel" --extra-button "$cancellabel" --no-wrap --text "$msg" 2>/dev/null)"; then
      return 0
    elif [[ "$resp" == "$cancellabel" ]]; then
      return 2
    else
      return 1
    fi
  else
    NOGUI=1
    eprompt "$@"
    return "$?"
  fi
}

# $1 Title
# $2 Header
# $3... [+]Option
#
# Returns 1 if cancelled
eprompt_list() {
  local title="${1:-}"
  if [[ -n "$title" ]]; then
    title="SteamOS Btrfs - $title"
  else
    title='SteamOS Btrfs'
  fi
  local header="${2:-}"
  if is_true "$NOGUI" || [[ -z "$DISPLAY" ]] || is_true "$NONINTERACTIVE" || [[ ! -t 0 ]]; then
    for opt in "${@:3}"; do
      if [[ "$opt" == '+'* ]]; then
        echo "${opt#+}"
      fi
    done
  elif command -v kdialog &>/dev/null; then
    local list=()
    for opt in "${@:3}"; do
      if [[ "$opt" == '+'* ]]; then
        list+=("${opt#+}" "${opt#+}" on)
      else
        list+=("$opt" "$opt" off)
      fi
    done
    if kdialog --title "$title" --separate-output --checklist "$header" "${list[@]}" 2>/dev/null; then
      return 0
    else
      return 1
    fi
  elif command -v zenity &>/dev/null; then
    local list=()
    for opt in "${@:3}"; do
      if [[ "$opt" == '+'* ]]; then
        list+=(TRUE "${opt#+}")
      else
        list+=(FALSE "$opt")
      fi
    done
    if zenity --title "$title" --list --text="$header" --column='' --column='' --checklist --separator=$'\n' --multiple --hide-header "${list[@]}" 2>/dev/null; then
      return 0
    else
      return 1
    fi
  else
    NOGUI=1 eprompt_list "$@"
    return "$?"
  fi
}

eprompt_error() {
  local title="${1:-}"
  if [[ -n "$title" ]]; then
    title="SteamOS Btrfs - $title"
  else
    title='SteamOS Btrfs'
  fi
  local msg="${2:-}"
  eprint "($title) $msg"
  if is_true "$NOGUI" || [[ -z "$DISPLAY" ]] || is_true "$NONINTERACTIVE" || [[ ! -t 0 ]]; then
    :
  elif command -v kdialog &>/dev/null; then
    if kdialog --title "$title" --error "$msg" &>/dev/null; then
      :
    fi
  elif command -v zenity &>/dev/null; then
    if zenity --error --title "$title" --no-wrap --text "$msg" &>/dev/null; then
      :
    fi
  else
    NOGUI=1 eprompt_error "$@"
  fi
}

config_load() {
  local v \
    TMP_NONINTERACTIVE \
    TMP_NOGUI \
    TMP_NOAUTOUPDATE \
    TMP_NOCONVERTHOME \
    TMP_STEAMOS_BTRFS_HOME_MOUNT_OPTS \
    TMP_STEAMOS_BTRFS_HOME_MOUNT_SUBVOL \
    TMP_STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS
  if [[ -f "$NOAUTOUPDATE_FILE_FLAG" ]]; then
    TMP_NOAUTOUPDATE=1
  fi
  if [[ -f "$NOCONVERTHOME_FILE_FLAG" ]]; then
    TMP_NOCONVERTHOME=1
  fi
  for f in "$STEAMOS_BTRFS_INSTALL_PATH/files/${CONFIGFILE#/}" "$WORKDIR/files/${CONFIGFILE#/}" "$CONFIGFILE"; do
    if [[ -f "$f" ]]; then
      {
        read -r v
        TMP_NONINTERACTIVE="${v:-"$TMP_NONINTERACTIVE"}"
        read -r v
        TMP_NOGUI="${v:-"$TMP_NOGUI"}"
        read -r v
        TMP_NOAUTOUPDATE="${v:-"$TMP_NOAUTOUPDATE"}"
        read -r v
        TMP_NOCONVERTHOME="${v:-"$TMP_NOCONVERTHOME"}"
        read -r v
        TMP_STEAMOS_BTRFS_HOME_MOUNT_OPTS="${v:-"$TMP_STEAMOS_BTRFS_HOME_MOUNT_OPTS"}"
        read -r v
        TMP_STEAMOS_BTRFS_HOME_MOUNT_SUBVOL="${v:-"$TMP_STEAMOS_BTRFS_HOME_MOUNT_SUBVOL"}"
        read -r v
        TMP_STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS="${v:-"$TMP_STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS"}"
      } < <(
        # shellcheck source=files/etc/default/steamos-btrfs
        source "$f"
        echo "${NONINTERACTIVE:-}"
        echo "${NOGUI:-}"
        echo "${NOAUTOUPDATE:-}"
        echo "${NOCONVERTHOME:-}"
        echo "${STEAMOS_BTRFS_HOME_MOUNT_OPTS:-}"
        echo "${STEAMOS_BTRFS_HOME_MOUNT_SUBVOL:-}"
        echo "${STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS:-}"
      )
    fi
  done
  NONINTERACTIVE="${NONINTERACTIVE:-"${TMP_NONINTERACTIVE:-"$NONINTERACTIVE_DEFAULT"}"}"
  NOGUI="${NOGUI:-"${TMP_NOGUI:-"$NOGUI_DEFAULT"}"}"
  NOAUTOUPDATE="${NOAUTOUPDATE:-"${TMP_NOAUTOUPDATE:-"$NOAUTOUPDATE_DEFAULT"}"}"
  NOCONVERTHOME="${NOCONVERTHOME:-"${TMP_NOCONVERTHOME:-"$NOCONVERTHOME_DEFAULT"}"}"
  STEAMOS_BTRFS_HOME_MOUNT_OPTS="${STEAMOS_BTRFS_HOME_MOUNT_OPTS:-"${TMP_STEAMOS_BTRFS_HOME_MOUNT_OPTS:-"$STEAMOS_BTRFS_HOME_MOUNT_OPTS_DEFAULT"}"}"
  STEAMOS_BTRFS_HOME_MOUNT_SUBVOL="${STEAMOS_BTRFS_HOME_MOUNT_SUBVOL:-"${TMP_STEAMOS_BTRFS_HOME_MOUNT_SUBVOL:-"$STEAMOS_BTRFS_HOME_MOUNT_SUBVOL_DEFAULT"}"}"
  STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS="${STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS:-"${TMP_STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS:-"$STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS_DEFAULT"}"}"
  PKGS=("${PKGS[@]:0:$PKGS_SIZE}")
  readarray -d' ' -O"$PKGS_SIZE" -t PKGS < <(echo -n "$STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS")
}

root_handler() {
  if [[ "$EUID" -eq 0 ]]; then
    return
  fi
  if is_true "$NONINTERACTIVE" || [[ ! -t 0 ]]; then
    eprint 'Please run as root.'
    return 1
  fi
  local sudo_args=(
    NONINTERACTIVE="$NONINTERACTIVE"
    NOGUI="$NOGUI"
    NOAUTOUPDATE="$NOAUTOUPDATE"
    NOCONVERTHOME="$NOCONVERTHOME"
    CUSTOMPROMPT="$CUSTOMPROMPT"
    STEAMOS_BTRFS_HOME_MOUNT_OPTS="$STEAMOS_BTRFS_HOME_MOUNT_OPTS"
    STEAMOS_BTRFS_HOME_MOUNT_SUBVOL="$STEAMOS_BTRFS_HOME_MOUNT_SUBVOL"
    STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS="$STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS")
  # not root, ask for password if needed
  if ! is_true "$NOGUI" && [[ -n "$DISPLAY" ]]; then
    sudo_args=(-A "${sudo_args[@]}")
    if [[ -z "${SUDO_ASKPASS:-}" ]]; then
      for ap in ksshaskpass kdialog ssh-askpass zenity; do
        if apc="$(command -v "$ap")"; then
          if [[ "$ap" == 'kdialog' ]]; then
            cat <<'EOF' >/tmp/kdialog-askpass
#!/bin/sh
exec kdialog --title Password --password "$1"
EOF
            chmod +x /tmp/kdialog-askpass
            apc="/tmp/kdialog-askpass"
          elif [[ "$ap" = "zenity" ]]; then
            cat <<'EOF' >/tmp/zenity-askpass
#!/bin/sh
exec zenity --password --title="$1"
EOF
            chmod +x /tmp/zenity-askpass
            apc="/tmp/zenity-askpass"
          fi
          export SUDO_ASKPASS="$apc"
          break
        fi
      done
    fi
  fi
  exec sudo "${sudo_args[@]}" -- "$SCRIPT" "${SCRIPT_ARGS[@]}"
}

find_partset_rootfs() {
  find /dev/disk/by-partsets/{self,other,A,B} \
    -mindepth 1 \
    -maxdepth 1 \
    -name rootfs \
    -exec sh -c '[ "$(realpath "$1")" = "$2" ]' _ '{}' "$(realpath "${1:?'Missing rootfs'}")" \; \
    -print \
    -quit
}

help() {
  echo "SteamOS Btrfs" >&2
  if [[ -f "$WORKDIR/version" ]]; then
    echo "Version: $(head -n "$WORKDIR/version")" >&2
  fi
  cat <<EOF >&2
Usage: '$SCRIPT' [OPTION]... [rootfs dev]...
Example: '$SCRIPT' --nogui /dev/disk/by-partsets/self/rootfs

  --help                 show help
  --noninteractive       run in noninteractive mode
                         apply options from config files, env vars or defaults
                         (env var: 'NONINTERACTIVE')
                         (default: $NONINTERACTIVE_DEFAULT)
  --nogui                run without gui prompts, force text prompts
                         (env var: 'NOGUI')
                         (default: $NOGUI_DEFAULT)
  --noautoupdate         disable automatic fetching of the latest script version when updating the system, changing channels or on version check
                         (env var: 'NOAUTOUPDATE')
                         (file flag: '$NOAUTOUPDATE_FILE_FLAG')
                         (default: $NOAUTOUPDATE_DEFAULT)
  --noconverthome        disable home conversion
                         (env var: 'NOCONVERTHOME')
                         (file flag: '$NOCONVERTHOME_FILE_FLAG')
                         (default: $NOCONVERTHOME_DEFAULT)
  --customprompt PATH    set path to a custom prompt script or executable
                         First argument supplied is the title, second argument the message to display, third argument label for yes, fourth argument label for no, fifth argument label for cancel
                         Env var 'EPROMPT_VALUE_DEFAULT' holds the default value
                         Should return 0 if OK, 1 if not, 2 if cancelled
                         (env var: 'CUSTOMPROMPT')
                         (default: '')

Expert config options:
  --STEAMOS_BTRFS_HOME_MOUNT_OPTS OPTS             set the /home mount options to use
                                                   (env var: 'STEAMOS_BTRFS_HOME_MOUNT_OPTS')
                                                   (default: '$STEAMOS_BTRFS_HOME_MOUNT_OPTS_DEFAULT')
  --STEAMOS_BTRFS_HOME_MOUNT_SUBVOL SUBVOL         set the /home subvolume name to use
                                                   (env var: 'STEAMOS_BTRFS_HOME_MOUNT_SUBVOL')
                                                   (default: '$STEAMOS_BTRFS_HOME_MOUNT_SUBVOL_DEFAULT')
  --STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS PKGS    set the extra pacman packages to install
                                                   (env var: 'STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS')
                                                   (default: '$STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS_DEFAULT')

You can specify multiple 'rootfs dev's or none and it will default to '$ROOTFS_DEVICE'.
Order of priority from highest to lowest for options is: command line flags, config files ('$STEAMOS_BTRFS_INSTALL_PATH/files/${CONFIGFILE#/}', '$WORKDIR/files/${CONFIGFILE#/}', '$CONFIGFILE'), flag files ('$NOCONVERTHOME_FILE_FLAG', '$NOAUTOUPDATE_FILE_FLAG').

A log file will be created at '$LOGFILE'.
EOF
}

cmd_handler() {
  local i=0
  local skip=0
  local TMP_ROOTFS_DEVICES=()
  for arg in "${SCRIPT_ARGS[@]}"; do
    if [[ "$skip" -eq 1 ]]; then
      skip=0
      continue
    fi
    if [[ "$arg" == '--'* ]]; then
      arg="${arg#--}"
      if [[ "${arg^^}" == 'HELP' ]]; then
        help
        exit 0
      elif [[ "${arg^^}" == 'NONINTERACTIVE' ]]; then
        NONINTERACTIVE=1
      elif [[ "${arg^^}" == 'NOGUI' ]]; then
        NOGUI=1
      elif [[ "${arg^^}" == 'NOAUTOUPDATE' ]]; then
        NOAUTOUPDATE=1
      elif [[ "${arg^^}" == 'NOCONVERTHOME' ]]; then
        NOCONVERTHOME=1
      elif [[ "${arg^^}" == 'CUSTOMPROMPT' ]]; then
        if [[ "$((i + 1))" -ge "${#SCRIPT_ARGS[@]}" ]]; then
          eprint "Missing argument for '${arg^^}'."
          return 1
        fi
        CUSTOMPROMPT="${SCRIPT_ARGS[$((i + 1))]}"
        skip=1
      elif [[ "${arg^^}" == 'STEAMOS_BTRFS_HOME_MOUNT_OPTS' ]]; then
        if [[ "$((i + 1))" -ge "${#SCRIPT_ARGS[@]}" ]]; then
          eprint "Missing argument for '${arg^^}'."
          return 1
        fi
        STEAMOS_BTRFS_HOME_MOUNT_OPTS="${SCRIPT_ARGS[$((i + 1))]}"
        skip=1
      elif [[ "${arg^^}" == 'STEAMOS_BTRFS_HOME_MOUNT_SUBVOL' ]]; then
        if [[ "$((i + 1))" -ge "${#SCRIPT_ARGS[@]}" ]]; then
          eprint "Missing argument for '${arg^^}'."
          return 1
        fi
        STEAMOS_BTRFS_HOME_MOUNT_SUBVOL="${SCRIPT_ARGS[$((i + 1))]}"
        skip=1
      elif [[ "${arg^^}" == 'STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS' ]]; then
        if [[ "$((i + 1))" -ge "${#SCRIPT_ARGS[@]}" ]]; then
          eprint "Missing argument for '${arg^^}'."
          return 1
        fi
        STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS="${SCRIPT_ARGS[$((i + 1))]}"
        PKGS=("${PKGS[@]:0:$PKGS_SIZE}")
        readarray -d' ' -O"$PKGS_SIZE" -t PKGS < <(echo -n "$STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS")
        skip=1
      else
        eprint "Unknown flag '${arg}'."
        help
        return 1
      fi
    else
      local rootfs
      rootfs="$(find_partset_rootfs "$arg")"
      if [[ -z "$rootfs" ]]; then
        eprint "'$arg' is not an acceptable rootfs device."
        return 1
      fi
      local found=0
      for rd in "${TMP_ROOTFS_DEVICES[@]}"; do
        if [[ "$rd" == "$rootfs" ]]; then
          found=1
          break
        fi
      done
      if [[ "$found" -eq 0 ]]; then
        TMP_ROOTFS_DEVICES+=("$rootfs")
      fi
    fi
    i=$((i + 1))
  done
  if [[ "${#TMP_ROOTFS_DEVICES[@]}" -gt 0 ]]; then
    ROOTFS_DEVICES=("${TMP_ROOTFS_DEVICES[@]}")
  fi
}

epatch_comment() {
  awk '{\
    if ($0 ~ /^[@+-]/) {\
      comm = substr(comm, 1, i);\
      if (comm ~ /\n\n$/) {\
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", comm);\
        print comm;\
      }\
      exit;\
    }\
    else {\
      comm = comm $0 "\n";\
      if (comm ~ /\n\n$/)\
        i=length(comm);\
    }\
  }' <"$1"
}

epatch() {
  local tpatch="$1"
  local patches=()
  for p in "$tpatch".old.*; do
    if [[ -f "$p" ]]; then
      patches=("$p" "${patches[@]}")
    fi
  done
  patches=("$tpatch" "${patches[@]}")
  for p in "${patches[@]}"; do
    if patch --dry-run -Rlfsp1 -i "$p" &>/dev/null; then
      cmd patch --no-backup-if-mismatch -Rlfsp1 -i "$p"
      break
    fi
  done
  for p in "${patches[@]}"; do
    if patch --dry-run -Nlfsp1 -i "$p" &>/dev/null; then
      tpatch="$p"
      break
    fi
  done
  # try to parse the comment if available
  local comment
  comment="$(epatch_comment "$tpatch")"
  if [[ -n "$comment" ]]; then
    einfo "$comment"
  fi
  if cmd patch --no-backup-if-mismatch -Nlfp1 -i "$tpatch"; then
    return 0
  fi
  return 1
}

factory_pacman() {
  if cmd pacman --root . \
    --config etc/pacman.conf \
    --dbpath usr/share/factory/var/lib/pacman \
    --cachedir /tmp/pacman-cache \
    --gpgdir etc/pacman.d/gnupg \
    --logfile /dev/null \
    --disable-download-timeout \
    --noconfirm \
    "$@"; then
    return 0
  else
    return 1
  fi
}

list_rootfs_devices() {
  find /dev/disk/by-partsets/{self,other,A,B} \
    -mindepth 1 \
    -maxdepth 1 \
    -name rootfs
}

log_handler() {
  if mkdir -p "$(dirname "$LOGFILE")" && touch "$LOGFILE"; then
    exec &> >(tee -a "$LOGFILE")
    printf '#### %(%F %T)T ####\n'
    if [[ -f "$WORKDIR/version" ]]; then
      eprint "Version: $(head -n 1 "$WORKDIR/version")"
    fi
  fi
}

rootfs_device_selection() {
  local ALL_ROOTFS_DEVICES=()
  readarray -d$'\n' -t ALL_ROOTFS_DEVICES < <(list_rootfs_devices)
  if [[ "${#ALL_ROOTFS_DEVICES[@]}" -eq 0 ]]; then
    eprompt_error 'No rootfs devices' 'No available rootfs devices.'
    return 1
  fi
  local i=0
  for rd in "${ALL_ROOTFS_DEVICES[@]}"; do
    for rdo in "${ROOTFS_DEVICES[@]}"; do
      if [[ "$rd" == "$rdo" ]]; then
        ALL_ROOTFS_DEVICES[$i]="+$rd"
        break
      fi
    done
    i=$((i + 1))
  done
  ROOTFS_DEVICES=()
  while read -r rd; do
    ROOTFS_DEVICES+=("$rd")
  done < <(eprompt_list 'Rootfs devices' 'Select the rootfs devices to install into:' "${ALL_ROOTFS_DEVICES[@]}")
}

ONEXITERR=()
ONEXITRESTORE=()

err() {
  echo >&2
  eprint 'Installation error occured, see above and restart process.'
  eprint 'Cleaning up...'
  for func in "${ONEXITERR[@]}"; do
    "$func" || true
  done
  ONEXITERR=()
  for func in "${ONEXITRESTORE[@]}"; do
    "$func" || true
  done
  ONEXITRESTORE=()
  eprompt_error 'Installation error occured' "An installation error occured, check the log at '${LOGFILE}' and report any issues." || true
}
trap err ERR

quit() {
  echo >&2
  eprint 'Quit signal received.'
  eprint 'Cleaning up...'
  for func in "${ONEXITERR[@]}"; do
    "$func" || true
  done
  ONEXITERR=()
  for func in "${ONEXITRESTORE[@]}"; do
    "$func" || true
  done
  ONEXITRESTORE=()
}
trap quit SIGINT SIGQUIT SIGTERM EXIT

update_check_cleanup() {
  if [[ -d "$UPDATER_PATH" ]]; then
    cmd rm -rf "$UPDATER_PATH" || true
  fi
}

update_check() {
  local version
  if [[ -f "$WORKDIR/version" ]]; then
    version="$(head -n 1 "$WORKDIR/version")"
  fi
  local remote_version
  remote_version="$({ curl -sLf "https://gitlab.com/popsulfr/steamos-btrfs/-/raw/${GIT_BRANCH}/version" || true; } | head -n 1)"
  if [[ "$version" != "$remote_version" ]]; then
    local update
    if is_true "$NOAUTOUPDATE"; then
      update=0
    else
      update=1
    fi
    if EPROMPT_VALUE_DEFAULT="$update" eprompt 'New update!' "A newer update '$remote_version' is available" 'Update' 'Continue'; then
      ONEXITERR=(update_check_cleanup "${ONEXITERR[@]}")
      UPDATER_PATH="$(mktemp -d)"
      cmd curl -sSL "https://gitlab.com/popsulfr/steamos-btrfs/-/archive/${GIT_BRANCH}/steamos-btrfs-${GIT_BRANCH}.tar.gz" | cmd tar -xzf - -C "$UPDATER_PATH" --strip-components=1
      exec "$UPDATER_PATH/install.sh" "${SCRIPT_ARGS[@]}"
    elif [[ "$?" -eq 1 ]]; then
      return 0
    else
      return 1
    fi
  fi
}

rootfs_install_packages_cleanup() {
  if [[ -d "$VAR_MOUNTPOINT" ]]; then
    if mountpoint -q "$VAR_MOUNTPOINT"; then
      cmd umount -l "$VAR_MOUNTPOINT" || true
    fi
    cmd rm -rf "$VAR_MOUNTPOINT" || true
  fi
  if [[ -d "$PACMAN_CACHE" ]]; then
    cmd rm -rf "$PACMAN_CACHE" || true
  fi
}

rootfs_install_packages() {
  ONEXITERR=(rootfs_install_packages_cleanup "${ONEXITERR[@]}")
  eprint "Install the needed arch packages: ${PKGS[*]}"
  # Patch /etc/pacman.conf if jupiter-beta does not exist
  if grep -q '^\[jupiter-beta\]' etc/pacman.conf; then
    ret_code="$(curl -sSLIo /dev/null -w '%{http_code}' 'https://steamdeck-packages.steamos.cloud/archlinux-mirror/jupiter-beta/os/x86_64/jupiter-beta.db')"
    if [[ "$ret_code" != '200' ]]; then
      eprint "Replace non-existing jupiter-beta repo in /etc/pacman.conf"
      cmd sed -i 's/^\[jupiter-beta\]/[jupiter]/' etc/pacman.conf
    fi
  fi
  PACMAN_CACHE="$(mktemp -d)"
  factory_pacman --cachedir "$PACMAN_CACHE" -Sy --needed "${PKGS[@]}"
  # patch the /usr/lib/manifest.pacman with the new packages
  if [[ -f usr/lib/manifest.pacman ]]; then
    estat 'Patch the /usr/lib/manifest.pacman with the new packages'
    cmd cp -a usr/lib/manifest.pacman{,.orig}
    head -n 1 usr/lib/manifest.pacman | wc -c | xargs -I'{}' truncate -s '{}' usr/lib/manifest.pacman
    factory_pacman -Qiq |
      sed -n 's/^\(Name\|Version\)\s*:\s*\(\S\+\)\s*$/\2/p' |
      xargs -d'\n' -n 2 printf '%s %s\n' >> usr/lib/manifest.pacman
  fi
  cmd rm -rf "$PACMAN_CACHE"
  # synchronize the /var partition with the new pacman state if needed
  eprint 'Synchronize the /var partition with the new pacman state if needed'
  VAR_MOUNTPOINT="$(mktemp -d)"
  cmd mount "$VAR_DEVICE" "$VAR_MOUNTPOINT"
  if [[ -d "$VAR_MOUNTPOINT"/lib/pacman ]]; then
    cmd cp -a -r -u usr/share/factory/var/lib/pacman/. "$VAR_MOUNTPOINT"/lib/pacman/
  fi
  cmd umount -l "$VAR_MOUNTPOINT"
  cmd rm -rf "$VAR_MOUNTPOINT"
  ONEXITERR=("${ONEXITERR[@]:1}")
}

rootfs_fstab_patch_cleanup() {
  if [[ -d "$VAR_MOUNTPOINT" ]]; then
    cmd mv -vf "$VAR_MOUNTPOINT/lib/overlays/etc/upper/fstab"{.orig,} || true
    if mountpoint -q "$VAR_MOUNTPOINT"; then
      cmd umount -l "$VAR_MOUNTPOINT" || true
    fi
    cmd rm -rf "$VAR_MOUNTPOINT" || true
  fi
  cmd mv -vf etc/fstab{.orig,} || true
}

rootfs_fstab_patch_restore() {
  VAR_MOUNTPOINT="$(mktemp -d)" || true
  cmd mount "$VAR_DEVICE" "$VAR_MOUNTPOINT" || true
  rootfs_fstab_patch_cleanup
}

rootfs_fstab_patch() {
  if is_true "$NOCONVERTHOME" || [[ ! -f 'etc/fstab' ]]; then
    return
  fi
  ONEXITERR=(rootfs_fstab_patch_cleanup "${ONEXITERR[@]}")
  # patch /etc/fstab to use temporary tmpfs /home
  if [[ ! -f 'etc/fstab.orig' ]]; then
    eprint "Backing up '/etc/fstab' to '/etc/fstab.orig'"
    cmd cp -a etc/fstab{,.orig}
  fi
  fstab_files=(etc/fstab)
  # if the user modified the fstab we will need to patch the one on the var partition too
  VAR_MOUNTPOINT="$(mktemp -d)"
  cmd mount "$VAR_DEVICE" "$VAR_MOUNTPOINT"
  if [[ -f "$VAR_MOUNTPOINT/lib/overlays/etc/upper/fstab" ]]; then
    fstab_files+=("$VAR_MOUNTPOINT/lib/overlays/etc/upper/fstab")
    if [[ ! -f "$VAR_MOUNTPOINT/lib/overlays/etc/upper/fstab.orig" ]]; then
      eprint "Backing up '$VAR_MOUNTPOINT/lib/overlays/etc/upper/fstab' to '$VAR_MOUNTPOINT/lib/overlays/etc/upper/fstab.orig'"
      cmd cp -a "$VAR_MOUNTPOINT/lib/overlays/etc/upper/fstab"{,.orig}
    fi
  fi
  if [[ "$(blkid -o value -s TYPE "$HOME_DEVICE")" != 'ext4' ]]; then
    eprint "Patch /etc/fstab to use btrfs for $HOME_MOUNTPOINT"
    cmd sed -i 's#^\S\+\s\+'"$HOME_MOUNTPOINT"'\s\+\(ext4\|tmpfs\|btrfs\)\s\+.*$#'"$HOME_DEVICE"' '"$HOME_MOUNTPOINT"' btrfs '"${HOME_MOUNT_OPTS}"',subvol='"${HOME_MOUNT_SUBVOL}"' 0 0#' "${fstab_files[@]}"
  else
    eprint "Patch /etc/fstab to use temporary $HOME_MOUNTPOINT in tmpfs"
    cmd sed -i 's#^\S\+\s\+'"$HOME_MOUNTPOINT"'\s\+ext4\s\+.*$#tmpfs '"$HOME_MOUNTPOINT"' tmpfs defaults,nofail,noatime,lazytime 0 0#' "${fstab_files[@]}"
  fi
  cmd umount -l "$VAR_MOUNTPOINT"
  cmd rm -rf "$VAR_MOUNTPOINT"
  ONEXITERR=("${ONEXITERR[@]:1}")
  ONEXITRESTORE=(rootfs_fstab_patch_restore "${ONEXITRESTORE[@]}")
}

rootfs_patch_files_cleanup() {
  while read -r -d '' p; do
    pf="$(realpath -s --relative-to="$WORKDIR/files" "${p%.*}")"
    if [[ "$pf" =~ ^home/ ]]; then
      pf="/$pf"
    fi
    cmd mv -vf "$pf"{.orig,} || true
  done < <(find "$WORKDIR/files" -type f -name '*.patch' -print0)
}

rootfs_patch_files() {
  ONEXITERR=(rootfs_patch_files_cleanup "${ONEXITERR[@]}")
  # patch existing files
  eprint 'Patching existing files'
  while read -r -d '' p; do
    pf="$(realpath -s --relative-to="$WORKDIR/files" "${p%.*}")"
    # /home patches use the current root
    if [[ "$pf" =~ ^home/ ]]; then
      pf="/$pf"
    fi
    if [[ -f "$pf" ]]; then
      if [[ ! -f "$pf.orig" ]]; then
        eprint "Backing up '/$pf' to '/$pf.orig'"
        cmd cp -a "$pf"{,.orig}
      fi
      if [[ "$pf" =~ ^/ ]]; then
        eprint "Patching '$pf'"
        (
          cd /
          epatch "$p"
        )
      else
        eprint "Patching '/$pf'"
        epatch "$p"
      fi
    fi
  done < <(find "$WORKDIR/files" -type f -name '*.patch' -print0)
  ONEXITERR=("${ONEXITERR[@]:1}")
  ONEXITRESTORE=(rootfs_patch_files_cleanup "${ONEXITRESTORE[@]}")
}

rootfs_remove_old_files() {
  # try to remove files from older versions
  eprint 'Remove files from older versions"'
  cmd rm -f {etc,usr/lib}/systemd/system/local-fs-pre.target.wants/steamos-convert-home-to-btrfs*.service \
    usr/lib/steamos/steamos-convert-home-to-btrfs-progress || true
}

rootfs_copy_files_cleanup() {
  while read -r -d '' p; do
    cmd rm -f "$p" || true
    cmd rmdir -p --ignore-fail-on-non-empty "$(dirname "$p")" || true
  done < <(find "$WORKDIR/files" -type f,l -not -name '*.patch*' -exec realpath -s -z --relative-to="$WORKDIR/files" '{}' +)
}

rootfs_copy_files() {
  ONEXITERR=(rootfs_copy_files_cleanup "${ONEXITERR[@]}")
  estat "Copy needed files"
  find "$WORKDIR/files" -type f,l -not -name '*.patch*' -exec realpath -s -z --relative-to="$WORKDIR/files" '{}' + |
    xargs -0 tar -cf - -C "$WORKDIR/files" | tar -xvf - --no-same-owner
  cmd rm -rf "${STEAMOS_BTRFS_INSTALL_PATH#/}" || true
  cmd mkdir -p "${STEAMOS_BTRFS_INSTALL_PATH#/}"
  tar -cf - -C "$WORKDIR" --exclude=.git . | tar -xvf - --no-same-owner -C "${STEAMOS_BTRFS_INSTALL_PATH#/}"
  if is_true "$NOCONVERTHOME"; then
    eprint 'Disable /home conversion services'
    cmd rm -f usr/lib/systemd/system/*.target.wants/steamos-convert-home-to-btrfs*.service || true
    cmd touch "${NOCONVERTHOME_FILE_FLAG#/}"
  else
    eprint 'Enable /home conversion services'
    cmd rm -f "${NOCONVERTHOME_FILE_FLAG#/}" || true
  fi
  if is_true "$NOAUTOUPDATE"; then
    eprint 'Auto-update disabled'
    cmd touch "${NOAUTOUPDATE_FILE_FLAG#/}"
  else
    estat 'Auto-update enabled'
    cmd rm -f "${NOAUTOUPDATE_FILE_FLAG#/}" || true
  fi
  # try to remount /etc overlay to refresh the lowerdir otherwise the files look corrupted
  eprint "Remount /etc overlay to refresh the installed files"
  cmd mount -o remount /etc || true
  ONEXITERR=("${ONEXITERR[@]:1}")
  ONEXITRESTORE=(rootfs_copy_files_cleanup "${ONEXITRESTORE[@]}")
}

rootfs_steam_download_workaround() {
  # set up Steam's 'downloading' and 'temp' folders as btrfs subvolumes and disable COW
  if [[ "$(blkid -o value -s TYPE "$HOME_DEVICE")" == 'btrfs' ]]; then
    eprint "Set up Steam's 'downloading' and 'temp' folders as btrfs subvolumes and disable COW"
    for d in "$HOME_MOUNTPOINT"/deck/.local/share/Steam/steamapps/{downloading,temp}; do
      if ! btrfs subvolume show "$d" &>/dev/null; then
        cmd mkdir -p "$d"
        cmd rm -rf "$d"
        cmd btrfs subvolume create "$d"
        cmd chattr +C "$d"
        d_parts=("$HOME_MOUNTPOINT"/deck)
        readarray -d'/' -t -O1 d_parts <<<"${d#"${d_parts[0]}"/}"
        i=1
        for p in "${d_parts[@]:1}"; do
          d_parts[$i]="${d_parts[$((i - 1))]}/${p%[[:space:]]*}"
          i=$((i + 1))
        done
        cmd chown 1000:1000 "${d_parts[@]}"
      fi
    done
  fi
}

rootfs_inject_cleanup() {
  cd /
  if [[ -d "$ROOTFS_MOUNTPOINT" ]]; then
    if mountpoint -q "$ROOTFS_MOUNTPOINT"; then
      cmd btrfs property set "$ROOTFS_MOUNTPOINT" ro true || true
      cmd umount -l "$ROOTFS_MOUNTPOINT" || true
    fi
    cmd rm -rf "$ROOTFS_MOUNTPOINT" || true
  fi
}

# $1 the rootfs device
rootfs_inject() {
  ROOTFS_DEVICE="${1:?'Missing rootfs device.'}"
  VAR_DEVICE="${ROOTFS_DEVICE%/*}/var"
  ONEXITRESTORE=()
  ONEXITERR=(rootfs_inject_cleanup "${ONEXITERR[@]}")
  ROOTFS_MOUNTPOINT="$(mktemp -d)"
  eprint "Mount '$ROOTFS_DEVICE' on '$ROOTFS_MOUNTPOINT' and make it writable"
  cmd mount "$ROOTFS_DEVICE" "$ROOTFS_MOUNTPOINT"
  cmd btrfs property set "$ROOTFS_MOUNTPOINT" ro false
  cd "$ROOTFS_MOUNTPOINT"
  rootfs_install_packages
  rootfs_fstab_patch
  rootfs_patch_files
  rootfs_remove_old_files
  rootfs_copy_files
  rootfs_steam_download_workaround
  ONEXITERR=("${ONEXITERR[@]:1}")
  ONEXITRESTORE=()
}

main() {
  root_handler
  config_load
  cmd_handler
  update_check
  eprompt '' 'This installer will inject the Btrfs payload into the system.' 'Proceed' 'Abort'
  log_handler
  rootfs_device_selection
  if [[ "$(blkid -o value -s TYPE "$HOME_DEVICE")" != 'btrfs' ]]; then
    local converthome
    if is_true "$NOCONVERTHOME"; then
      converthome=0
    else
      converthome=1
    fi
    # ask the user if they want to convert their home partition to btrfs
    if EPROMPT_VALUE_DEFAULT="$converthome" eprompt 'Install Btrfs /home converter' 'Do you wish to install the necessary files to migrate your home partition to btrfs on the next boot ?\nThis operation can not be undone once it is started!\n(mounting and formatting of SD cards with btrfs, f2fs, ext4 filesystems will still be available)' 'Convert /home' 'Keep /home as ext4'; then
      NOCONVERTHOME=0
    elif [[ "$?" -eq 1 ]]; then
      NOCONVERTHOME=1
    else
      return 1
    fi
  fi
  local update
  if is_true "$NOAUTOUPDATE"; then
    update=0
  else
    update=1
  fi
  # determine if the user wants to automatically pull updates from gitlab
  if EPROMPT_VALUE_DEFAULT="$update" eprompt 'Auto-update' 'Do you wish to always pull the latest version when updating or changing the SteamOS channel ?\n This will automatically fetch the latest script bundle from gitlab when SteamOS performs an update or switches the channel.\n(Highly recommended to leave enabled in case of needed future changes)' 'Enable Auto-update' 'Disable Auto-update'; then
    NOAUTOUPDATE=0
  elif [[ "$?" -eq 1 ]]; then
    NOAUTOUPDATE=1
  else
    return 1
  fi
  for rootfs in "${ROOTFS_DEVICES[@]}"
  do
    rootfs_inject "$rootfs"
  done
  if eprompt 'Installation Complete' 'Done. You can reboot the system now or reimage the system.\n\nChoose Proceed to reboot the Steam Deck now, or Cancel to stay.\nThe conversion of the /home partition will happen on the next reboot if you selected the option. Once it is done, it will reboot just one more time.' 'Reboot now' 'Reboot later'; then
    cmd systemctl reboot
  fi
}

main
