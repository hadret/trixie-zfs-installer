#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
INSTALLER="${SCRIPT_DIR}/debian13-zbm-install.sh"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/install.env}"
DRY_RUN=no

case "${1:-}" in
--dry-run)
  DRY_RUN=yes
  shift
  ;;
"") ;;
*) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
(( $# == 0 )) || { printf 'Unexpected argument: %s\n' "$1" >&2; exit 2; }

declare -A INHERITED=() INHERITED_VALUE=() FILE_VALUE=() PROVIDED=() VALUE=() SOURCE=()
declare -a CURATED=(
  DISK TARGET_HOSTNAME ADMIN_USER TIMEZONE KEYMAP KEYBOARD_VARIANT LOCALE
  DESKTOP ENCRYPTION AUTOLOGIN
)

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

[[ "$DRY_RUN" == yes || $EUID -eq 0 ]] || die "Run this wrapper as root (sudo -i), or use --dry-run."

remember_environment() {
  local name
  while IFS= read -r name; do
    INHERITED["$name"]=yes
    INHERITED_VALUE["$name"]="${!name}"
  done < <(compgen -e)
}

load_config() {
  local name config_path="$CONFIG_FILE"
  remember_environment
  if [[ -e "$config_path" ]]; then
    [[ -r "$config_path" ]] || die "Cannot read ${config_path}."
    set -a
    # shellcheck disable=SC1090
    source "$config_path"
    set +a
  fi
  CONFIG_FILE="$config_path"
  for name in "${CURATED[@]}"; do
    if [[ ! -v INHERITED[$name] && -v $name ]]; then
      FILE_VALUE["$name"]="${!name}"
    fi
  done
  for name in "${!INHERITED[@]}"; do
    printf -v "$name" '%s' "${INHERITED_VALUE[$name]}"
    export "${name?}"
  done
  for name in "${CURATED[@]}"; do
    if [[ -v INHERITED[$name] ]]; then
      PROVIDED["$name"]=yes
    fi
  done
}

resolve_config() {
  local output name
  if ! output="$(bash "$INSTALLER" --print-config)"; then
    return 1
  fi
  # Output is shell-escaped assignments emitted by the trusted installer.
  source /dev/stdin <<<"$output"
  for name in "${CURATED[@]}"; do
    VALUE["$name"]="${!name}"
  done
  RESOLVED_CONFIG="$output"
}

pick_input() {
  local name="$1" prompt="$2" result
  result="$(gum input --prompt "${prompt}: " --value "${VALUE[$name]}")" || return 1
  [[ "$result" == "${VALUE[$name]}" ]] || SOURCE["$name"]="picked"
  VALUE["$name"]="$result"
}

pick_filter() {
  local name="$1" prompt="$2" values="$3" result
  result="$(gum filter --placeholder "$prompt" --value "${VALUE[$name]}" <<<"$values")" || return 1
  [[ "$result" == "${VALUE[$name]}" ]] || SOURCE["$name"]="picked"
  VALUE["$name"]="$result"
}

xkb_list() {
  local kind="$1" layout="${2:-}"
  awk -v kind="$kind" -v layout="${layout}:" '
    /^!/ { if ($2 == kind) { active = 1; next }; active = 0 }
    !active || !NF { next }
    kind == "layout" { print $1; next }
    kind == "variant" && $2 == layout { print $1 }
  ' /usr/share/X11/xkb/rules/base.lst
}

timezone_choices() {
  if timedatectl list-timezones 2>/dev/null; then
    return 0
  fi
  [[ -r /usr/share/zoneinfo/zone1970.tab ]] || die "Cannot list timezones."
  {
    printf '%s\n' Etc/UTC
    awk '!/^#/ { print $3 }' /usr/share/zoneinfo/zone1970.tab
  } | sort -u
}

locale_choices() {
  if [[ -r /usr/share/i18n/SUPPORTED ]]; then
    awk '$2 == "UTF-8" { print $1 }' /usr/share/i18n/SUPPORTED | sort -u
  else
    printf '%s\n' en_US.UTF-8
  fi
}

live_disk() {
  local source parent
  source="$(findmnt -n -o SOURCE /run/live/medium 2>/dev/null || true)"
  [[ -n "$source" ]] || return 0
  source="$(readlink -f -- "$source")"
  parent="$(lsblk -no PKNAME "$source" 2>/dev/null | head -n1)"
  [[ -n "$parent" ]] && readlink -f -- "/dev/${parent}"
}

disk_choices() {
  local link real live name
  declare -A seen=()
  live="$(live_disk)"
  for link in /dev/disk/by-id/*; do
    [[ -e "$link" && "$link" != *-part* ]] || continue
    name="${link##*/}"
    [[ "$name" != nvme-eui.* && "$name" != wwn-* ]] || continue
    real="$(readlink -f -- "$link")"
    [[ -b "$real" && "$(lsblk -dno TYPE "$real" 2>/dev/null)" == disk ]] || continue
    [[ -z "$live" || "$real" != "$live" ]] || continue
    [[ -z "${seen[$real]:-}" ]] || continue
    seen["$real"]=yes
    printf '%s\t%s\n' "$link" "$(lsblk -dno SIZE,MODEL "$real" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  done
}

pick_disk() {
  local choices selected selected_value path details
  local -a choose_args=(--header "Installation disk (the live USB is excluded)")
  choices="$(disk_choices)"
  [[ -n "$choices" ]] || die "No eligible whole disks found under /dev/disk/by-id/."
  selected_value="$(awk -F '\t' -v path="${VALUE[DISK]}" '$1 == path { print; exit }' <<<"$choices")"
  [[ -z "$selected_value" ]] || choose_args+=(--selected "$selected_value")
  selected="$(gum choose "${choose_args[@]}" <<<"$choices")" || return 1
  IFS=$'\t' read -r path details <<<"$selected"
  gum confirm \
    --prompt.foreground 196 \
    "Use ${path} (${details})? Every partition will be destroyed later." || return 1
  [[ "$path" == "${VALUE[DISK]}" ]] || SOURCE[DISK]="picked"
  VALUE[DISK]="$path"
}

pick_missing_values() {
  local options variants locales prior_variant prior_source
  if [[ ! -v PROVIDED[DISK] ]]; then
    if [[ "$DRY_RUN" == yes ]]; then
      pick_input DISK "Target disk (/dev/disk/by-id/... whole-disk path)"
    else
      pick_disk
    fi
  fi
  [[ -v PROVIDED[TARGET_HOSTNAME] ]] || pick_input TARGET_HOSTNAME "Hostname"
  [[ -v PROVIDED[ADMIN_USER] ]] || pick_input ADMIN_USER "Admin user"

  if [[ ! -v PROVIDED[TIMEZONE] ]]; then
    pick_filter TIMEZONE "Timezone" "$(timezone_choices)"
  fi

  if [[ ! -v PROVIDED[KEYMAP] ]]; then
    [[ -r /usr/share/X11/xkb/rules/base.lst ]] || die "xkb-data is required for the keyboard picker."
    pick_filter KEYMAP "Keyboard layout" "$(xkb_list layout)"
  fi
  if [[ ! -v PROVIDED[KEYBOARD_VARIANT] ]]; then
    prior_variant="${VALUE[KEYBOARD_VARIANT]}"
    prior_source="${SOURCE[KEYBOARD_VARIANT]}"
    variants="$(xkb_list variant "${VALUE[KEYMAP]}")"
    pick_filter KEYBOARD_VARIANT "Keyboard variant ((none) = standard)" "$(printf '(none)\n%s\n' "$variants")"
    [[ "${VALUE[KEYBOARD_VARIANT]}" == "(none)" ]] && VALUE[KEYBOARD_VARIANT]=""
    [[ "${VALUE[KEYBOARD_VARIANT]}" != "$prior_variant" ]] || SOURCE[KEYBOARD_VARIANT]="$prior_source"
  fi

  if [[ ! -v PROVIDED[LOCALE] ]]; then
    locales="$(locale_choices)"
    pick_filter LOCALE "Locale" "$locales"
  fi

  if [[ ! -v PROVIDED[DESKTOP] ]]; then
    options="$(bash "$INSTALLER" --print-options DESKTOP)"
    pick_filter DESKTOP "Desktop" "$options"
  fi
  if [[ ! -v PROVIDED[ENCRYPTION] ]]; then
    options="$(bash "$INSTALLER" --print-options ENCRYPTION)"
    pick_filter ENCRYPTION "ZFS encryption" "$options"
  fi
  if [[ "${VALUE[ENCRYPTION]}" == yes && "${VALUE[DESKTOP]}" != none && ! -v PROVIDED[AUTOLOGIN] ]]; then
    options="$(bash "$INSTALLER" --print-options AUTOLOGIN)"
    pick_filter AUTOLOGIN "LightDM autologin" "$options"
  fi
}

export_values() {
  local name
  for name in "${CURATED[@]}"; do
    if [[ -v PROVIDED[$name] || "${SOURCE[$name]:-}" == picked || "${SOURCE[$name]:-}" == file ]]; then
      printf -v "$name" '%s' "${VALUE[$name]}"
      export "${name?}"
    else
      unset "$name"
    fi
  done
}

show_review() {
  local name label
  printf '\nConfiguration\n\n'
  for name in "${CURATED[@]}"; do
    if [[ -v PROVIDED[$name] ]]; then
      label="env"
    else
      label="${SOURCE[$name]:-default}"
    fi
    printf '  %-18s %-45s [%s]\n' "$name" "${VALUE[$name]:-(empty)}" "$label"
  done
  printf '\nPasswords and the final ERASE confirmation are collected by the installer.\n\n'
}

write_config() {
  local temporary
  temporary="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
  {
    printf '# Generated by zbm-installer.sh. Passwords are intentionally omitted.\n'
    printf '%s\n' "$RESOLVED_CONFIG"
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$CONFIG_FILE"
}

load_config
resolve_config || die "Existing configuration is invalid."

INTERACTIVE=no
if [[ "$DRY_RUN" == yes ]]; then
  [[ -t 0 && -t 1 ]] || die "--dry-run requires an interactive terminal."
  command -v gum >/dev/null 2>&1 || die "gum is required for --dry-run."
  INTERACTIVE=yes
elif [[ "${NONINTERACTIVE:-no}" != yes && -t 0 && -t 1 ]]; then
  command -v gum >/dev/null 2>&1 || die "gum is required for the interactive installer."
  INTERACTIVE=yes
fi

while :; do
  for _name in "${CURATED[@]}"; do
    if [[ -v PROVIDED[$_name] ]]; then
      SOURCE["$_name"]="env"
    elif [[ -v FILE_VALUE[$_name] ]]; then
      SOURCE["$_name"]="file"
    else
      SOURCE["$_name"]="default"
    fi
  done

  if [[ "$INTERACTIVE" == yes ]]; then
    pick_missing_values || die "Cancelled."
  fi

  [[ -n "${VALUE[DISK]}" ]] || die "DISK is required; set it in the environment or ${CONFIG_FILE}."
  export_values
  resolve_config || die "Configuration validation failed."

  if [[ "$INTERACTIVE" != yes ]]; then
    break
  fi

  show_review
  if [[ "$DRY_RUN" == yes ]]; then
    _continue_label="Save"
  else
    _continue_label="Install"
  fi
  case "$(gum choose "$_continue_label" "Start over" "Quit")" in
  "$_continue_label") break ;;
  "Start over")
    for _name in "${CURATED[@]}"; do
      if [[ ! -v PROVIDED[$_name] ]]; then
        unset 'SOURCE[$_name]'
        if [[ -v FILE_VALUE[$_name] ]]; then
          printf -v "$_name" '%s' "${FILE_VALUE[$_name]}"
          export "${_name?}"
        else
          unset "$_name"
        fi
      fi
    done
    resolve_config || die "Could not restore installer defaults."
    ;;
  *) exit 0 ;;
  esac
done

write_config
printf 'Saved configuration to %s\n' "$CONFIG_FILE"
if [[ "$DRY_RUN" == yes ]]; then
  printf 'Would exec: set -a; source %q; set +a; exec bash %q\n' "$CONFIG_FILE" "$INSTALLER"
  exit 0
fi
set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a
exec bash "$INSTALLER"
