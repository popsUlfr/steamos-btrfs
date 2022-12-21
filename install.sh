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
NOAUTOUPDATE_FILE_FLAG="${STEAMOS_BTRFS_INSTALL_PATH}/disableautoupdate"
NOCONVERTHOME_DEFAULT=0
NOCONVERTHOME_FILE_FLAG="${STEAMOS_BTRFS_INSTALL_PATH}/disableconverthome"
STEAMOS_BTRFS_HOME_MOUNT_OPTS_DEFAULT='defaults,nofail,x-systemd.growfs,noatime,lazytime,compress-force=zstd,space_cache=v2,autodefrag'
STEAMOS_BTRFS_HOME_MOUNT_SUBVOL_DEFAULT='@'
STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS_DEFAULT=''
CONFIGFILE='/etc/default/steamos-btrfs'
LOGFILE='/var/log/steamos-btrfs.log'
PKGS=(f2fs-tools reiserfsprogs kdialog wmctrl patch exfatprogs)
PKGS_SIZE="${#PKGS[@]}"
ROOTFS_DEVICES=('/dev/disk/by-partsets/self/rootfs')
ROOTFS_DEVICE='/dev/disk/by-partsets/self/rootfs'
ROOTFS_MOUNTPOINT=''
VAR_DEVICE=''
VAR_MOUNTPOINT=''
HOME_DEVICE='/dev/disk/by-partsets/shared/home'
HOME_DEVICE_STATIC='/dev/disk/by-partsets/shared/home'
HOME_MOUNTPOINT='/home'
PACMAN_CACHE=''
GIT_BRANCH='main'
UPDATER_PATH=''
oPATH="${PATH:-}"
oLD_LIBRARY_PATH="${LD_LIBRARY_PATH:-/usr/local/lib:/usr/lib}"

SCRIPT="$0"
SCRIPT_ARGS=("$@")
WORKDIR="$(realpath "$(dirname "$0")")"

eprint() {
  echo -e ":: $*" >&2
}

cmd() {
  eprint '[$]' "${@@Q}"
  "$@"
}

is_true() {
  local v="${1:-}"
  v="${v//[[:space:]]/}"
  v="${v,,}"
  if [[ -n "${v}" && "${v}" != '0' && "${v}" != 'n' && "${v}" != 'no' && "${v}" != 'false' ]]; then
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
  if [[ -n "${title}" ]]; then
    title="SteamOS Btrfs - ${title}"
  else
    title='SteamOS Btrfs'
  fi
  local msg="${2:-}"
  local yeslabel="${3:-Yes}"
  local nolabel="${4:-No}"
  local cancellabel="${5:-Cancel}"
  local defaultvalue="${EPROMPT_VALUE_DEFAULT:-1}"
  local resp
  eprint "(${title}) ${msg}"
  if is_true "${NONINTERACTIVE}" || [[ ! -t 0 ]]; then
    if is_true "${defaultvalue}"; then
      eprint '[Y/n]: y'
      return 0
    else
      eprint '[N/y]: n'
      return 1
    fi
  elif [[ -n "${CUSTOMPROMPT}" ]]; then
    if EPROMPT_VALUE_DEFAULT="${defaultvalue}" "${CUSTOMPROMPT}" "${title}" "${msg}" "${yeslabel}" "${nolabel}" "${cancellabel}"; then
      return 0
    elif [[ "$?" -eq 1 ]]; then
      return 1
    else
      return 2
    fi
  elif is_true "${NOGUI}" || [[ -z "${DISPLAY:-}" ]]; then
    local prompt
    if is_true "${defaultvalue}"; then
      prompt='[Y/n]: '
    else
      prompt='[N/y]: '
    fi
    if read -r -p "${prompt}" resp; then
      if [[ -z "${resp//[[:space:]]/}" ]]; then
        if is_true "${defaultvalue}"; then
          return 0
        else
          return 1
        fi
      elif is_true "${resp}"; then
        return 0
      else
        return 1
      fi
    else
      return 2
    fi
  elif command -v kdialog &>/dev/null; then
    if XDG_CONFIG_DIRS="${XDG_CONFIG_DIRS:-/home/deck/.config/kdedefaults:/etc/xdg}" XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-KDE}" QT_QPA_PLATFORMTHEME="${QT_QPA_PLATFORMTHEME:-kde}" kdialog --title "${title}" --yes-label "${yeslabel}" --no-label "${nolabel}" --cancel-label "${cancellabel}" --yesnocancel "${msg}" &>/dev/null; then
      return 0
    elif [[ "$?" -eq 1 ]]; then
      return 1
    else
      return 2
    fi
  elif command -v zenity &>/dev/null; then
    if resp="$(zenity --title "${title}" --question --ok-label "${yeslabel}" --cancel-label "${nolabel}" --extra-button "${cancellabel}" --no-wrap --text "${msg}" 2>/dev/null)"; then
      return 0
    elif [[ "${resp}" == "${cancellabel}" ]]; then
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
  if [[ -n "${title}" ]]; then
    title="SteamOS Btrfs - ${title}"
  else
    title='SteamOS Btrfs'
  fi
  local header="${2:-}"
  if is_true "${NOGUI}" || [[ -z "${DISPLAY:-}" ]] || is_true "${NONINTERACTIVE}" || [[ ! -t 0 ]]; then
    for opt in "${@:3}"; do
      if [[ "${opt}" == '+'* ]]; then
        echo "${opt#+}"
      fi
    done
  elif command -v kdialog &>/dev/null; then
    local list=()
    for opt in "${@:3}"; do
      if [[ "${opt}" == '+'* ]]; then
        list+=("${opt#+}" "${opt#+}" on)
      else
        list+=("${opt}" "${opt}" off)
      fi
    done
    if XDG_CONFIG_DIRS="${XDG_CONFIG_DIRS:-/home/deck/.config/kdedefaults:/etc/xdg}" XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-KDE}" QT_QPA_PLATFORMTHEME="${QT_QPA_PLATFORMTHEME:-kde}" kdialog --title "${title}" --separate-output --checklist "${header}" "${list[@]}" 2>/dev/null; then
      return 0
    else
      return 2
    fi
  elif command -v zenity &>/dev/null; then
    local list=()
    for opt in "${@:3}"; do
      if [[ "${opt}" == '+'* ]]; then
        list+=(TRUE "${opt#+}")
      else
        list+=(FALSE "${opt}")
      fi
    done
    if zenity --title "${title}" --list --text="${header}" --column='' --column='' --checklist --separator=$'\n' --multiple --hide-header "${list[@]}" 2>/dev/null; then
      return 0
    else
      return 2
    fi
  else
    NOGUI=1 eprompt_list "$@"
    return "$?"
  fi
}

