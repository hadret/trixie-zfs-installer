#!/usr/bin/env bash
# Debian 13 root-on-ZFS installer using rEFInd and prebuilt ZFSBootMenu.
# [GUIDE] follows upstream; [DEVIATION] marks intentional departures.
# See README.md for configuration, layout, and recovery details.
# THIS DESTROYS ALL DATA ON $DISK.

set -euo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
ZBM_PUBKEY_SOURCE="${SCRIPT_DIR}/releng/zfsbootmenu.pub"

#==============================================================================
# Keyboard detection from the live environment
#==============================================================================

_LIVE_XKBLAYOUT=""
_LIVE_XKBVARIANT=""
if [[ -r /etc/default/keyboard ]]; then
  _LIVE_XKBLAYOUT="$(
    . /etc/default/keyboard 2>/dev/null
    printf '%s' "${XKBLAYOUT:-}"
  )"
  _LIVE_XKBVARIANT="$(
    . /etc/default/keyboard 2>/dev/null
    printf '%s' "${XKBVARIANT:-}"
  )"
fi

XKB_LST="/usr/share/X11/xkb/rules/base.lst"

xkb_list() {
  local kind="$1" layout="${2:-}"
  awk -v kind="$kind" -v layout="${layout}:" '
		/^!/ { if ($2 == kind) { active = 1; next }; active = 0 }
		!active || !NF { next }
		kind == "layout" { print $1; next }
		kind == "variant" && $2 == layout {
			name = $1; $1 = $2 = ""; sub(/^ +/, "")
			print name "\t" $0
		}' "$XKB_LST"
}

list_variants() {
  local layout="$1" name description
  if [[ ! -r "$XKB_LST" ]]; then
    echo "  (xkb-data not installed; cannot list)" >&2
    return 0
  fi
  printf '  %-18s %s\n' "(none)" "standard layout for '${layout}'" >&2
  while IFS=$'\t' read -r name description; do
    printf '  %-18s %s\n' "$name" "$description"
  done < <(xkb_list variant "$layout") >&2
  return 0
}

if [[ -n "${LIST_KEYBOARD:-}" ]]; then
  _l="${LIST_KEYBOARD}"
  [[ "$_l" == "yes" ]] && _l="${KEYMAP:-${_LIVE_XKBLAYOUT:-us}}"
  echo "Keyboard variants for layout '${_l}':" >&2
  list_variants "$_l"
  exit 0
fi

#==============================================================================
# CONFIGURATION
#==============================================================================

#--- Target disk (REQUIRED, /dev/disk/by-id/... whole-disk path) --------------
DISK="${DISK:-}"

#--- ZFSBootMenu image selection ----------------------------------------------
# Pinned for reproducible installs.
ZBM_VERSION="${ZBM_VERSION:-v3.1.0}"
ZBM_BASE_URL="${ZBM_BASE_URL:-https://github.com/zbm-dev/zfsbootmenu/releases/download}"

# Linux series: all, one value, or a space-separated subset.
ZBM_KERNELS="${ZBM_KERNELS:-all}"

# Install recovery builds alongside release builds.
ZBM_RECOVERY="${ZBM_RECOVERY:-yes}"

# Keep a second copy of every release image under EFI/ZBM-BACKUP.
ZBM_BACKUP="${ZBM_BACKUP:-yes}"

# Release image copied to EFI/BOOT/BOOTX64.EFI; empty disables it.
ZBM_FALLBACK_KERNEL="${ZBM_FALLBACK_KERNEL:-6.12}"

#--- rEFInd -------------------------------------------------------------------
# Set 0 to wait indefinitely.
REFIND_TIMEOUT="${REFIND_TIMEOUT:-30}"
# Empty leaves the first rEFInd entry highlighted.
REFIND_DEFAULT="${REFIND_DEFAULT:-}"

#--- Kernel command lines -----------------------------------------------------
# ZBM_CMDLINE configures ZBM; KERNEL_CMDLINE is passed to Debian.
ZBM_CMDLINE="${ZBM_CMDLINE:-loglevel=6}"
KERNEL_CMDLINE="${KERNEL_CMDLINE:-loglevel=6 systemd.show_status=yes}"
# ZBM countdown: 0 boots immediately; -1 waits forever.
ZBM_TIMEOUT="${ZBM_TIMEOUT:-30}"

#--- Partition sizes (MiB) ----------------------------------------------------
# 2048 leaves room for multiple release, recovery, and backup images.
ESP_SIZE_MIB="${ESP_SIZE_MIB:-2048}"
SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-1024}"

#--- Swap ---------------------------------------------------------------------
# Modes: random (default), luks, or none. Hibernation is not configured.
SWAP_MODE="${SWAP_MODE:-random}"
SWAP_RANDOM_SOURCE="${SWAP_RANDOM_SOURCE:-/dev/urandom}"
SWAP_CIPHER="${SWAP_CIPHER:-aes-xts-plain64}"
SWAP_KEYSIZE="${SWAP_KEYSIZE:-512}"
SWAP_MAPPER="${SWAP_MAPPER:-cswap}"

# Install cryptsetup initramfs support when the archive provides it.
INSTALL_CRYPTSETUP_INITRAMFS="${INSTALL_CRYPTSETUP_INITRAMFS:-yes}"

#--- ZFS ----------------------------------------------------------------------
POOL_NAME="${POOL_NAME:-zroot}"
BE_NAME="${BE_NAME:-default}"
BASELINE_NAME="${BASELINE_NAME:-baseline}"
BASELINE_MODE="${BASELINE_MODE:-clone}" # clone | send | none
ASHIFT="${ASHIFT:-12}"
COMPRESSION="${COMPRESSION:-lz4}"
ENCRYPTION="${ENCRYPTION:-yes}"
ENCRYPTION_ALGO="${ENCRYPTION_ALGO:-aes-256-gcm}"
DATASET_TUNING="${DATASET_TUNING:-yes}"
POOL_COMPAT="${POOL_COMPAT:-}"

#--- Identity -----------------------------------------------------------------
TARGET_HOSTNAME="${TARGET_HOSTNAME:-debian-zbm}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_FULLNAME="${ADMIN_FULLNAME:-System Administrator}"
ADMIN_GROUPS="${ADMIN_GROUPS:-adm,cdrom,dip,plugdev,users,audio,video,netdev}"

#--- Locale / time / keyboard -------------------------------------------------
TIMEZONE="${TIMEZONE:-Etc/UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-${_LIVE_XKBLAYOUT:-us}}"
KEYBOARD_VARIANT="${KEYBOARD_VARIANT-${_LIVE_XKBVARIANT}}"

#--- Debian sources -----------------------------------------------------------
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-https://security.debian.org/debian-security}"
# non-free supplies packages such as intel-media-va-driver-non-free.
COMPONENTS="${COMPONENTS:-main contrib non-free non-free-firmware}"

ENABLE_UPDATES="${ENABLE_UPDATES:-yes}"     # ${SUITE}-updates
ENABLE_SECURITY="${ENABLE_SECURITY:-yes}"   # ${SUITE}-security
ENABLE_BACKPORTS="${ENABLE_BACKPORTS:-yes}" # Debian's native backports policy
# proposed-updates has normal priority and may be selected on upgrade.
ENABLE_PROPOSED_UPDATES="${ENABLE_PROPOSED_UPDATES:-no}"

INSTALL_FIRMWARE="${INSTALL_FIRMWARE:-yes}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

#--- Desktop ------------------------------------------------------------------
DESKTOP="${DESKTOP:-minimal}" # minimal | full | none (Cinnamon)
AUTOLOGIN_EXPLICIT=no
if [[ -v AUTOLOGIN ]]; then
  AUTOLOGIN_EXPLICIT=yes
else
  AUTOLOGIN=yes
fi
# The "works like a normal desktop" layer: audio, bluetooth, mounting, codecs,
# archives and firmware updates. Debian does not pull these in with
# a bare DE metapackage the way Ubuntu's desktop task does.
DESKTOP_EXTRAS="${DESKTOP_EXTRAS:-yes}"
INSTALL_MEDIA_ACCEL="${INSTALL_MEDIA_ACCEL:-yes}" # VA-API / VDPAU / Vulkan
INSTALL_FLATPAK="${INSTALL_FLATPAK:-no}"
INSTALL_OFFICE="${INSTALL_OFFICE:-no}"
INSTALL_UNATTENDED_UPGRADES="${INSTALL_UNATTENDED_UPGRADES:-no}"

#--- Passwords (prompted if unset) --------------------------------------------
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ZFS_PASSPHRASE="${ZFS_PASSPHRASE:-}"

#--- Misc ---------------------------------------------------------------------
FORCE="${FORCE:-no}"
HOSTID="${HOSTID:-0x00bab10c}"

#==============================================================================
# Helpers
#==============================================================================

log() { printf '\n\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2
  exit 1
}

# Failure cleanup is ownership-driven: these markers are set only after this
# run creates each resource, so the trap cannot touch an unrelated /mnt or pool.
INSTALL_POOL_CREATED=no
INSTALL_POOL_GUID=""
INSTALL_ENV_WRITTEN=no
LIVE_KEY_WRITTEN=no

secure_remove_file() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  if command -v shred >/dev/null 2>&1 &&
    shred -u -z -- "$path" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$path"
}

cleanup_on_failure() {
  local rc="$1" imported_guid="" secret
  ((rc != 0)) || return 0

  # Prevent recursion if any best-effort cleanup command itself fails.
  trap - EXIT INT TERM
  set +e
  warn "Installation failed (exit ${rc}); cleaning up this run's resources."

  if [[ "$INSTALL_ENV_WRITTEN" == "yes" ]]; then
    for secret in /mnt/run/*-install.env; do
      if [[ -e "$secret" ]] && ! rm -f -- "$secret"; then
        warn "Could not remove ${secret}; remove it manually before rebooting."
      fi
    done
    rm -f -- /mnt/root/zbm-chroot.sh /mnt/root/sources.list.new
  fi

  if [[ "$LIVE_KEY_WRITTEN" == "yes" && -n "${KEYFILE:-}" ]]; then
    secure_remove_file "$KEYFILE" ||
      warn "Could not remove live key ${KEYFILE}; remove it manually before rebooting."
  fi

  if [[ "$INSTALL_POOL_CREATED" == "yes" ]]; then
    umount -n -R /mnt 2>/dev/null || umount -n -R -l /mnt 2>/dev/null || true
    imported_guid="$(zpool get -H -o value guid "$POOL_NAME" 2>/dev/null || true)"
    if [[ -n "$imported_guid" &&
      (-z "$INSTALL_POOL_GUID" || "$imported_guid" == "$INSTALL_POOL_GUID") ]]; then
      zpool export "$POOL_NAME" 2>/dev/null ||
        warn "Could not export ${POOL_NAME}; export it manually before rebooting."
    elif [[ -n "$imported_guid" ]]; then
      warn "Refusing to export ${POOL_NAME}: imported GUID ${imported_guid} does not match ${INSTALL_POOL_GUID}."
    fi
  fi

  warn "Cleanup complete; original exit status was ${rc}."
  exit "$rc"
}

prompt_pass() {
  local __var="$1" label="$2" minlen="${3:-1}" p1 p2
  while :; do
    read -rsp "  ${label}: " p1
    echo
    read -rsp "  Confirm ${label}: " p2
    echo
    if [[ -z "$p1" ]]; then
      warn "Empty. Try again."
    elif [[ "$p1" != "$p2" ]]; then
      warn "Passwords do not match. Try again."
    elif ((${#p1} < minlen)); then
      warn "Need at least ${minlen} characters."
    else
      break
    fi
  done
  printf -v "$__var" '%s' "$p1"
  return 0
}

list_disks() {
  local l
  echo "Whole disks under /dev/disk/by-id/:" >&2
  for l in /dev/disk/by-id/*; do
    [[ "$l" == *-part* ]] && continue
    [[ -b "$l" ]] || continue
    [[ "$(lsblk -dno TYPE "$l" 2>/dev/null)" == "disk" ]] || continue
    printf '  %-72s %s\n' "$l" "$(lsblk -dno SIZE,MODEL "$l" 2>/dev/null)" >&2
  done
  return 0
}

#==============================================================================
# Preflight
#==============================================================================

[[ $EUID -eq 0 ]] || die "Run this script as root (sudo -i)."
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. This script is UEFI-only."

# Keep pool features compatible with ZFSBootMenu; never guess for unknown releases.
if [[ -z "$POOL_COMPAT" ]]; then
  case "$ZBM_VERSION" in
  v3.1.0)
    if [[ "$ENABLE_BACKPORTS" == "yes" ]]; then
      POOL_COMPAT="openzfs-2.4-linux"
    else
      POOL_COMPAT="openzfs-2.3-linux"
    fi
    ;;
  *) die "POOL_COMPAT must be set explicitly for ZFSBootMenu ${ZBM_VERSION}." ;;
  esac
fi

if [[ -z "$DISK" ]]; then
  list_disks
  die "DISK is not set. Pass a /dev/disk/by-id/... path."
fi
if [[ "$DISK" != /dev/disk/by-id/* ]]; then
  list_disks
  die "DISK must be a /dev/disk/by-id/... path (got: ${DISK})."
fi
if [[ "$DISK" == *-part* ]]; then
  die "DISK must point at a whole disk, not a partition."
fi
if [[ ! -b "$DISK" ]]; then
  list_disks
  die "${DISK} is not a block device."
fi

DISK_REAL="$(readlink -f "$DISK")"
[[ "$(lsblk -dno TYPE "$DISK_REAL")" == "disk" ]] || die "${DISK} does not resolve to a whole disk."

SECURE_BOOT_EFIVAR="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
# SecureBoot is the byte after EFI's four-byte attribute header; missing is fine.
if [[ -r "$SECURE_BOOT_EFIVAR" ]] &&
  [[ "$(od -An -tu1 -j4 -N1 "$SECURE_BOOT_EFIVAR" | tr -d '[:space:]')" == "1" ]]; then
  die "Secure Boot is enabled. The unsigned ZFSBootMenu EFI images will not boot; disable Secure Boot and retry."
fi

[[ -r "$ZBM_PUBKEY_SOURCE" ]] ||
  die "Missing vendored ZFSBootMenu signing key: ${ZBM_PUBKEY_SOURCE}"

case "$DESKTOP" in minimal | full | none) ;; *) die "DESKTOP must be minimal, full or none." ;; esac
case "$AUTOLOGIN" in yes | no) ;; *) die "AUTOLOGIN must be yes or no." ;; esac
case "$BASELINE_MODE" in clone | send | none) ;; *) die "BASELINE_MODE must be clone, send or none." ;; esac
case "$SWAP_MODE" in random | luks | none) ;; *) die "SWAP_MODE must be random, luks or none." ;; esac
case "$ENCRYPTION" in yes | no) ;; *) die "ENCRYPTION must be yes or no." ;; esac
case "$ENABLE_BACKPORTS" in yes | no) ;; *) die "ENABLE_BACKPORTS must be yes or no." ;; esac
if [[ "$ENCRYPTION" == "no" || "$DESKTOP" == "none" ]]; then
  if [[ "$AUTOLOGIN_EXPLICIT" == "yes" && "$AUTOLOGIN" == "yes" ]]; then
    warn "AUTOLOGIN=yes ignored: autologin requires an encrypted desktop install."
  fi
  AUTOLOGIN=no
fi
[[ "$ENCRYPTION" == "no" || -z "$ZFS_PASSPHRASE" || ${#ZFS_PASSPHRASE} -ge 8 ]] ||
  die "ZFS_PASSPHRASE must be at least 8 characters."
[[ "$SWAP_SIZE_MIB" =~ ^[0-9]+$ ]] || die "SWAP_SIZE_MIB must be a non-negative integer."
SWAP_SIZE_MIB=$((10#$SWAP_SIZE_MIB))
if [[ "$SWAP_MODE" == "none" ]] || ((SWAP_SIZE_MIB == 0)); then
  SWAP_MODE="none"
  SWAP_SIZE_MIB=0
fi
if [[ "$SWAP_MODE" == "luks" && "$ENCRYPTION" == "no" ]]; then
  warn "SWAP_MODE=luks stores its key on the unencrypted root pool; it provides no offline confidentiality."
fi
if [[ "$POOL_COMPAT" != "off" && ! "$POOL_COMPAT" =~ ^[A-Za-z0-9._-]+$ ]]; then
  die "POOL_COMPAT contains invalid characters: ${POOL_COMPAT}"
fi

BPO=()
[[ "$ENABLE_BACKPORTS" == "yes" ]] && BPO=(-t "${SUITE}-backports")

if [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  die "ADMIN_USER '${ADMIN_USER}' is not a valid Unix username."
fi
if [[ "$ADMIN_USER" == "root" ]]; then
  die "ADMIN_USER cannot be root."
fi

#--- Resolve the kernel selection ---------------------------------------------
ZBM_ALL_KERNELS="6.6 6.12 6.18"
if [[ "$ZBM_KERNELS" == "all" ]]; then
  ZBM_KERNEL_LIST="$ZBM_ALL_KERNELS"
else
  ZBM_KERNEL_LIST="$ZBM_KERNELS"
fi

SELECTED_KERNELS=()
for k in $ZBM_KERNEL_LIST; do
  case " $ZBM_ALL_KERNELS " in
  *" $k "*) SELECTED_KERNELS+=("$k") ;;
  *) die "ZBM_KERNELS: '${k}' is not one of: ${ZBM_ALL_KERNELS} (or 'all')." ;;
  esac
done
((${#SELECTED_KERNELS[@]} > 0)) || die "ZBM_KERNELS selected nothing."

if [[ -n "$ZBM_FALLBACK_KERNEL" ]]; then
  _found=no
  for k in "${SELECTED_KERNELS[@]}"; do
    [[ "$k" == "$ZBM_FALLBACK_KERNEL" ]] && _found=yes
  done
  if [[ "$_found" != yes ]]; then
    warn "ZBM_FALLBACK_KERNEL=${ZBM_FALLBACK_KERNEL} was not selected; using ${SELECTED_KERNELS[0]}."
    ZBM_FALLBACK_KERNEL="${SELECTED_KERNELS[0]}"
  fi
fi

#--- ESP capacity sanity check ------------------------------------------------
# Observed v3.1.0 sizes: release images run 60-70 MB, recovery images 77-84 MB.
N_KERNELS=${#SELECTED_KERNELS[@]}
EST_MIB=$((N_KERNELS * 70))
[[ "$ZBM_BACKUP" == "yes" ]] && EST_MIB=$((EST_MIB + N_KERNELS * 70))
[[ "$ZBM_RECOVERY" == "yes" ]] && EST_MIB=$((EST_MIB + N_KERNELS * 85))
[[ -n "$ZBM_FALLBACK_KERNEL" ]] && EST_MIB=$((EST_MIB + 70))
EST_MIB=$((EST_MIB + 60)) # rEFInd, FAT overhead, slack

if ((ESP_SIZE_MIB < EST_MIB)); then
  die "ESP_SIZE_MIB=${ESP_SIZE_MIB} is too small for this selection (~${EST_MIB} MiB needed). Raise it."
fi

#--- Keyboard / locale / timezone validation ----------------------------------
if [[ -r "$XKB_LST" ]]; then
  if ! xkb_list layout | grep -qx "$KEYMAP"; then
    die "KEYMAP='${KEYMAP}' is not a known XKB layout."
  fi
  if [[ -n "$KEYBOARD_VARIANT" ]]; then
    if ! xkb_list variant "$KEYMAP" | cut -f1 | grep -qx "$KEYBOARD_VARIANT"; then
      warn "KEYBOARD_VARIANT='${KEYBOARD_VARIANT}' is not valid for layout '${KEYMAP}'."
      echo "Valid variants for '${KEYMAP}':" >&2
      list_variants "$KEYMAP"
      die "Pick one of the above, or leave KEYBOARD_VARIANT empty."
    fi
  fi
else
  warn "xkb-data not available; skipping keyboard validation."
fi

[[ -e "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "TIMEZONE='${TIMEZONE}' is not a known zoneinfo name."
case "$LOCALE" in
*.UTF-8 | *.utf8) ;;
*) die "LOCALE='${LOCALE}' must be a UTF-8 locale, e.g. en_US.UTF-8." ;;
esac
if [[ -r /usr/share/i18n/SUPPORTED ]]; then
  grep -qi "^${LOCALE} UTF-8$" /usr/share/i18n/SUPPORTED ||
    warn "LOCALE='${LOCALE}' not listed in /usr/share/i18n/SUPPORTED; locale-gen may fail."
fi

#--- Partition devices --------------------------------------------------------
BOOT_PART=1
SWAP_PART=2
POOL_PART=3
if [[ "$SWAP_MODE" == "none" ]]; then
  POOL_PART=2
fi
BOOT_DEVICE="${DISK}-part${BOOT_PART}"
SWAP_DEVICE="${DISK}-part${SWAP_PART}"
POOL_DEVICE="${DISK}-part${POOL_PART}"

KEYFILE=""
[[ "$ENCRYPTION" == "yes" ]] && KEYFILE="/etc/zfs/${POOL_NAME}.key"

log "Planned configuration"
cat <<EOF
  Disk             : ${DISK}
                     -> ${DISK_REAL}  ($(lsblk -dno SIZE,MODEL "$DISK_REAL"))
  ESP              : ${BOOT_DEVICE}   ${ESP_SIZE_MIB} MiB  vfat  /boot/efi
                     (~${EST_MIB} MiB will be used by ZBM images)
  Swap             : $([[ "$SWAP_MODE" != none ]] && echo "${SWAP_DEVICE}   ${SWAP_SIZE_MIB} MiB  mode=${SWAP_MODE}" || echo "disabled")
  Pool vdev        : ${POOL_DEVICE}
  Pool             : ${POOL_NAME}  ashift=${ASHIFT}  compression=${COMPRESSION}
  Compatibility    : ${POOL_COMPAT}
  Encryption       : $([[ "$ENCRYPTION" == yes ]] && echo "${ENCRYPTION_ALGO}, native, passphrase" || echo "disabled (data readable at rest)")
  Boot environment : ${POOL_NAME}/ROOT/${BE_NAME}
  Baseline BE      : $([[ "$BASELINE_MODE" == none ]] && echo "disabled" || echo "${POOL_NAME}/ROOT/${BASELINE_NAME} (${BASELINE_MODE})")

  ZFSBootMenu      : ${ZBM_VERSION}
    kernels        : ${SELECTED_KERNELS[*]}
    release images : yes  (EFI/ZBM-<ver>/vmlinuz.EFI)
    recovery images: ${ZBM_RECOVERY}  (EFI/ZBM-RECOVERY-<ver>/vmlinuz.EFI)
    backup copies  : ${ZBM_BACKUP}  (EFI/ZBM-BACKUP/vmlinuz-<ver>.EFI)
    BOOTX64 fallback: ${ZBM_FALLBACK_KERNEL:-disabled}
  rEFInd           : timeout ${REFIND_TIMEOUT} $([[ "$REFIND_TIMEOUT" == 0 ]] && echo "(waits for you; nothing auto-boots)"), default_selection $([[ -n "$REFIND_DEFAULT" ]] && echo "'${REFIND_DEFAULT}'" || echo "not set")
  ZBM cmdline      : ${ZBM_CMDLINE}   (countdown ${ZBM_TIMEOUT}s)
  Debian cmdline   : ${KERNEL_CMDLINE}

  Hostname         : ${TARGET_HOSTNAME}
  Admin user       : ${ADMIN_USER}
  Desktop          : ${DESKTOP}  extras=${DESKTOP_EXTRAS}  autologin=${AUTOLOGIN}
  Locale / TZ      : ${LOCALE} / ${TIMEZONE}
  Keyboard         : layout=${KEYMAP} variant=$([[ -n "$KEYBOARD_VARIANT" ]] && echo "$KEYBOARD_VARIANT" || echo "(none, standard layout)")
  Components       : ${COMPONENTS}
  Suites           : ${SUITE}$([[ "$ENABLE_UPDATES" == yes ]] && echo " +updates")$([[ "$ENABLE_SECURITY" == yes ]] && echo " +security")$([[ "$ENABLE_BACKPORTS" == yes ]] && echo " +backports")$([[ "$ENABLE_PROPOSED_UPDATES" == yes ]] && echo " +proposed-updates")
EOF

if [[ "$ENABLE_PROPOSED_UPDATES" == "yes" ]]; then
  warn "${SUITE}-proposed-updates is enabled. It has NORMAL apt priority, so"
  warn "packages queued for the next point release WILL be installed on upgrade."
fi

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK_REAL" || true

if [[ "$FORCE" != "yes" ]]; then
  echo
  warn "EVERY PARTITION AND ALL DATA ON ${DISK_REAL} WILL BE DESTROYED."
  read -rp "Type ERASE to continue: " confirm
  [[ "$confirm" == "ERASE" ]] || die "Aborted."
fi

log "Collecting passwords"
[[ -n "$ROOT_PASSWORD" ]] || prompt_pass ROOT_PASSWORD "root password" 1
[[ -n "$ADMIN_PASSWORD" ]] || prompt_pass ADMIN_PASSWORD "password for ${ADMIN_USER}" 1
if [[ "$ENCRYPTION" == "yes" && -z "$ZFS_PASSPHRASE" ]]; then
  # [GUIDE] The pool passphrase must be typeable in ZFSBootMenu's minimal keymap.
  echo "  Typed inside ZFSBootMenu at every boot, on a basic keymap."
  echo "  Prefer unshifted ASCII you can find blind."
  prompt_pass ZFS_PASSPHRASE "ZFS pool passphrase" 8
fi

#==============================================================================
# APT source generation (shared by live environment and target)
#==============================================================================

APT_SUITES=("${SUITE}|${MIRROR}|")
[[ "$ENABLE_UPDATES" == "yes" ]] &&
  APT_SUITES+=("${SUITE}-updates|${MIRROR}|Point-release updates")
[[ "$ENABLE_SECURITY" == "yes" ]] &&
  APT_SUITES+=("${SUITE}-security|${SECURITY_MIRROR}|Security updates")
[[ "$ENABLE_PROPOSED_UPDATES" == "yes" ]] &&
  APT_SUITES+=("${SUITE}-proposed-updates|${MIRROR}|Queued for the next point release; normal priority")
[[ "$ENABLE_BACKPORTS" == "yes" ]] &&
  APT_SUITES+=("${SUITE}-backports|${MIRROR}|Debian's native backports policy")

# Emit sources.list; $1 is live (binary only) or target (with deb-src).
gen_sources() {
  local mode="$1" entry suite mirror note first=yes
  for entry in "${APT_SUITES[@]}"; do
    IFS='|' read -r suite mirror note <<<"$entry"
    if [[ "$first" == "no" ]]; then
      echo
      echo "# ${note}"
    fi
    echo "deb ${mirror} ${suite} ${COMPONENTS}"
    [[ "$mode" == "target" ]] && echo "deb-src ${mirror} ${suite} ${COMPONENTS}"
    first=no
  done
  return 0
}

#==============================================================================
# [GUIDE] Configure Live Environment
#==============================================================================

log "Configuring APT in the live environment"
gen_sources live >/etc/apt/sources.list
rm -f /etc/apt/sources.list.d/debian.sources
export DEBIAN_FRONTEND=noninteractive
apt update

log "Installing ZFS and helpers in the live environment (DKMS build, be patient)"
apt install -y debootstrap gdisk dkms "linux-headers-$(uname -r)" cryptsetup curl ca-certificates
apt install -y "${BPO[@]}" zfsutils-linux zfs-dkms
modprobe zfs || die "zfs module failed to load in the live environment."

if [[ "$POOL_COMPAT" != "off" &&
  ! -r "/usr/share/zfs/compatibility.d/${POOL_COMPAT}" ]]; then
  die "ZFS compatibility profile '${POOL_COMPAT}' is unavailable. Choose a profile from /usr/share/zfs/compatibility.d, or set POOL_COMPAT=off. With ENABLE_BACKPORTS=no on Trixie, use openzfs-2.3-linux."
fi

# [GUIDE] Generate /etc/hostid
log "Generating /etc/hostid"
zgenhostid -f "$HOSTID"

#==============================================================================
# [GUIDE] Disk preparation
#==============================================================================

# Refuse an imported same-name pool before any destructive work.
log "Checking for an already-imported pool named ${POOL_NAME}"
if zpool list -H -o name 2>/dev/null | grep -qx "$POOL_NAME"; then
  echo >&2
  warn "A pool named '${POOL_NAME}' is ALREADY IMPORTED in this live environment."
  warn "Export it first:   zpool export ${POOL_NAME}"
  warn "or re-run with a different name, e.g.   POOL_NAME=zzroot"
  die "Refusing to continue with an ambiguous pool name."
fi

# Arm failure cleanup only once this run is about to create resources or alter
# the target. Preflight failures and a declined ERASE confirmation need none.
trap 'cleanup_on_failure "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "Wiping ${DISK}"
swapoff -a || true
zpool labelclear -f "$DISK" 2>/dev/null || true
for p in "${DISK}"-part*; do
  [[ -b "$p" ]] || continue
  zpool labelclear -f "$p" 2>/dev/null || true
  wipefs -a "$p" || true
done
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"
udevadm settle

log "Creating partitions"
sgdisk -n "${BOOT_PART}:1m:+${ESP_SIZE_MIB}m" -t "${BOOT_PART}:ef00" -c "${BOOT_PART}:EFI" "$DISK"
if [[ "$SWAP_MODE" != "none" ]]; then
  # 8200 = Linux swap, 8309 = Linux LUKS. Getting this wrong makes
  # systemd-gpt-auto-generator create a competing unit that cannot succeed.
  swap_type=8200
  [[ "$SWAP_MODE" == "luks" ]] && swap_type=8309
  sgdisk -n "${SWAP_PART}:0:+${SWAP_SIZE_MIB}m" -t "${SWAP_PART}:${swap_type}" -c "${SWAP_PART}:swap" "$DISK"
fi
sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" -c "${POOL_PART}:${POOL_NAME}" "$DISK"

partprobe "$DISK_REAL" || true
udevadm settle
sleep 2
sgdisk -p "$DISK"

for p in "$BOOT_DEVICE" "$POOL_DEVICE"; do
  [[ -b "$p" ]] || die "Expected partition link $p does not exist after partitioning."
done
if [[ "$SWAP_MODE" != "none" && ! -b "$SWAP_DEVICE" ]]; then
  die "Expected partition link $SWAP_DEVICE does not exist."
fi

#==============================================================================
# Pool name collision check
#==============================================================================

# After the wipe, any remaining same-name pool must be on another disk.
log "Checking other disks for a pool named ${POOL_NAME}"
OTHER_POOL=no
if zpool import 2>/dev/null | awk '$1 == "pool:" { print $2 }' | grep -qx "$POOL_NAME"; then
  OTHER_POOL=yes
  echo >&2
  warn "Another pool named '${POOL_NAME}' exists on this machine, on a different disk."
  warn ""
  warn "The install itself is safe: the new pool is imported by GUID with the"
  warn "search restricted to ${POOL_DEVICE}, so the other pool is never touched."
  warn ""
  warn "The problem is later. ZFS cannot have two pools of the same name imported"
  warn "at once, so at boot ZFSBootMenu will see both and can only use one. Renaming"
  warn "a root pool afterwards is awkward."
  warn ""
  warn "Strongly recommended: abort and re-run with a unique name, e.g."
  warn "    POOL_NAME=zzroot ${0##*/} ..."
  if [[ "$FORCE" != "yes" ]]; then
    echo
    read -rp "Continue anyway with POOL_NAME=${POOL_NAME}? Type YES to proceed: " _pc
    [[ "$_pc" == "YES" ]] || die "Aborted. Re-run with a different POOL_NAME."
  fi