eprompt_error() {
  local title="${1:-}"
  if [[ -n "${title}" ]]; then
    title="SteamOS Btrfs - ${title}"
  else
    title='SteamOS Btrfs'
  fi
  local msg="${2:-}"
  eprint "(${title}) ${msg}"
  if is_true "${NOGUI}" || [[ -z "${DISPLAY:-}" ]] || is_true "${NONINTERACTIVE}" || [[ ! -t 0 ]]; then
    :
  elif command -v kdialog &>/dev/null; then
    if XDG_CONFIG_DIRS="${XDG_CONFIG_DIRS:-/home/deck/.config/kdedefaults:/etc/xdg}" XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-KDE}" QT_QPA_PLATFORMTHEME="${QT_QPA_PLATFORMTHEME:-kde}" kdialog --title "${title}" --error "${msg}" &>/dev/null; then
      :
    fi
  elif command -v zenity &>/dev/null; then
    if zenity --error --title "${title}" --no-wrap --text "${msg}" &>/dev/null; then
      :
    fi
  else
    NOGUI=1 eprompt_error "$@"
  fi
}

eprompt_password() {
  local title="${1:-}"
  if [[ -n "${title}" ]]; then
    title="SteamOS Btrfs - ${title}"
  else
    title='SteamOS Btrfs'
  fi
  local msg="${2:-}"
  eprint "(${title}) ${msg}"
  local pass=''
  if is_true "${NOGUI}" || [[ -z "${DISPLAY:-}" ]] || is_true "${NONINTERACTIVE}" || [[ ! -t 0 ]]; then
    passwd
    return 0
  elif command -v kdialog &>/dev/null; then
    if pass="$(XDG_CONFIG_DIRS="${XDG_CONFIG_DIRS:-/home/deck/.config/kdedefaults:/etc/xdg}" XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-KDE}" QT_QPA_PLATFORMTHEME="${QT_QPA_PLATFORMTHEME:-kde}" kdialog --title "${title}" --newpassword "${msg}" 2>/dev/null)"; then
      :
    else
      return 2
    fi
  elif command -v zenity &>/dev/null; then
    local resp=''
    while true; do
      if resp="$(zenity --title "${title}" --forms --separator $'\n' --text "${msg}" --add-password Password --add-password 'Confirm Password' 2>/dev/null)"; then
        local pass1='' pass2='' i=0
        while read -r line; do
          if [[ "${i}" -eq 0 ]]; then
            pass1="${line}"
          elif [[ "${i}" -eq 1 ]]; then
            pass2="${line}"
          fi
          i=$((i + 1))
        done < <(echo "${resp}")
        if [[ "${pass1}" == "${pass2}" ]]; then
          pass="${pass1}"
          break
        else
          eprompt_error 'Password error' 'The passwords do not match'
        fi
      else
        return 2
      fi
    done
  else
    NOGUI=1 eprompt_password "$@"
    return "$?"
  fi
  local err=''
  if [[ -z "${pass}" ]]; then
    eprompt_error 'Password error' 'Empty password'
    return 1
  elif ! err="$(passwd -q < <(yes "${pass}") 2>&1 >/dev/null)"; then
    eprompt_error 'Password error' "${err}"
    return 1
  fi
}