fi

#==============================================================================
# [GUIDE] ZFS pool creation
#==============================================================================

if [[ "$ENCRYPTION" == "yes" ]]; then
  # [GUIDE] Create the key file referenced by the encrypted-pool step.
  log "Writing pool key to ${KEYFILE}"
  mkdir -p /etc/zfs
  LIVE_KEY_WRITTEN=yes
  printf '%s' "$ZFS_PASSPHRASE" >"$KEYFILE"
  chmod 000 "$KEYFILE"
fi

log "Creating zpool ${POOL_NAME} on ${POOL_DEVICE}"
zpool_opts=(
  -f
  -o "ashift=${ASHIFT}"
  -O "compression=${COMPRESSION}"
  -O acltype=posixacl
  -O xattr=sa
  -O relatime=off
  -O atime=off
  -o autotrim=on
)
if [[ "$ENCRYPTION" == "yes" ]]; then
  zpool_opts+=(
    -O "encryption=${ENCRYPTION_ALGO}"
    -O "keylocation=file://${KEYFILE}"
    -O keyformat=passphrase
  )
fi
if [[ "$POOL_COMPAT" != "off" ]]; then
  zpool_opts+=(-o "compatibility=${POOL_COMPAT}")
fi
zpool create "${zpool_opts[@]}" -m none "$POOL_NAME" "$POOL_DEVICE"
INSTALL_POOL_CREATED=yes