config_load() {
  local v='' \
    TMP_NONINTERACTIVE='' \
    TMP_NOGUI='' \
    TMP_NOAUTOUPDATE='' \
    TMP_NOCONVERTHOME='' \
    TMP_STEAMOS_BTRFS_HOME_MOUNT_OPTS='' \
    TMP_STEAMOS_BTRFS_HOME_MOUNT_SUBVOL='' \
    TMP_STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS=''
  if [[ -f "${NOAUTOUPDATE_FILE_FLAG}" ]]; then
    TMP_NOAUTOUPDATE=1
  fi
  if [[ -f "${NOCONVERTHOME_FILE_FLAG}" ]]; then
    TMP_NOCONVERTHOME=1
  fi
  for f in "${STEAMOS_BTRFS_INSTALL_PATH}/files/${CONFIGFILE#/}" "${WORKDIR}/files/${CONFIGFILE#/}" "${CONFIGFILE}"; do
    if [[ -f "${f}" ]]; then
      {
        read -r v
        TMP_NONINTERACTIVE="${v:-"${TMP_NONINTERACTIVE}"}"
        read -r v
        TMP_NOGUI="${v:-"${TMP_NOGUI}"}"
        read -r v
        TMP_NOAUTOUPDATE="${v:-"${TMP_NOAUTOUPDATE}"}"
        read -r v
        TMP_NOCONVERTHOME="${v:-"${TMP_NOCONVERTHOME}"}"
        read -r v
        TMP_STEAMOS_BTRFS_HOME_MOUNT_OPTS="${v:-"${TMP_STEAMOS_BTRFS_HOME_MOUNT_OPTS}"}"
        read -r v
        TMP_STEAMOS_BTRFS_HOME_MOUNT_SUBVOL="${v:-"${TMP_STEAMOS_BTRFS_HOME_MOUNT_SUBVOL}"}"
        read -r v
        TMP_STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS="${v:-"${TMP_STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS}"}"
      } < <(
        # shellcheck source=files/etc/default/steamos-btrfs
        source "${f}"
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
  NONINTERACTIVE="${NONINTERACTIVE:-"${TMP_NONINTERACTIVE:-"${NONINTERACTIVE_DEFAULT}"}"}"
  NOGUI="${NOGUI:-"${TMP_NOGUI:-"${NOGUI_DEFAULT}"}"}"
  NOAUTOUPDATE="${NOAUTOUPDATE:-"${TMP_NOAUTOUPDATE:-"${NOAUTOUPDATE_DEFAULT}"}"}"
  NOCONVERTHOME="${NOCONVERTHOME:-"${TMP_NOCONVERTHOME:-"${NOCONVERTHOME_DEFAULT}"}"}"
  STEAMOS_BTRFS_HOME_MOUNT_OPTS="${STEAMOS_BTRFS_HOME_MOUNT_OPTS:-"${TMP_STEAMOS_BTRFS_HOME_MOUNT_OPTS:-"${STEAMOS_BTRFS_HOME_MOUNT_OPTS_DEFAULT}"}"}"
  STEAMOS_BTRFS_HOME_MOUNT_SUBVOL="${STEAMOS_BTRFS_HOME_MOUNT_SUBVOL:-"${TMP_STEAMOS_BTRFS_HOME_MOUNT_SUBVOL:-"${STEAMOS_BTRFS_HOME_MOUNT_SUBVOL_DEFAULT}"}"}"
  STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS="${STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS:-"${TMP_STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS:-"${STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS_DEFAULT}"}"}"
  PKGS=("${PKGS[@]:0:${PKGS_SIZE}}")
  readarray -d' ' -O"${PKGS_SIZE}" -t PKGS < <(echo -n "${STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS}")
}

root_handler() {
  if [[ "${EUID}" -eq 0 ]]; then
    return
  fi
  if { is_true "${NONINTERACTIVE}" || [[ ! -t 0 ]]; } && ! sudo -n -v &>/dev/null; then
    eprint 'Please run as root.'
    return 1
  fi
  if [[ "$(passwd -S | cut -d' ' -f2)" == 'NP' ]] && ! sudo -n -v &>/dev/null; then
    # user needs to set their password
    eprompt_password 'Set the password' 'Set a new user password'
  fi
  local sudo_args=(
    NONINTERACTIVE="${NONINTERACTIVE}"
    NOGUI="${NOGUI}"
    NOAUTOUPDATE="${NOAUTOUPDATE}"
    NOCONVERTHOME="${NOCONVERTHOME}"
    CUSTOMPROMPT="${CUSTOMPROMPT}"
    STEAMOS_BTRFS_HOME_MOUNT_OPTS="${STEAMOS_BTRFS_HOME_MOUNT_OPTS}"
    STEAMOS_BTRFS_HOME_MOUNT_SUBVOL="${STEAMOS_BTRFS_HOME_MOUNT_SUBVOL}"
    STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS="${STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS}")
  # not root, ask for password if needed
  if ! is_true "${NOGUI}" && [[ -n "${DISPLAY:-}" ]]; then
    sudo_args=(-A "${sudo_args[@]}")
    if [[ -z "${SUDO_ASKPASS:-}" ]]; then
      for ap in ksshaskpass kdialog ssh-askpass zenity; do
        if apc="$(command -v "${ap}")"; then
          if [[ "${ap}" == 'kdialog' ]]; then
            cat <<'EOF' >/tmp/kdialog-askpass
#!/bin/sh
exec kdialog --title Password --password "$1"
EOF
            chmod +x /tmp/kdialog-askpass
            apc="/tmp/kdialog-askpass"
          elif [[ "${ap}" = "zenity" ]]; then
            cat <<'EOF' >/tmp/zenity-askpass
#!/bin/sh
exec zenity --password --title="$1"
EOF
            chmod +x /tmp/zenity-askpass
            apc="/tmp/zenity-askpass"
          fi
          export SUDO_ASKPASS="${apc}"
          break
        fi
      done
    fi
  fi
  exec sudo "${sudo_args[@]}" -- "${SCRIPT}" "${SCRIPT_ARGS[@]}"
}

find_partset_rootfs() {
  local rootfs_dev="${1:?'Missing rootfs'}"
  local vrootfs_dev=''
  vrootfs_dev="$(find /dev/disk/by-partsets/{self,other,shared,*} \
    -mindepth 1 \
    -maxdepth 1 \
    -name rootfs \
    -exec sh -c '[ "$(realpath "$1")" = "$2" ]' _ '{}' "$(realpath "${rootfs_dev}")" \; \
    -print \
    -quit)"
  if [[ -n "${vrootfs_dev}" ]]; then
    echo "${vrootfs_dev}"
  elif [[ "$(blkid -o value -s LABEL "${rootfs_dev}")" == 'rootfs' && "$(blkid -o value -s TYPE "${rootfs_dev}")" == 'btrfs' ]]; then
    echo "${rootfs_dev}"
  fi
}

help() {
  echo "SteamOS Btrfs" >&2
  if [[ -f "${WORKDIR}/version" ]]; then
    echo "Version: $(head -n 1 "${WORKDIR}/version")" >&2
  fi
  cat <<EOF >&2
Usage: '${SCRIPT}' [OPTION]... [rootfs dev]...
Example: '${SCRIPT}' --nogui /dev/disk/by-partsets/self/rootfs

  --help                 show help
  --noninteractive       run in noninteractive mode
                         apply options from config files, env vars or defaults
                         (env var: 'NONINTERACTIVE')
                         (default: ${NONINTERACTIVE_DEFAULT})
  --nogui                run without gui prompts, force text prompts
                         (env var: 'NOGUI')
                         (default: ${NOGUI_DEFAULT})
  --noautoupdate         disable automatic fetching of the latest script version when updating the system, changing channels or on version check
                         (env var: 'NOAUTOUPDATE')
                         (file flag: '${NOAUTOUPDATE_FILE_FLAG}')
                         (default: ${NOAUTOUPDATE_DEFAULT})
  --noconverthome        disable home conversion
                         (env var: 'NOCONVERTHOME')
                         (file flag: '${NOCONVERTHOME_FILE_FLAG}')
                         (default: ${NOCONVERTHOME_DEFAULT})
  --customprompt PATH    set path to a custom prompt script or executable
                         First argument supplied is the title, second argument the message to display, third argument label for yes, fourth argument label for no, fifth argument label for cancel
                         Env var 'EPROMPT_VALUE_DEFAULT' holds the default value
                         Should return 0 if OK, 1 if not, 2 if cancelled
                         (env var: 'CUSTOMPROMPT')
                         (default: '')

Expert config options:
  --STEAMOS_BTRFS_HOME_MOUNT_OPTS OPTS             set the /home mount options to use
                                                   (env var: 'STEAMOS_BTRFS_HOME_MOUNT_OPTS')
                                                   (default: '${STEAMOS_BTRFS_HOME_MOUNT_OPTS_DEFAULT}')
  --STEAMOS_BTRFS_HOME_MOUNT_SUBVOL SUBVOL         set the /home subvolume name to use
                                                   (env var: 'STEAMOS_BTRFS_HOME_MOUNT_SUBVOL')
                                                   (default: '${STEAMOS_BTRFS_HOME_MOUNT_SUBVOL_DEFAULT}')
  --STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS PKGS    set the extra pacman packages to install
                                                   (env var: 'STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS')
                                                   (default: '${STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS_DEFAULT}')

You can specify multiple 'rootfs dev's or none and it will default to '${ROOTFS_DEVICE}'.
Order of priority from highest to lowest for options is: command line flags, env vars, config files ('${STEAMOS_BTRFS_INSTALL_PATH}/files/${CONFIGFILE#/}', '${WORKDIR}/files/${CONFIGFILE#/}', '${CONFIGFILE}'), flag files ('${NOCONVERTHOME_FILE_FLAG}', '${NOAUTOUPDATE_FILE_FLAG}').

A log file will be created at '${LOGFILE}'.
EOF
}

cmd_handler() {
  local i=0
  local skip=0
  local TMP_ROOTFS_DEVICES=()
  for arg in "${SCRIPT_ARGS[@]}"; do
    if [[ "${skip}" -eq 1 ]]; then
      skip=0
      continue
    fi
    if [[ "${arg}" == '--'* ]]; then
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
        PKGS=("${PKGS[@]:0:${PKGS_SIZE}}")
        readarray -d' ' -O"${PKGS_SIZE}" -t PKGS < <(echo -n "${STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS}")
        skip=1
      else
        eprint "Unknown flag '${arg}'."
        help
        return 1
      fi
    else
      local rootfs
      rootfs="$(find_partset_rootfs "${arg}")"
      if [[ -z "${rootfs}" ]]; then
        eprint "'${arg}' is not an acceptable rootfs device."
        return 1
      fi
      local found=0
      for rd in "${TMP_ROOTFS_DEVICES[@]}"; do
        if [[ "${rd}" == "${rootfs}" ]]; then
          found=1
          break
        fi
      done
      if [[ "${found}" -eq 0 ]]; then
        TMP_ROOTFS_DEVICES+=("${rootfs}")
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
  for p in "${tpatch}".old.*; do
    if [[ -f "${p}" ]]; then
      patches=("${p}" "${patches[@]}")
    fi
  done
  patches=("${tpatch}" "${patches[@]}")
  for p in "${patches[@]}"; do
    if patch --dry-run -Rlfsp1 -i "${p}" &>/dev/null; then
      cmd patch --no-backup-if-mismatch -Rlfsp1 -i "${p}"
      break
    fi
  done
  for p in "${patches[@]}"; do
    if patch --dry-run -Nlfsp1 -i "${p}" &>/dev/null; then
      tpatch="${p}"
      break
    fi
  done
  # try to parse the comment if available
  local comment
  comment="$(epatch_comment "${tpatch}")"
  if [[ -n "${comment}" ]]; then
    eprint "${comment}"
  fi
  if cmd patch --no-backup-if-mismatch -Nlfp1 -i "${tpatch}"; then
    return 0
  fi
  return 1
}

factory_pacman() {
  if [[ ! -f etc/pacman.conf.orig ]]; then
    cmd cp -a etc/pacman.conf{,.orig}
  fi
  cmd sed -i 's/^SigLevel\s*=.*$/SigLevel = Never/g' etc/pacman.conf
  if cmd pacman --root . \
    --config etc/pacman.conf \
    --dbpath usr/share/factory/var/lib/pacman \
    --cachedir "${PACMAN_CACHE}" \
    --gpgdir etc/pacman.d/gnupg \
    --logfile /dev/null \
    --disable-download-timeout \
    "$@" < <(yes 'y'); then
    cmd mv -vf etc/pacman.conf{.orig,}
    return 0
  else
    cmd mv -vf etc/pacman.conf{.orig,}
    return 1
  fi
}

list_rootfs_devices() {
  local rootfs_devs=()
  readarray -d '' -t rootfs_devs < <(find /dev/disk/by-partsets/{self,other,shared,*} -mindepth 1 -maxdepth 1 -name rootfs -print0)
  local i=0
  while [[ "${i}" -lt "${#rootfs_devs[@]}" ]]; do
    local rfs_dev="${rootfs_devs[${i}]}"
    local found=0
    for rfs_dev_o in "${rootfs_devs[@]:0:${i}}"; do
      if [[ "${rfs_dev_o}" == "${rfs_dev}" ]]; then
        found=1
        break
      fi
    done
    if [[ "${found}" -eq 1 ]]; then
      rootfs_devs=("${rootfs_devs[@]:0:${i}}" "${rootfs_devs[@]:$((i + 1))}")
    else
      i=$((i + 1))
    fi
  done
  local rootfs_devs_x=()
  readarray -t rootfs_devs_x < <(blkid | grep '\bLABEL="rootfs\(-[a-zA-Z]\+\)\?"' | cut -d: -f1 | sort)
  for rfs_dev_x in "${rootfs_devs_x[@]}"; do
    if [[ "$(blkid -o value -s TYPE "${rfs_dev_x}")" != 'btrfs' ]]; then
      continue
    fi
    local found=0
    for rfs_dev in "${rootfs_devs[@]}"; do
      if [[ "$(realpath "${rfs_dev}")" == "$(realpath "${rfs_dev_x}")" ]]; then
        found=1
        break
      fi
    done
    if [[ "${found}" -ne 1 ]]; then
      rootfs_devs+=("${rfs_dev_x}")
    fi
  done
  (
    IFS=$'\n'
    echo "${rootfs_devs[*]}"
  )
}

# $1 rootfs device
#
# Returns associated var device
determine_var_device() {
  local rootfs_dev=''
  rootfs_dev="$(realpath "$1")"
  local rootfs_devs=()
  local var_devs=()
  readarray -t rootfs_devs < <(blkid | grep '\bLABEL="rootfs\(-[a-zA-Z]\+\)\?"' | cut -d: -f1 | grep '^'"${rootfs_dev%[[:digit:]]*}" | sort -u)
  readarray -t var_devs < <(blkid | grep '\bLABEL="var\(-[a-zA-Z]\+\)\?"' | cut -d: -f1 | grep '^'"${rootfs_dev%[[:digit:]]*}" | sort -u)
  local pos=0
  for rfs_d in "${rootfs_devs[@]}"; do
    if [[ "${rfs_d}" == "${rootfs_dev}" ]]; then
      break
    fi
    pos=$((pos + 1))
  done
  local var_dev="${var_devs[${pos}]}"
  local vvar_dev=''
  vvar_dev="$(find /dev/disk/by-partsets/{self,other,shared,*} -mindepth 1 -maxdepth 1 -name var -exec sh -c '[ "$(realpath "$1")" = "$2" ]' _ '{}' "${var_dev}" \; -print -quit)"
  if [[ -n "${vvar_dev}" ]]; then
    echo "${vvar_dev}"
  else
    echo "${var_dev}"
  fi
}

# $1 rootfs device
#
# Returns associated home device
determine_home_device() {
  local rootfs_dev=''
  rootfs_dev="$(realpath "$1")"
  local rootfs_devs=()
  local home_devs=()
  readarray -t rootfs_devs < <(blkid | grep '\bLABEL="rootfs\(-[a-zA-Z]\+\)\?"' | cut -d: -f1 | grep '^'"${rootfs_dev%[[:digit:]]*}" | sort -u)
  readarray -t home_devs < <(blkid -t LABEL=home -o device | grep '^'"${rootfs_dev%[[:digit:]]*}" | sort -u)
  local home_dev="${home_devs[0]}"
  local vhome_dev=''
  vhome_dev="$(find /dev/disk/by-partsets/{self,other,shared,*} -mindepth 1 -maxdepth 1 -name home -exec sh -c '[ "$(realpath "$1")" = "$2" ]' _ '{}' "${home_dev}" \; -print -quit)"
  if [[ -n "${vhome_dev}" ]]; then
    echo "${vhome_dev}"
  else
    echo "${home_dev}"
  fi
}

log_truncate() {
  local log_bms=()
  readarray -t log_bms < <(grep -n '^#\+\s*[-0-9]\+\s\+[0-9:.]\+\s*#\+' "${LOGFILE}" | tail -n 6 | cut -d: -f1)
  if [[ "${#log_bms[@]}" -lt 6 ]]; then
    return
  fi
  eprint "Truncating log file: ${LOGFILE}"
  tail -n +"${log_bms[0]}" "${LOGFILE}" >"${LOGFILE}.new"
  mv -f "${LOGFILE}.new" "${LOGFILE}"
}

log_handler() {
  if mkdir -p "$(dirname "${LOGFILE}")" && touch "${LOGFILE}"; then
    log_truncate
    exec &> >(tee -a "${LOGFILE}")
    printf '#### %(%F %T)T ####\n'
    if [[ -f "${WORKDIR}/version" ]]; then
      eprint "Version: $(head -n 1 "${WORKDIR}/version")"
    fi
    eprint "Command-line arguments: ${SCRIPT_ARGS[*]@Q}"
    eprint 'Env vars:'
    eprint "\tNONINTERACTIVE: ${NONINTERACTIVE}"
    eprint "\tNOGUI: ${NOGUI}"
    eprint "\tNOAUTOUPDATE: ${NOAUTOUPDATE}"
    eprint "\tNOCONVERTHOME: ${NOCONVERTHOME}"
    eprint "\tSTEAMOS_BTRFS_HOME_MOUNT_OPTS: ${STEAMOS_BTRFS_HOME_MOUNT_OPTS}"
    eprint "\tSTEAMOS_BTRFS_HOME_MOUNT_SUBVOL: ${STEAMOS_BTRFS_HOME_MOUNT_SUBVOL}"
    eprint "\tSTEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS: ${STEAMOS_BTRFS_ROOTFS_PACMAN_EXTRA_PKGS}"
    if [[ -f "${CONFIGFILE}" ]]; then
      eprint "${CONFIGFILE}:"
      cat "${CONFIGFILE}"
    fi
    if [[ -f '/etc/os-release' ]]; then
      eprint '/etc/os-release:'
      cat '/etc/os-release'
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
      if [[ "${rd}" == "${rdo}" ]]; then
        ALL_ROOTFS_DEVICES[${i}]="+${rd}"
        break
      fi
    done
    i=$((i + 1))
  done
  ROOTFS_DEVICES=()
  local ret
  ret="$(eprompt_list 'Rootfs devices' 'Select the rootfs devices to install into:' "${ALL_ROOTFS_DEVICES[@]}")"
  readarray -d$'\n' -t ROOTFS_DEVICES < <(echo -n "${ret}")
  if [[ "${#ROOTFS_DEVICES[@]}" -eq 0 ]]; then
    eprompt_error 'No rootfs devices' 'No rootfs devices selected.'
    return 1
  fi
}

ONEXITERR=()
ONEXITRESTORE=()

err() {
  echo >&2
  eprint 'Installation error occured, see above and restart process.'
  eprint 'Cleaning up...'
  for func in "${ONEXITERR[@]}"; do
    "${func}" || true
  done
  ONEXITERR=()
  for func in "${ONEXITRESTORE[@]}"; do
    "${func}" || true
  done
  ONEXITRESTORE=()
  eprompt_error 'Installation error occured' "An installation error occured, check the log at '${LOGFILE}' and report any issues." || true
}

quit() {
  local last_status_code="$?"
  if [[ "${last_status_code}" -ne 0 ]]; then
    err
    return
  fi
  echo >&2
  eprint 'Quit signal received.'
  eprint 'Cleaning up...'
  for func in "${ONEXITERR[@]}"; do
    "${func}" || true
  done
  ONEXITERR=()
  for func in "${ONEXITRESTORE[@]}"; do
    "${func}" || true
  done
  ONEXITRESTORE=()
}

update_check_cleanup() {
  if [[ -d "${UPDATER_PATH}" ]]; then
    cmd rm -rf "${UPDATER_PATH}" || true
  fi
}

update_check() {
  local version=''
  if [[ -f "${WORKDIR}/version" ]]; then
    version="$(head -n 1 "${WORKDIR}/version")"
  fi
  local remote_version
  remote_version="$({ curl -sLf "https://gitlab.com/popsulfr/steamos-btrfs/-/raw/${GIT_BRANCH}/version" || true; } | head -n 1)"
  if [[ "${version}" != "${remote_version}" ]]; then
    local update
    if is_true "${NOAUTOUPDATE}"; then
      update=0
    else
      update=1
    fi
    if EPROMPT_VALUE_DEFAULT="${update}" eprompt 'New update!' "A newer update '${remote_version}' is available" 'Update' 'Continue'; then
      ONEXITERR=(update_check_cleanup "${ONEXITERR[@]}")
      UPDATER_PATH="$(mktemp -d)"
      cmd curl -sSL "https://gitlab.com/popsulfr/steamos-btrfs/-/archive/${GIT_BRANCH}/steamos-btrfs-${GIT_BRANCH}.tar.gz" | cmd tar -xzf - -C "${UPDATER_PATH}" --strip-components=1
      exec "${UPDATER_PATH}/install.sh" "${SCRIPT_ARGS[@]}"
    elif [[ "$?" -eq 1 ]]; then
      return 0
    else
      return 1
    fi
  fi
}

rootfs_install_packages_cleanup() {
  if [[ -d "${VAR_MOUNTPOINT}" ]]; then
    if mountpoint -q "${VAR_MOUNTPOINT}"; then
      cmd umount -l "${VAR_MOUNTPOINT}" || true
    fi
    cmd rmdir "${VAR_MOUNTPOINT}" || true
  fi
  if [[ -d "${PACMAN_CACHE}" ]]; then
    cmd rm -rf "${PACMAN_CACHE}" || true
  fi
}

pacman_repos_check_and_fix() {
  local repos=()
  readarray -t repos < <(sed -n 's/^\[\([^]]\+\)\]/\1/p' etc/pacman.conf | grep -v '^options$')
  for r in "${repos[@]}"; do
    local ret_code='200'
    ret_code="$(curl -sSLIo /dev/null -w '%{http_code}' "https://steamdeck-packages.steamos.cloud/archlinux-mirror/${r}/os/x86_64/${r}.db")"
    if [[ "${ret_code}" != '200' ]]; then
      local nr
      nr="${r%-main}"
      nr="${nr%-beta}"
      nr="${nr%-rel}"
      nr="${nr%-3.3}"
      nr="${nr%-3.3.3}"
      local trepos=()
      if [[ "${r}" == *-beta ]]; then
        trepos=("${nr}-rel" "${nr}-main")
      else
        trepos=("${nr}" "${nr}-3.3.3" "${nr}-3.3")
      fi
      for r2 in "${trepos[@]}"; do
        if [[ "${r}" == "${r2}" ]]; then
          continue
        fi
        ret_code="$(curl -sSLIo /dev/null -w '%{http_code}' "https://steamdeck-packages.steamos.cloud/archlinux-mirror/${r2}/os/x86_64/${r2}.db")"
        if [[ "${ret_code}" == '200' ]]; then
          eprint "Replace non-existing '${r}' repo with '${r2}' in /etc/pacman.conf"
          cmd sed -i 's/^\['"${r}"'\]/['"${r2}"']/' etc/pacman.conf
          break
        fi
      done
    fi
  done
}

rootfs_install_packages() {
  ONEXITERR=(rootfs_install_packages_cleanup "${ONEXITERR[@]}")
  eprint "Install the needed arch packages: ${PKGS[*]}"
  pacman_repos_check_and_fix
  PACMAN_CACHE="$(mktemp -d)"
  factory_pacman --cachedir "${PACMAN_CACHE}" -Sy --needed "${PKGS[@]}"
  # patch the /usr/lib/manifest.pacman with the new packages
  if [[ -f usr/lib/manifest.pacman ]]; then
    eprint 'Patch the /usr/lib/manifest.pacman with the new packages'
    cmd cp -a usr/lib/manifest.pacman{,.orig}
    head -n 1 usr/lib/manifest.pacman | wc -c | xargs -I'{}' truncate -s '{}' usr/lib/manifest.pacman
    factory_pacman -Qiq |
      sed -n 's/^\(Name\|Version\)\s*:\s*\(\S\+\)\s*$/\2/p' |
      xargs -d'\n' -n 2 printf '%s %s\n' >>usr/lib/manifest.pacman
  fi
  cmd rm -rf "${PACMAN_CACHE}"
  # synchronize the /var partition with the new pacman state if needed
  eprint 'Synchronize the /var partition with the new pacman state if needed'
  VAR_MOUNTPOINT="$(mktemp -d)"
  cmd mount "${VAR_DEVICE}" "${VAR_MOUNTPOINT}"
  if [[ -d "${VAR_MOUNTPOINT}"/lib/pacman ]]; then
    cmd rsync -a --inplace --delete usr/share/factory/var/lib/pacman/ "${VAR_MOUNTPOINT}"/lib/pacman/
  fi
  cmd umount -l "${VAR_MOUNTPOINT}"
  cmd rmdir "${VAR_MOUNTPOINT}" || true
  ONEXITERR=("${ONEXITERR[@]:1}")
}

rootfs_fstab_patch_cleanup() {
  if [[ -d "${VAR_MOUNTPOINT}" ]]; then
    if [[ "$(blkid -o value -s TYPE "${HOME_DEVICE}")" != 'btrfs' ]]; then
      cmd mv -vf "${VAR_MOUNTPOINT}/lib/overlays/etc/upper/fstab"{.orig,} || true
    fi
    if mountpoint -q "${VAR_MOUNTPOINT}"; then
      cmd umount -l "${VAR_MOUNTPOINT}" || true
    fi
    cmd rmdir "${VAR_MOUNTPOINT}" || true
  fi
  if [[ "$(blkid -o value -s TYPE "${HOME_DEVICE}")" != 'btrfs' ]]; then
    cmd mv -vf etc/fstab{.orig,} || true
  fi
}

rootfs_fstab_patch_restore() {
  VAR_MOUNTPOINT="$(mktemp -d)" || true
  cmd mount "${VAR_DEVICE}" "${VAR_MOUNTPOINT}" || true
  rootfs_fstab_patch_cleanup
}

rootfs_fstab_patch() {
  if is_true "${NOCONVERTHOME}" || [[ ! -f 'etc/fstab' ]]; then
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
  cmd mount "${VAR_DEVICE}" "${VAR_MOUNTPOINT}"
  if [[ -f "${VAR_MOUNTPOINT}/lib/overlays/etc/upper/fstab" ]]; then
    fstab_files+=("${VAR_MOUNTPOINT}/lib/overlays/etc/upper/fstab")
    if [[ ! -f "${VAR_MOUNTPOINT}/lib/overlays/etc/upper/fstab.orig" ]]; then
      eprint "Backing up '${VAR_MOUNTPOINT}/lib/overlays/etc/upper/fstab' to '${VAR_MOUNTPOINT}/lib/overlays/etc/upper/fstab.orig'"
      cmd cp -a "${VAR_MOUNTPOINT}/lib/overlays/etc/upper/fstab"{,.orig}
    fi
  fi
  if [[ "$(blkid -o value -s TYPE "${HOME_DEVICE}")" != 'ext4' ]]; then
    eprint "Patch /etc/fstab to use btrfs for ${HOME_MOUNTPOINT}"
    cmd sed -i 's#^\S\+\s\+'"${HOME_MOUNTPOINT}"'\s\+\S\+\s\+.*$#'"${HOME_DEVICE_STATIC}"' '"${HOME_MOUNTPOINT}"' btrfs '"${STEAMOS_BTRFS_HOME_MOUNT_OPTS}"',subvol='"${STEAMOS_BTRFS_HOME_MOUNT_SUBVOL}"' 0 0#' "${fstab_files[@]}"
  else
    eprint "Patch /etc/fstab to use temporary ${HOME_MOUNTPOINT} in tmpfs"
    cmd sed -i 's#^\S\+\s\+'"${HOME_MOUNTPOINT}"'\s\+\S\+\s\+.*$#tmpfs '"${HOME_MOUNTPOINT}"' tmpfs defaults,nofail,noatime,lazytime 0 0#' "${fstab_files[@]}"
  fi
  cmd umount -l "${VAR_MOUNTPOINT}"
  cmd rmdir "${VAR_MOUNTPOINT}" || true
  ONEXITERR=("${ONEXITERR[@]:1}")
  ONEXITRESTORE=(rootfs_fstab_patch_restore "${ONEXITRESTORE[@]}")
}

rootfs_patch_files_cleanup() {
  while read -r -d '' p; do
    pf="$(realpath -s --relative-to="${WORKDIR}/files" "${p%.*}")"
    if [[ "${pf}" =~ ^home/ ]]; then
      pf="/${pf}"
    fi
    cmd mv -vf "${pf}"{.orig,} || true
  done < <(find "${WORKDIR}/files" -type f -name '*.patch' -print0)
}

rootfs_patch_files() {
  ONEXITERR=(rootfs_patch_files_cleanup "${ONEXITERR[@]}")
  # patch existing files
  eprint 'Patching existing files'
  while read -r -d '' p; do
    pf="$(realpath -s --relative-to="${WORKDIR}/files" "${p%.*}")"
    # /home patches use the current root
    if [[ "${pf}" =~ ^home/ ]]; then
      pf="/${pf}"
    fi
    if [[ -f "${pf}" ]]; then
      if [[ ! -f "${pf}.orig" ]]; then
        eprint "Backing up '/${pf}' to '/${pf}.orig'"
        cmd cp -a "${pf}"{,.orig}
      fi
      if [[ "${pf}" =~ ^/ ]]; then
        eprint "Patching '${pf}'"
        (
          cd /
          epatch "${p}"
        )
      else
        eprint "Patching '/${pf}'"
        epatch "${p}"
      fi
    fi
  done < <(find "${WORKDIR}/files" -type f -name '*.patch' -print0)
  ONEXITERR=("${ONEXITERR[@]:1}")
  ONEXITRESTORE=(rootfs_patch_files_cleanup "${ONEXITRESTORE[@]}")
}

rootfs_remove_old_files() {
  # try to remove files from older versions
  eprint 'Remove files from older versions'
  cmd rm -f {etc,usr/lib}/systemd/system/local-fs-pre.target.wants/steamos-convert-home-to-btrfs*.service \
    usr/lib/steamos/steamos-convert-home-to-btrfs-progress || true
}

rootfs_copy_files_cleanup() {
  while read -r -d '' p; do
    cmd rm -f "${p}" || true
    cmd rmdir -p --ignore-fail-on-non-empty "$(dirname "${p}")" || true
  done < <(find "${WORKDIR}/files" -type f,l -not -name '*.patch*' -exec realpath -s -z --relative-to="${WORKDIR}/files" '{}' +)
}

rootfs_copy_files() {
  ONEXITERR=(rootfs_copy_files_cleanup "${ONEXITERR[@]}")
  eprint 'Copy needed files'
  find "${WORKDIR}/files" -type f,l -not -name '*.patch*' -exec realpath -s -z --relative-to="${WORKDIR}/files" '{}' + |
    xargs -0 tar -cf - -C "${WORKDIR}/files" | tar -xvf - --no-same-owner
  eprint "Copy installer to '${STEAMOS_BTRFS_INSTALL_PATH}'"
  # the WORKDIR and the STEAMOS_BTRFS_INSTALL_PATH could be the same location but it's hard to determine
  # a temporary archive is created to avoid ending up with an empty directory
  local tmpfile
  tmpfile="$(mktemp)"
  cmd tar -czf "${tmpfile}" -C "${WORKDIR}" --exclude=.git .
  cmd rm -rf "${STEAMOS_BTRFS_INSTALL_PATH#/}" || true
  cmd mkdir -p "${STEAMOS_BTRFS_INSTALL_PATH#/}"
  cmd tar -xzvf "${tmpfile}" --no-same-owner -C "${STEAMOS_BTRFS_INSTALL_PATH#/}"
  cmd rm -f "${tmpfile}"
  cmd chmod 755 "${STEAMOS_BTRFS_INSTALL_PATH#/}"
  if is_true "${NOCONVERTHOME}"; then
    eprint 'Disable /home conversion services'
    cmd rm -f usr/lib/systemd/system/*.target.wants/steamos-convert-home-to-btrfs*.service || true
    cmd touch "${NOCONVERTHOME_FILE_FLAG#/}"
  else
    eprint 'Enable /home conversion services'
    cmd rm -f "${NOCONVERTHOME_FILE_FLAG#/}" || true
  fi
  if is_true "${NOAUTOUPDATE}"; then
    eprint 'Auto-update disabled'
    cmd touch "${NOAUTOUPDATE_FILE_FLAG#/}"
  else
    eprint 'Auto-update enabled'
    cmd rm -f "${NOAUTOUPDATE_FILE_FLAG#/}" || true
  fi
  # try to remount /etc overlay to refresh the lowerdir otherwise the files look corrupted
  eprint "Remount /etc overlay to refresh the installed files"
  cmd mount -o remount /etc || true
  ONEXITERR=("${ONEXITERR[@]:1}")
  ONEXITRESTORE=(rootfs_copy_files_cleanup "${ONEXITRESTORE[@]}")
}

home_steam_download_workaround() {
  # set up Steam's 'downloading' and 'temp' folders as btrfs subvolumes and disable COW
  if [[ "$(blkid -o value -s TYPE "${HOME_DEVICE}")" == 'btrfs' ]]; then
    eprint "Set up Steam's 'downloading' and 'temp' folders as btrfs subvolumes and disable COW"
    for d in "${HOME_MOUNTPOINT}"/deck/.local/share/Steam/steamapps/{downloading,temp}; do
      if ! btrfs subvolume show "${d}" &>/dev/null; then
        cmd mkdir -p "${d}"
        cmd rm -rf "${d}"
        cmd btrfs subvolume create "${d}"
        cmd chattr +C "${d}"
        d_parts=("${HOME_MOUNTPOINT}"/deck)
        readarray -d'/' -t -O1 d_parts <<<"${d#"${d_parts[0]}"/}"
        i=1
        for p in "${d_parts[@]:1}"; do
          d_parts[${i}]="${d_parts[$((i - 1))]}/${p%[[:space:]]*}"
          i=$((i + 1))
        done
        cmd chown 1000:1000 "${d_parts[@]}"
      fi
    done
  fi
}

fstrim_timer_enable_cleanup() {
  if [[ -d "${VAR_MOUNTPOINT}" ]]; then
    if mountpoint -q "${VAR_MOUNTPOINT}"; then
      cmd umount -l "${VAR_MOUNTPOINT}" || true
    fi
    cmd rmdir "${VAR_MOUNTPOINT}" || true
  fi
}

fstrim_timer_enable() {
  ONEXITERR=(fstrim_timer_enable_cleanup "${ONEXITERR[@]}")
  # synchronize the /var partition with the new pacman state if needed
  eprint 'Enable fstrim.timer for periodic TRIM'
  VAR_MOUNTPOINT="$(mktemp -d)"
  cmd mount "${VAR_DEVICE}" "${VAR_MOUNTPOINT}"
  cmd mkdir -p "${VAR_MOUNTPOINT}/lib/overlays/etc/upper/systemd/system/timers.target.wants"
  cmd ln -s /usr/lib/systemd/system/fstrim.timer "${VAR_MOUNTPOINT}/lib/overlays/etc/upper/systemd/system/timers.target.wants/fstrim.timer" || true
  # try to remount /etc overlay to refresh the lowerdir otherwise the files look corrupted
  eprint "Remount /etc overlay to refresh the changed files"
  cmd mount -o remount /etc || true
  cmd systemctl start fstrim.timer || true
  cmd umount -l "${VAR_MOUNTPOINT}"
  cmd rmdir "${VAR_MOUNTPOINT}" || true
  ONEXITERR=("${ONEXITERR[@]:1}")
}

home_copy_desktop_file() {
  eprint "Copy 'steamos-btrfs.desktop' file to the Desktop"
  cmd mkdir -p "${HOME_MOUNTPOINT}"/deck/{Desktop,.local/share/applications} || true
  cmd cp -a "${WORKDIR}/steamos-btrfs.desktop" "${HOME_MOUNTPOINT}/deck/Desktop/" || true
  cmd cp -a "${WORKDIR}/steamos-btrfs.desktop" "${HOME_MOUNTPOINT}/deck/.local/share/applications/" || true
  cmd chown deck:deck "${HOME_MOUNTPOINT}"/deck/{Desktop{,/steamos-btrfs.desktop},.local{,/share{,/applications{,/steamos-btrfs.desktop}}}} || true
}

rootfs_inject_cleanup() {
  export PATH="${oPATH}"
  export LD_LIBRARY_PATH="${oLD_LIBRARY_PATH}"
  cd /
  if [[ -d "${ROOTFS_MOUNTPOINT}" ]]; then
    if mountpoint -q "${ROOTFS_MOUNTPOINT}"; then
      cmd btrfs property set "${ROOTFS_MOUNTPOINT}" ro true || true
      cmd umount -l "${ROOTFS_MOUNTPOINT}" || true
    fi
    cmd rmdir "${ROOTFS_MOUNTPOINT}" || true
  fi
}

# $1 the rootfs device
rootfs_inject() {
  ROOTFS_DEVICE="${1:?'Missing rootfs device.'}"
  VAR_DEVICE="$(determine_var_device "${ROOTFS_DEVICE}")"
  HOME_DEVICE="$(determine_home_device "${ROOTFS_DEVICE}")"
  ONEXITRESTORE=()
  ONEXITERR=(rootfs_inject_cleanup "${ONEXITERR[@]}")
  ROOTFS_MOUNTPOINT="$(mktemp -d)"
  eprint "Mount '${ROOTFS_DEVICE}' on '${ROOTFS_MOUNTPOINT}' and make it writable"
  cmd mount "${ROOTFS_DEVICE}" "${ROOTFS_MOUNTPOINT}"
  export PATH="${oPATH}:${ROOTFS_MOUNTPOINT}/usr/bin"
  export LD_LIBRARY_PATH="${oLD_LIBRARY_PATH}:${ROOTFS_MOUNTPOINT}/usr/lib"
  cmd btrfs property set "${ROOTFS_MOUNTPOINT}" ro false
  cd "${ROOTFS_MOUNTPOINT}"
  rootfs_install_packages
  rootfs_fstab_patch
  rootfs_patch_files
  rootfs_remove_old_files
  rootfs_copy_files
  home_steam_download_workaround
  fstrim_timer_enable
  home_copy_desktop_file
  cmd btrfs property set "${ROOTFS_MOUNTPOINT}" ro true
  export PATH="${oPATH}"
  export LD_LIBRARY_PATH="${oLD_LIBRARY_PATH}"
  cmd umount -l "${ROOTFS_MOUNTPOINT}"
  cmd rmdir "${ROOTFS_MOUNTPOINT}" || true
  ONEXITERR=("${ONEXITERR[@]:1}")
  ONEXITRESTORE=()
}

main() {
  config_load
  cmd_handler
  update_check
  root_handler
  if [[ -f "${WORKDIR}/version" ]]; then
    eprompt '' "This installer will inject the Btrfs payload into the system or update the existing one.\nVersion: $(head -n 1 "${WORKDIR}/version")" 'Proceed' 'Abort'
  else
    eprompt '' 'This installer will inject the Btrfs payload into the system or update the existing one.' 'Proceed' 'Abort'
  fi
  log_handler
  rootfs_device_selection
  local ask_converthome=0
  for rootfs_dev in "${ROOTFS_DEVICES[@]}"; do
    local home_dev=''
    home_dev="$(determine_home_device "${rootfs_dev}")"
    if [[ "$(blkid -o value -s TYPE "${home_dev}")" != 'btrfs' ]]; then
      ask_converthome=1
      break
    fi
  done
  if [[ "${ask_converthome}" -eq 1 ]]; then
    local converthome
    if is_true "${NOCONVERTHOME}"; then
      converthome=0
    else
      converthome=1
    fi
    # ask the user if they want to convert their home partition to btrfs
    if EPROMPT_VALUE_DEFAULT="${converthome}" eprompt 'Install Btrfs /home converter' 'Do you wish to install the necessary files to migrate your home partition to btrfs on the next boot ?\nThis operation can not be undone once it is started!\n(mounting and formatting of SD cards with btrfs, f2fs, ext4 filesystems will still be available)' 'Convert /home' 'Keep /home as ext4'; then
      NOCONVERTHOME=0
    elif [[ "$?" -eq 1 ]]; then
      NOCONVERTHOME=1
    else
      return 2
    fi
  fi
  local update
  if is_true "${NOAUTOUPDATE}"; then
    update=0
  else
    update=1
  fi
  # determine if the user wants to automatically pull updates from gitlab
  if EPROMPT_VALUE_DEFAULT="${update}" eprompt 'Auto-update' 'Do you wish to always pull the latest version when updating or changing the SteamOS channel ?\n This will automatically fetch the latest script bundle from gitlab when SteamOS performs an update or switches the channel.\n(Highly recommended to leave enabled in case of needed future changes)' 'Enable Auto-update' 'Disable Auto-update'; then
    NOAUTOUPDATE=0
  elif [[ "$?" -eq 1 ]]; then
    NOAUTOUPDATE=1
  else
    return 2
  fi
  trap err ERR
  trap quit SIGINT SIGQUIT SIGTERM EXIT
  local i=0
  for rootfs_dev in "${ROOTFS_DEVICES[@]}"; do
    # only install once into unique rootfs devs
    local rootfs_dev_real=''
    rootfs_dev_real="$(realpath "${rootfs_dev}")"
    local found=0
    for rfs_dev_o in "${ROOTFS_DEVICES[@]:0:${i}}"; do
      if [[ "$(realpath "${rfs_dev_o}")" == "${rootfs_dev_real}" ]]; then
        found=1
        break
      fi
    done
    if [[ "${found}" -ne 1 ]]; then
      rootfs_inject "${rootfs_dev}"
    fi
    i=$((i + 1))
  done
  if ! is_true "${NOCONVERTHOME}" && [[ "${ask_converthome}" -eq 1 ]]; then
    if EPROMPT_VALUE_DEFAULT=0 eprompt 'Installation Complete' 'Done. You can reboot the system now or reimage the system.\n\nChoose Proceed to reboot the Steam Deck now, or Cancel to stay.\nThe conversion of the /home partition will happen on the next reboot if you selected the option. Once it is done, it will reboot just one more time.' 'Reboot now' 'Reboot later'; then
      cmd systemctl reboot
    fi
  else
    eprint 'Installation Complete.'
  fi
}

main