# Re-import by GUID so a same-named pool on another disk cannot be selected.
POOL_GUID="$(zpool get -H -o value guid "$POOL_NAME")"
[[ -n "$POOL_GUID" ]] || die "Could not read the GUID of the new pool."
INSTALL_POOL_GUID="$POOL_GUID"
echo "  pool GUID: ${POOL_GUID}"

# [GUIDE] Create initial file systems
# Set canmount=noauto explicitly because canmount is not inherited.

log "Creating boot environment datasets"
zfs create -o mountpoint=none -o canmount=off "${POOL_NAME}/ROOT"
zfs create -o mountpoint=/ -o canmount=noauto "${POOL_NAME}/ROOT/${BE_NAME}"
zpool set "bootfs=${POOL_NAME}/ROOT/${BE_NAME}" "$POOL_NAME"

log "Creating data datasets"
zfs create -o mountpoint=none -o canmount=off "${POOL_NAME}/data"
zfs create -o mountpoint=/home "${POOL_NAME}/data/home"
zfs create -o mountpoint=/root "${POOL_NAME}/data/home/root"
zfs create -o mountpoint="/home/${ADMIN_USER}" "${POOL_NAME}/data/home/${ADMIN_USER}"
zfs create -o mountpoint=/opt "${POOL_NAME}/data/opt"
zfs create -o mountpoint=/srv "${POOL_NAME}/data/srv"
zfs create -o mountpoint=none -o canmount=off "${POOL_NAME}/data/var"
zfs create -o mountpoint=none -o canmount=off "${POOL_NAME}/data/var/lib"
zfs create -o mountpoint=none -o canmount=off "${POOL_NAME}/data/usr"
zfs create -o mountpoint=/usr/local "${POOL_NAME}/data/usr/local"
zfs create -o mountpoint=/var/lib/containers "${POOL_NAME}/data/var/lib/containers"
zfs create -o mountpoint=/var/lib/containerd "${POOL_NAME}/data/var/lib/containerd"
zfs create -o mountpoint=/var/lib/docker "${POOL_NAME}/data/var/lib/docker"
zfs create -o mountpoint=/var/lib/libvirt "${POOL_NAME}/data/var/lib/libvirt"
zfs create -o mountpoint=/var/lib/lxc "${POOL_NAME}/data/var/lib/lxc"
zfs create -o mountpoint=/var/log "${POOL_NAME}/data/var/log"
zfs create -o mountpoint=/var/spool "${POOL_NAME}/data/var/spool"
zfs create -o mountpoint=/var/tmp "${POOL_NAME}/data/var/tmp"

if [[ "$DATASET_TUNING" == "yes" ]]; then
  log "Applying per-dataset tuning"
  zfs set setuid=off devices=off "${POOL_NAME}/data/var/tmp"
  zfs set compression=zstd recordsize=64K "${POOL_NAME}/data/var/log"
  zfs set recordsize=64K "${POOL_NAME}/data/var/lib/libvirt"
  zfs set recordsize=32K "${POOL_NAME}/data/var/lib/containers"
  zfs set recordsize=32K "${POOL_NAME}/data/var/lib/docker"
  zfs set com.sun:auto-snapshot=false "${POOL_NAME}/data/var/lib/docker"
  zfs set com.sun:auto-snapshot=false "${POOL_NAME}/data/var/lib/containers"
  zfs set com.sun:auto-snapshot=false "${POOL_NAME}/data/var/lib/lxc"
  zfs set com.sun:auto-snapshot=false "${POOL_NAME}/data/var/lib/libvirt"
fi

log "Exporting and re-importing at /mnt"
zpool export "$POOL_NAME"

# [DEVIATION] Import by GUID, with the scan restricted to $POOL_DEVICE.
if ! zpool import -N -R /mnt -d "$POOL_DEVICE" "$POOL_GUID"; then
  # Fall back to the by-id directory while retaining GUID identity.
  warn "Import with -d ${POOL_DEVICE} failed; retrying against /dev/disk/by-id"
  zpool import -N -R /mnt -d /dev/disk/by-id "$POOL_GUID" ||
    die "Could not import pool ${POOL_GUID}."
fi

# Confirm we imported OUR pool and not something else.
IMPORTED_GUID="$(zpool get -H -o value guid "$POOL_NAME" 2>/dev/null || true)"
if [[ "$IMPORTED_GUID" != "$POOL_GUID" ]]; then
  die "Imported pool GUID '${IMPORTED_GUID}' does not match the pool just created ('${POOL_GUID}')."
fi

if [[ "$ENCRYPTION" == "yes" ]]; then
  zfs load-key "$POOL_NAME"
fi
zfs mount "${POOL_NAME}/ROOT/${BE_NAME}"
zfs mount -a

echo
zfs list -o name,used,mountpoint,canmount -r "$POOL_NAME"
mount | grep -q ' /mnt ' || die "${POOL_NAME}/ROOT/${BE_NAME} is not mounted at /mnt."
for d in /mnt/home /mnt/root /mnt/opt /mnt/srv /mnt/var/log /mnt/var/spool /mnt/var/tmp; do
  mountpoint -q "$d" || die "Expected dataset not mounted: $d"
done

# [GUIDE] Update device symlinks
udevadm trigger

#==============================================================================
# [GUIDE] Install Debian
#==============================================================================

log "Running debootstrap (${SUITE})"
debootstrap --include=ca-certificates "$SUITE" /mnt "$MIRROR"

log "Fixing permissions on dataset-backed directories"
chmod 0700 /mnt/root
chmod 1777 /mnt/var/tmp
chmod 0755 /mnt/home /mnt/opt /mnt/srv /mnt/var/log /mnt/var/spool

log "Copying host files into the new install"
mkdir -p /mnt/etc/zfs
cp /etc/hostid /mnt/etc/
cp /etc/resolv.conf /mnt/etc/
if [[ "$ENCRYPTION" == "yes" ]]; then
  cp "$KEYFILE" "/mnt${KEYFILE}"
  chmod 000 "/mnt${KEYFILE}"
fi

log "Preparing chroot mounts"
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount -B /dev /mnt/dev
mount -t devpts pts /mnt/dev/pts
mount -t tmpfs tmpfs /mnt/run
mkdir -p /mnt/run/lock
mkdir -p /mnt/sys/firmware/efi/efivars
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null ||
  warn "Could not mount efivarfs; rEFInd may fail to register a boot entry."

#==============================================================================
# Write configuration + chroot script
#==============================================================================

log "Writing chroot payload"

gen_sources target >/mnt/root/sources.list.new
install -D -m 0644 "$ZBM_PUBKEY_SOURCE" /mnt/etc/signify/zfsbootmenu.pub

INSTALL_ENV_WRITTEN=yes
declare -p POOL_NAME BE_NAME ENCRYPTION KEYFILE TARGET_HOSTNAME ADMIN_USER ADMIN_FULLNAME \
  ADMIN_GROUPS ROOT_PASSWORD ADMIN_PASSWORD TIMEZONE LOCALE KEYMAP \
  KEYBOARD_VARIANT SUITE INSTALL_FIRMWARE EXTRA_PACKAGES DESKTOP AUTOLOGIN \
  DESKTOP_EXTRAS INSTALL_MEDIA_ACCEL INSTALL_FLATPAK INSTALL_OFFICE \
  INSTALL_UNATTENDED_UPGRADES BOOT_DEVICE SWAP_DEVICE SWAP_SIZE_MIB SWAP_MODE \
  SWAP_RANDOM_SOURCE SWAP_CIPHER SWAP_KEYSIZE SWAP_MAPPER \
  INSTALL_CRYPTSETUP_INITRAMFS ZBM_VERSION ZBM_BASE_URL ZBM_RECOVERY ZBM_BACKUP \
  ZBM_FALLBACK_KERNEL ZBM_CMDLINE ZBM_TIMEOUT KERNEL_CMDLINE REFIND_DEFAULT \
  REFIND_TIMEOUT SELECTED_KERNELS BPO >/mnt/run/zbm-install.env
chmod 600 /mnt/run/zbm-install.env

cat >/mnt/root/zbm-chroot.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
source /run/zbm-install.env

WARNFILE=/root/INSTALL-WARNINGS.txt

log()  { printf '\n\033[1;36m -->\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() {
	printf '\033[1;33m [!]\033[0m %s\n' "$*" >&2
	printf '%s\n' "$*" >> "$WARNFILE"
}
die() {
	printf '%s\n' "$*" >> "$WARNFILE"
	printf '\033[1;31m [X]\033[0m FATAL: %s\n' "$*" >&2
	exit 1
}

export DEBIAN_FRONTEND=noninteractive

install -d -m 0755 /etc/initramfs-tools/conf.d
if [[ "$ENCRYPTION" == "yes" ]]; then
	# Restrict initramfs permissions before package triggers can embed the ZFS key.
	printf 'UMASK=0077\n' > /etc/initramfs-tools/conf.d/umask.conf
fi
printf 'RESUME=none\n' > /etc/initramfs-tools/conf.d/resume

# Install only packages present in this suite's archive.
apt_install_available() {
	local label="$1"; shift
	local avail=() p
	for p in "$@"; do
		if apt-cache show "$p" >/dev/null 2>&1; then
			avail+=("$p")
		else
			echo "    skip (not in archive): ${p}"
		fi
	done
	if (( ${#avail[@]} > 0 )); then
		echo "    installing ${label}: ${avail[*]}"
		apt install -y "${avail[@]}" || warn "Some ${label} packages failed to install."
	fi
	return 0
}

#--- [GUIDE] Set a hostname ---------------------------------------------------
log "Setting hostname"
echo "$TARGET_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	${TARGET_HOSTNAME}
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

#--- [GUIDE] Configure apt sources --------------------------------------------
log "Configuring APT sources"
rm -f /etc/apt/sources.list.d/debian.sources
mv /root/sources.list.new /etc/apt/sources.list
cat /etc/apt/sources.list
apt update

#--- [GUIDE] Locale, timezone, keyboard ---------------------------------------
log "Configuring locale, timezone and keyboard"
apt install -y locales keyboard-configuration console-setup tzdata

sed -i "s/^# *${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
grep -q "^${LOCALE} UTF-8"   /etc/locale.gen || echo "${LOCALE} UTF-8"   >> /etc/locale.gen
grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
update-locale "LANG=${LOCALE}"

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "$TIMEZONE" > /etc/timezone

debconf-set-selections <<EOF
keyboard-configuration keyboard-configuration/xkb-keymap select ${KEYMAP}
keyboard-configuration keyboard-configuration/variant select ${KEYBOARD_VARIANT}
console-setup console-setup/charmap47 select UTF-8
EOF
sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"${KEYMAP}\"/"             /etc/default/keyboard 2>/dev/null || true
sed -i "s/^XKBVARIANT=.*/XKBVARIANT=\"${KEYBOARD_VARIANT}\"/" /etc/default/keyboard 2>/dev/null || true
dpkg-reconfigure -f noninteractive tzdata
dpkg-reconfigure -f noninteractive keyboard-configuration console-setup

#--- [GUIDE] Kernel and ZFS ---------------------------------------------------
log "Installing kernel and ZFS"
mkdir -p /etc/dkms
apt install -y linux-headers-amd64 linux-image-amd64 dosfstools dkms
apt install -y "${BPO[@]}" zfsutils-linux zfs-dkms zfs-zed zfs-initramfs
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

#--- Microcode and firmware ---------------------------------------------------
if [[ "$INSTALL_FIRMWARE" == "yes" ]]; then
	log "Installing device firmware"
	# Include wireless, sound, and NIC firmware not pulled by firmware-linux.
	apt_install_available "firmware" \
		firmware-linux firmware-linux-free firmware-linux-nonfree \
		firmware-misc-nonfree \
		firmware-iwlwifi firmware-realtek firmware-atheros \
		firmware-brcm80211 firmware-libertas firmware-ti-connectivity \
		firmware-zd1211 firmware-mediatek firmware-marvell-prestera \
		firmware-sof-signed firmware-intel-sound \
		firmware-amd-graphics firmware-intel-graphics firmware-nvidia-graphics \
		firmware-bnx2 firmware-bnx2x firmware-qlogic firmware-cavium
	apt_install_available "wireless tooling" \
		wireless-regdb iw rfkill wpasupplicant
fi

#--- [GUIDE] ZFS systemd services ---------------------------------------------
log "Enabling ZFS systemd units"
systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target zfs-zed

#--- Encrypted swap -----------------------------------------------------------
if [[ "$SWAP_MODE" != "none" ]]; then
	log "Configuring encrypted swap (${SWAP_MODE})"
	# Keep dependencies deliberate; cryptsetup-initramfs is handled below.
	apt install -y --no-install-recommends cryptsetup cryptsetup-bin
	apt install -y systemd-cryptsetup 2>/dev/null || true

	if [[ "$INSTALL_CRYPTSETUP_INITRAMFS" == "yes" ]]; then
		if apt-cache show cryptsetup-initramfs >/dev/null 2>&1; then
			if ! apt install -y cryptsetup-initramfs; then
				warn "cryptsetup-initramfs failed to install."
			fi
		else
			warn "cryptsetup-initramfs is not in the archive; skipped."
		fi
	fi

	if [[ "$SWAP_MODE" == "luks" ]]; then
		# Persistent LUKS2 with a random key kept on the encrypted root. Root is
		# already unlocked when crypttab is processed, so this never prompts.
		install -d -m 700 /etc/cryptsetup-keys.d
		dd if=/dev/urandom of=/etc/cryptsetup-keys.d/swap.key bs=512 count=1 status=none
		chmod 400 /etc/cryptsetup-keys.d/swap.key

		cryptsetup luksFormat --type luks2 --batch-mode \
			--cipher "$SWAP_CIPHER" --key-size "$SWAP_KEYSIZE" \
			--key-file /etc/cryptsetup-keys.d/swap.key "$SWAP_DEVICE" \
			|| die "luksFormat failed on ${SWAP_DEVICE}."
		cryptsetup open --key-file /etc/cryptsetup-keys.d/swap.key \
			"$SWAP_DEVICE" "$SWAP_MAPPER" \
			|| die "Could not open the LUKS swap volume."
		# udev runs in the live environment whose /dev is bind-mounted here, so
		# the mapper node should appear; wait rather than assume.
		for _i in 1 2 3 4 5 6 7 8 9 10; do
			[[ -e "/dev/mapper/${SWAP_MAPPER}" ]] && break
			sleep 1
		done
		[[ -e "/dev/mapper/${SWAP_MAPPER}" ]] \
			|| die "/dev/mapper/${SWAP_MAPPER} never appeared."
		mkswap -L swap "/dev/mapper/${SWAP_MAPPER}"

		SWAP_UUID="$(blkid -s UUID -o value "$SWAP_DEVICE")"
		cat >> /etc/crypttab <<EOF
${SWAP_MAPPER}	UUID=${SWAP_UUID}	/etc/cryptsetup-keys.d/swap.key	luks,discard
EOF
		cryptsetup close "$SWAP_MAPPER"
	else
		# Plain dm-crypt: crypttab's 'swap' option takes a fresh key from the
		# source device and runs mkswap on every boot.
		SWAP_PARTUUID="$(blkid -s PARTUUID -o value "$SWAP_DEVICE")"
		cat >> /etc/crypttab <<EOF
${SWAP_MAPPER}	/dev/disk/by-partuuid/${SWAP_PARTUUID}	${SWAP_RANDOM_SOURCE}	swap,cipher=${SWAP_CIPHER},size=${SWAP_KEYSIZE},discard
EOF
	fi

	# Require systemd-cryptsetup explicitly; never let swap failure block boot.
	echo "/dev/mapper/${SWAP_MAPPER}	none	swap	sw,nofail,x-systemd.requires=systemd-cryptsetup@${SWAP_MAPPER}.service	0	0" >> /etc/fstab
fi

# [GUIDE] Build the final initramfs after crypttab is complete.
log "Rebuilding final initramfs"
update-initramfs -u -k all

if [[ "$ENCRYPTION" == "yes" ]]; then
	if _insecure_initrd="$(find /boot -maxdepth 1 -type f -name 'initrd.img-*' -perm /077 -print -quit)" \
		&& [[ -n "$_insecure_initrd" ]]; then
		die "Initramfs is accessible by group/other despite UMASK=0077: ${_insecure_initrd}"
	fi
fi
#--- [GUIDE] ZFSBootMenu dataset properties -----------------------------------
log "Setting ZFSBootMenu dataset properties"

# Let ZFSBootMenu set spl_hostid; Debian already has /etc/hostid in initramfs.
zfs set "org.zfsbootmenu:commandline=${KERNEL_CMDLINE}" "${POOL_NAME}/ROOT"
if [[ "$ENCRYPTION" == "yes" ]]; then
	zfs set "org.zfsbootmenu:keysource=${POOL_NAME}/ROOT/${BE_NAME}" "$POOL_NAME"
fi
zfs get -o property,value org.zfsbootmenu:commandline "${POOL_NAME}/ROOT"

#--- [GUIDE] ESP filesystem and mount -----------------------------------------
log "Creating vfat filesystem on the ESP and mounting /boot/efi"
mkfs.vfat -F32 -n EFI "$BOOT_DEVICE"
ESP_UUID="$(blkid -s UUID -o value "$BOOT_DEVICE")"
echo "UUID=${ESP_UUID}	/boot/efi	vfat	defaults	0	0" >> /etc/fstab
mkdir -p /boot/efi
mount /boot/efi

#==============================================================================
# ZFSBootMenu images
#==============================================================================

log "Downloading and verifying ZFSBootMenu ${ZBM_VERSION} images"
apt install -y ca-certificates curl signify-openbsd

ZBM_DOWNLOAD_DIR="/root/zfsbootmenu-${ZBM_VERSION}"
ZBM_SIGNIFY_KEY="/etc/signify/zfsbootmenu.pub"
ZBM_RELEASE_URL="${ZBM_BASE_URL}/${ZBM_VERSION}"
install -d -m 0700 "$ZBM_DOWNLOAD_DIR"

download_zbm_asset() {
	local name="$1" dest="${ZBM_DOWNLOAD_DIR}/${1}" part="${ZBM_DOWNLOAD_DIR}/${1}.part"
	rm -f "$part"
	curl -fSL --retry 3 --retry-delay 2 -o "$part" "${ZBM_RELEASE_URL}/${name}" \
		|| { rm -f "$part"; return 1; }
	mv "$part" "$dest"
}

download_zbm_asset sha256.sig || die "Could not download ${ZBM_RELEASE_URL}/sha256.sig"

# One directory per image prevents rEFInd folding; args: directory, label.
write_rlc() {
	local dir="$1" label="$2"
	cat > "${dir}/refind_linux.conf" <<EOF
"${label} - boot default"      "${ZBM_CMDLINE} zbm.timeout=${ZBM_TIMEOUT}"
"${label} - boot to menu"      "${ZBM_CMDLINE} zbm.show"
"${label} - boot immediately"  "${ZBM_CMDLINE} zbm.skip"
"${label} - verbose debug"     "loglevel=7 zbm.show"
EOF
	return 0
}

ZBM_FILES=()

for KV in "${SELECTED_KERNELS[@]}"; do
	release="zfsbootmenu-release-x86_64-${ZBM_VERSION}-linux${KV}.EFI"
	ZBM_FILES+=("$release")
	echo "  fetching ${release}"
	download_zbm_asset "$release" || die "Could not download ${ZBM_RELEASE_URL}/${release}"
	if [[ "$ZBM_RECOVERY" == "yes" ]]; then
		recovery="zfsbootmenu-recovery-x86_64-${ZBM_VERSION}-linux${KV}.EFI"
		ZBM_FILES+=("$recovery")
		echo "  fetching ${recovery}"
		download_zbm_asset "$recovery" || die "Could not download ${ZBM_RELEASE_URL}/${recovery}"
	fi
done

(cd "$ZBM_DOWNLOAD_DIR" && signify-openbsd -C \
	-p "$ZBM_SIGNIFY_KEY" -x sha256.sig "${ZBM_FILES[@]}") \
	|| die "ZFSBootMenu ${ZBM_VERSION} signature or checksum verification failed."

for KV in "${SELECTED_KERNELS[@]}"; do
	log "Installing ZFSBootMenu image set for Linux ${KV}"
	release="zfsbootmenu-release-x86_64-${ZBM_VERSION}-linux${KV}.EFI"
	install -D -m 0644 "${ZBM_DOWNLOAD_DIR}/${release}" "/boot/efi/EFI/ZBM-${KV}/vmlinuz.EFI"
	write_rlc "/boot/efi/EFI/ZBM-${KV}" "ZBM ${KV}"

	if [[ "$ZBM_RECOVERY" == "yes" ]]; then
		recovery="zfsbootmenu-recovery-x86_64-${ZBM_VERSION}-linux${KV}.EFI"
		install -D -m 0644 "${ZBM_DOWNLOAD_DIR}/${recovery}" \
			"/boot/efi/EFI/ZBM-RECOVERY-${KV}/vmlinuz.EFI"
		write_rlc "/boot/efi/EFI/ZBM-RECOVERY-${KV}" "ZBM RECOVERY ${KV}"
	fi

	# Backup copy of the release image, in a shared directory. These DO fold
	# into one rEFInd tag on purpose; press F2/Insert to reach the others.
	if [[ "$ZBM_BACKUP" == "yes" ]]; then
		mkdir -p /boot/efi/EFI/ZBM-BACKUP
		cp "/boot/efi/EFI/ZBM-${KV}/vmlinuz.EFI" \
		   "/boot/efi/EFI/ZBM-BACKUP/vmlinuz-${KV}.EFI"
	fi
done

if [[ -d /boot/efi/EFI/ZBM-BACKUP ]]; then
	write_rlc /boot/efi/EFI/ZBM-BACKUP "ZBM BACKUP"
fi

find "$ZBM_DOWNLOAD_DIR" -maxdepth 1 -type f -delete
rmdir "$ZBM_DOWNLOAD_DIR"

#==============================================================================
# [GUIDE] rEFInd
#==============================================================================

log "Installing and configuring rEFInd"
mountpoint -q /sys/firmware/efi/efivars || \
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true

echo 'refind refind/install_to_esp boolean true' | debconf-set-selections
apt install -y refind efibootmgr

# Not fatal: the BOOTX64.EFI fallback may still boot the machine, and aborting
# here would leave the install with no user accounts at all.
if ! refind-install; then
	warn "refind-install FAILED. Rely on the EFI/BOOT/BOOTX64.EFI fallback,"
	warn "or repair from a live ISO."
fi

# [GUIDE] Remove direct Debian-kernel entries that bypass ZFSBootMenu.
rm -f /boot/refind_linux.conf

REFIND_CONF=/boot/efi/EFI/refind/refind.conf
if [[ -f "$REFIND_CONF" ]]; then
	{
		echo ""
		echo "# Added by debian13-zbm-install.sh"
		echo "timeout ${REFIND_TIMEOUT}"
		if [[ -n "$REFIND_DEFAULT" ]]; then
			echo "default_selection \"${REFIND_DEFAULT}\""
		fi
	} >> "$REFIND_CONF"
else
	warn "${REFIND_CONF} not found; rEFInd settings were not applied."
fi

#--- Removable-media fallback -------------------------------------------------
# Fill BOOTX64.EFI only when refind-install leaves the fallback slot empty.
if [[ -e /boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
	log "EFI/BOOT/BOOTX64.EFI already present (installed by refind-install); left alone"
elif [[ -n "$ZBM_FALLBACK_KERNEL" && -f "/boot/efi/EFI/ZBM-${ZBM_FALLBACK_KERNEL}/vmlinuz.EFI" ]]; then
	log "Installing EFI/BOOT/BOOTX64.EFI fallback (ZBM, Linux ${ZBM_FALLBACK_KERNEL})"
	mkdir -p /boot/efi/EFI/BOOT
	cp "/boot/efi/EFI/ZBM-${ZBM_FALLBACK_KERNEL}/vmlinuz.EFI" \
	   /boot/efi/EFI/BOOT/BOOTX64.EFI
else
	warn "No EFI/BOOT/BOOTX64.EFI fallback installed. If this machine ignores"
	warn "NVRAM boot entries it may not boot without one."
fi

#==============================================================================
# Accounts
#==============================================================================

log "Creating accounts"
apt install -y sudo
echo "root:${ROOT_PASSWORD}" | chpasswd

# The home dataset already exists; use -M, copy skel, and filter missing groups.
IFS=',' read -ra _grps <<< "${ADMIN_GROUPS},sudo"
REAL_GROUPS="$(getent group "${_grps[@]}" 2>/dev/null \
	| cut -d: -f1 | paste -sd, || true)"
echo "  groups: ${REAL_GROUPS}"

useradd -M -d "/home/${ADMIN_USER}" -s /bin/bash \
	-c "$ADMIN_FULLNAME" -G "$REAL_GROUPS" "$ADMIN_USER"
cp -a /etc/skel/. "/home/${ADMIN_USER}/"
echo "${ADMIN_USER}:${ADMIN_PASSWORD}" | chpasswd
chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}"
chmod 0750 "/home/${ADMIN_USER}"

#==============================================================================
# Base userland
#==============================================================================

log "Installing base userland"
apt install -y \
	network-manager openssh-client ca-certificates \
	bash-completion less nano vim-tiny curl wget rsync \
	man-db pciutils usbutils htop zstd git gdisk cryptsetup \
	systemd-timesyncd
apt_install_available "diagnostics" smartmontools lm-sensors plocate tree
systemctl enable NetworkManager
systemctl enable systemd-timesyncd

if [[ -n "$EXTRA_PACKAGES" ]]; then
	# Deliberately unquoted: EXTRA_PACKAGES is a space-separated list.
	apt install -y $EXTRA_PACKAGES
fi

#==============================================================================
# Desktop
#==============================================================================

case "$DESKTOP" in
	minimal)
		log "Installing Cinnamon (minimal)"
		apt install -y cinnamon-core lightdm slick-greeter
		;;
	full)
		log "Installing Cinnamon (full)"
		apt install -y cinnamon-desktop-environment lightdm slick-greeter
		;;
	none)
		log "Skipping desktop install"
		systemctl set-default multi-user.target
		;;
esac

if [[ "$DESKTOP" != "none" ]]; then
	systemctl enable lightdm
	systemctl set-default graphical.target

	if [[ "$AUTOLOGIN" == "yes" ]]; then
		log "Enabling LightDM autologin for ${ADMIN_USER}"
		install -d -m 0755 /etc/lightdm/lightdm.conf.d
		cat > /etc/lightdm/lightdm.conf.d/60-autologin.conf <<EOF
[Seat:*]
autologin-user=${ADMIN_USER}
EOF
	fi
fi

if [[ "$DESKTOP" != "none" && "$DESKTOP_EXTRAS" == "yes" ]]; then
	log "Installing desktop integration packages"

	# Desktop integration not guaranteed by the Cinnamon metapackages: audio,
	# Bluetooth, removable media, codecs, archives and hardware services.
	apt_install_available "session integration" \
		xdg-user-dirs xdg-utils xdg-desktop-portal \
		gvfs gvfs-backends gvfs-fuse udisks2 upower

	apt_install_available "audio" \
		pipewire-audio wireplumber libspa-0.2-bluetooth

	apt_install_available "bluetooth" bluez

	# Fonts, emoji and printing are documented as optional in README.md.

	# The rough equivalent of ubuntu-restricted-extras' codec half.
	apt_install_available "codecs" \
		gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
		gstreamer1.0-plugins-ugly gstreamer1.0-libav \
		gstreamer1.0-pipewire

	apt_install_available "archives and filesystems" \
		p7zip-full unzip zip xz-utils unrar-free \
		ntfs-3g exfatprogs dosfstools

	apt_install_available "hardware services" \
		fwupd power-profiles-daemon

	apt_install_available "browser" firefox-esr

	if [[ "$INSTALL_MEDIA_ACCEL" == "yes" ]]; then
		# Hardware video decode. intel-media-va-driver-non-free is why
		# 'non-free' (not just non-free-firmware) is in the components list.
		apt_install_available "video acceleration" \
			va-driver-all vdpau-driver-all mesa-va-drivers mesa-vdpau-drivers \
			mesa-vulkan-drivers intel-media-va-driver-non-free vainfo
	fi

	apt_install_available "Cinnamon applications" \
		xdg-desktop-portal-xapp xdg-desktop-portal-gtk \
		file-roller nemo-fileroller gnome-system-monitor

	if [[ "$INSTALL_FLATPAK" == "yes" ]]; then
		apt_install_available "flatpak" flatpak
	fi

	if [[ "$INSTALL_OFFICE" == "yes" ]]; then
		apt_install_available "office" \
			libreoffice-writer libreoffice-calc libreoffice-impress
		apt_install_available "office integration" libreoffice-gtk3
	fi
fi

if [[ "$INSTALL_UNATTENDED_UPGRADES" == "yes" ]]; then
	apt_install_available "unattended upgrades" unattended-upgrades
fi

#--- Cleanup ------------------------------------------------------------------
log "Cleaning up"
apt --purge autoremove -y
apt clean

log "ESP contents"
find /boot/efi/EFI -maxdepth 2 \( -name '*.EFI' -o -name '*.efi' \) | sort
df -h /boot/efi
CHROOT_EOF

chmod 700 /mnt/root/zbm-chroot.sh

#==============================================================================
# Run the chroot stage
#==============================================================================

log "Entering chroot"
chroot /mnt /usr/bin/env bash /root/zbm-chroot.sh

#==============================================================================
# Baseline boot environment
#==============================================================================

log "Removing installer artefacts"
rm -f -- /mnt/run/zbm-install.env
INSTALL_ENV_WRITTEN=no
rm -f /mnt/root/zbm-chroot.sh /mnt/root/sources.list.new

if [[ "$BASELINE_MODE" != "none" ]]; then
  log "Creating factory baseline boot environment (${BASELINE_MODE})"
  zfs snapshot "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}"
  if [[ "$BASELINE_MODE" == "clone" ]]; then
    zfs clone -o canmount=noauto -o mountpoint=/ \
      "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}" \
      "${POOL_NAME}/ROOT/${BASELINE_NAME}"
  else
    zfs send "${POOL_NAME}/ROOT/${BE_NAME}@${BASELINE_NAME}" |
      zfs recv -u "${POOL_NAME}/ROOT/${BASELINE_NAME}"
    zfs set canmount=noauto "${POOL_NAME}/ROOT/${BASELINE_NAME}"
    zfs set mountpoint=/ "${POOL_NAME}/ROOT/${BASELINE_NAME}"
  fi
fi

#==============================================================================
# Finish
#==============================================================================

log "Final dataset layout"
zfs list -o name,used,refer,mountpoint,canmount -r "$POOL_NAME"

if [[ -s /mnt/root/INSTALL-WARNINGS.txt ]]; then
  echo
  warn "Warnings were recorded during installation:"
  sed 's/^/    /' /mnt/root/INSTALL-WARNINGS.txt >&2
  warn "Kept at /root/INSTALL-WARNINGS.txt on the new system."
fi

log "Unmounting and exporting the pool"
umount -n -R /mnt || {
  warn "Lazy-unmounting stragglers"
  umount -n -R -l /mnt || true
}
sleep 2
zpool export "$POOL_NAME"
INSTALL_POOL_CREATED=no
if [[ "$LIVE_KEY_WRITTEN" == "yes" ]]; then
  secure_remove_file "$KEYFILE"
  LIVE_KEY_WRITTEN=no
fi

log "Done"
cat <<EOF

Installation complete. Remove the live medium and reboot.

$([[ "$OTHER_POOL" == yes ]] && printf '%s\n' \
  "POOL NAME COLLISION -- READ THIS" \
  "  Another disk contains a pool named '${POOL_NAME}'; only one can be imported." \
  "  Disconnect or rename the other pool, or reinstall with a unique POOL_NAME." \
  "      zpool export ${POOL_NAME}" \
  "      zpool import <guid-of-the-other-pool> othername" \
  "")
BOOT PATH
  firmware -> rEFInd -> (a ZFSBootMenu image you pick) -> ${POOL_NAME}/ROOT/${BE_NAME}

  Kernels installed: ${SELECTED_KERNELS[*]}
  Boot each image once, then pin the winner in refind.conf:
    sudo nano /boot/efi/EFI/refind/refind.conf
      default_selection "ZBM-6.12"
      timeout 5

RECOVERY IMAGES
  Keep at least one EFI/ZBM-RECOVERY-* image after choosing a favourite.

NEW BOOT ENVIRONMENTS
  canmount is not inherited; set it explicitly on every new environment:
    sudo zfs snapshot ${POOL_NAME}/ROOT/${BE_NAME}@pre-upgrade
    sudo zfs clone -o canmount=noauto -o mountpoint=/ \\
        ${POOL_NAME}/ROOT/${BE_NAME}@pre-upgrade ${POOL_NAME}/ROOT/new

POOL COMPATIBILITY
  Current profile: ${POOL_COMPAT}
  Upgrade order: install one verified ZBM image -> boot and prove it -> replace
  every remaining release/recovery/backup/fallback -> advance the pool:
    target=openzfs-2.5-linux
    test -r "/usr/share/zfs/compatibility.d/\${target}"
    sudo zpool set compatibility="\${target}" ${POOL_NAME}
    sudo zpool upgrade ${POOL_NAME}

See README.md for packages, users, APT policy, recovery, and full upgrade notes.

EOF
