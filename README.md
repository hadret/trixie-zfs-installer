# trixie-zfs-installer

An installer for **Debian 13 (Trixie) with root on ZFS**, booting via rEFInd → **ZFSBootMenu**, with `/boot` on the ZFS root dataset. It follows the [ZFSBootMenu — Debian (UEFI)](https://docs.zfsbootmenu.org/en/v3.1.x/guides/debian/uefi.html) guide.

The script:

- use **ZFS native encryption** (`aes-256-gcm`, passphrase) by default, with an explicit unencrypted opt-out
- require the disk to be given as a stable `/dev/disk/by-id/…` path
- build the **same dataset hierarchy** with separate datasets for `/home`, `/root`, `/opt`, `/srv`, `/var/log`, `/var/spool`, `/var/tmp` and the container/VM stores
- create a `default` and a `baseline` boot environment
- install a **1 GiB encrypted swap partition** with a fresh random key each boot
- install **Cinnamon** (the base for [OhMyDebn](https://github.com/dougburks/ohmydebn)), minimal or full, or nothing — with LightDM autologin for the admin user on encrypted installs
- install CPU microcode and a broad firmware set (including `firmware-iwlwifi`)
- leave boot messages **visible** — `quiet` is not set anywhere

Every step is tagged in the source with `[GUIDE]` (straight from the upstream document) or `[DEVIATION]` (with the reason inline), so you can audit the script against the guide.

---

## Table of contents

- [Introduction](#introduction)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Disk layout](#disk-layout)
- [Dataset hierarchy](#dataset-hierarchy)
- [Environment variables](#environment-variables)
- [What happens at boot](#what-happens-at-boot)
- [After installation](#after-installation)
- [Upgrading OpenZFS and the pool](#upgrading-openzfs-and-the-pool)
- [Recovery](#recovery)
- [Deviations from the upstream guides](#deviations-from-the-upstream-guides)
- [Safety notes](#safety-notes)
- [Credits](#credits)
- [License](#license)

---

# Introduction

### `debian13-zbm-install.sh` — ZFSBootMenu

ZFSBootMenu is a small Linux+initramfs bundled into a single EFI executable. It imports your pool, asks for its passphrase when encrypted, lists every boot environment and snapshot it can find, and `kexec`s into the one you choose.

**Why:** boot environments become a first-class, interactive feature: rolling back a bad upgrade is a menu selection at boot, not a rescue USB. You also get a snapshot browser, a diff viewer, a recovery shell, and pool health reporting before the OS ever starts.

**The cost:** ZFSBootMenu contains its own copy of the ZFS userland and module. If you `zpool upgrade` to feature flags your ZBM image doesn't understand, it cannot import the pool and the machine won't boot. This is manageable — see [Upgrading OpenZFS and the pool](#upgrading-openzfs-and-the-pool) — but it is a real constraint you have to remember forever.

---

## Requirements

- A **64-bit UEFI** system
- A **whole disk** to erase — this script is not for dual-booting
- A **Debian 13 Live ISO**, booted in UEFI mode
- Working internet in the live environment
- ≥ 4 GiB RAM recommended (ZFS is slow below 2 GiB)
- Patience: `zfs-dkms` compiles in the live environment, which takes several minutes before anything visible happens

---

## Quick start

```bash
# In the live environment
sudo -i
apt update && apt install -y git
git clone https://github.com/hadret/trixie-zfs-installer.git
cd trixie-zfs-installer
chmod +x *.sh
```

**Find your disk.** Run the script with no `DISK` set and it lists the candidates and exits:

```bash
./debian13-zbm-install.sh
# Whole disks under /dev/disk/by-id/:
#   /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4    931.5G Samsung SSD 990 PRO
#   /dev/disk/by-id/ata-CT1000MX500SSD1_2015E2A0B1C2          931.5G CT1000MX500SSD1
```

**Install:**

```bash
DISK=/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S1A2B3C4 \
TARGET_HOSTNAME=workstation \
ADMIN_USER=alireza \
TIMEZONE=Europe/Berlin \
DESKTOP=minimal \
./debian13-zbm-install.sh
```

The script prints a full configuration summary, then requires you to type `ERASE` before touching the disk. It prompts once for the admin password and, by default, also uses it as the encrypted-pool passphrase. Set `ZFS_PASSPHRASE` to keep those credentials separate. The root account is locked unless `ROOT_PASSWORD` is supplied.

### Not sure about the keyboard layout?

The script inherits the layout you picked at the ISO boot menu. To see the variants available for your layout:

```bash
LIST_KEYBOARD=yes ./debian13-zbm-install.sh
```

An empty `KEYBOARD_VARIANT` is normal and correct for most people — it means the standard layout for that country code.

---

## Disk layout

| Part | Size | Type | Purpose |
|---|---|---|---|
| 1 | 2048 MiB | `ef00` | ESP → `/boot/efi`, holds rEFInd + ZFSBootMenu |
| 2 | 1024 MiB | `8200` / `8309` | random-key dm-crypt (default) / LUKS2 swap |
| 3 | rest − 10 MiB | `bf00` | `zroot` |

With `SWAP_MODE=none` or `SWAP_SIZE_MIB=0`, the swap partition is omitted and `zroot` becomes partition 2.

The kernel and initramfs live on the ZFS root dataset, so they are snapshotted and rolled back along with everything else. That is the whole point of the design.

---

## Dataset hierarchy

The pool is named `zroot`, matching the ZFSBootMenu guide's convention:

```
POOL/ROOT                       mountpoint=none   canmount=off
├── default                     mountpoint=/      canmount=noauto   ← active
└── baseline                    mountpoint=/      canmount=noauto   ← factory image
POOL/data                       mountpoint=none   canmount=off
├── home                        /home
│   ├── root                    /root
│   └── <username>              /home/<username>
├── opt                         /opt
├── srv                         /srv
└── var                         (container, canmount=off)
    ├── lib                     (container, canmount=off)
    │   ├── containers          /var/lib/containers      Podman
    │   ├── docker              /var/lib/docker          Docker
    │   ├── libvirt             /var/lib/libvirt         VMs
    │   └── lxc                 /var/lib/lxc             LXC
    ├── log                     /var/log
    ├── spool                   /var/spool
    └── tmp                     /var/tmp
```

The `ROOT`/`data` split is what makes boot environments useful: rolling back `ROOT/default` reverts the OS without touching home directories, logs, or VM images.

The container and VM datasets exist but **no daemons are installed**. Install `docker.io`, `podman`, `libvirt-daemon-system` or `lxc` when you need them and they land on their own datasets automatically.

### Optional tuning

With `DATASET_TUNING=yes` (the default), the script applies a light, conservative set of properties: `atime=off` across `data/var`, `setuid=off devices=off` on `/var/tmp`, `compression=zstd recordsize=64K` on `/var/log`, `recordsize=64K` on libvirt, `32K` on the container stores, and `com.sun:auto-snapshot=false` on the container/VM datasets. Set `DATASET_TUNING=no` to inherit pool defaults everywhere and tune it yourself.

---

## Environment variables

| Variable | Default | Notes |
|---|---|---|
| `DISK` | — | **Required.** Must be a `/dev/disk/by-id/…` whole-disk path |
| `TARGET_HOSTNAME` | `debian-zbm` | |
| `ADMIN_USER` | `admin` | Gets its own dataset and `sudo` |
| `ADMIN_FULLNAME` | `System Administrator` | GECOS field |
| `ADMIN_GROUPS` | see script | `sudo` is always added |
| `TIMEZONE` | `Etc/UTC` | Any zoneinfo name; validated |
| `LOCALE` | `en_US.UTF-8` | Must be UTF-8; `en_US.UTF-8` generated regardless |
| `KEYMAP` | inherited from live ISO | Validated against the XKB rules list |
| `KEYBOARD_VARIANT` | inherited from live ISO | Empty = standard layout. Pass `KEYBOARD_VARIANT=` to force none |
| `DESKTOP` | `minimal` | Cinnamon `minimal` or `full`, or `none` for headless |
| `AUTOLOGIN` | `yes` if encrypted | LightDM autologin for `ADMIN_USER`. **Forced to `no` on unencrypted pools**; with encryption, the ZBM passphrase already gates the machine |
| `SWAP_SIZE_MIB` | `1024` | `0` disables swap entirely and normalizes `SWAP_MODE` to `none` |
| `SWAP_RANDOM_SOURCE` | `/dev/urandom` | See [note on swap](#a-note-on-random-key-swap) |
| `POOL_NAME` | `zroot` | |
| `BE_NAME` | `default` | Active boot environment |
| `BASELINE_NAME` | `baseline` | |
| `BASELINE_MODE` | `clone` | `clone`, `send`, `none` |
| `ASHIFT` | `12` | |
| `COMPRESSION` | `lz4` | |
| `DATASET_TUNING` | `yes` | |
| `ENCRYPTION` | `yes` | `no` creates an unencrypted pool and does not prompt for or install a ZFS key |
| `SUITE` / `MIRROR` | `trixie` / deb.debian.org | |
| `COMPONENTS` | `main contrib non-free non-free-firmware` | |
| `ENABLE_UPDATES` / `ENABLE_SECURITY` | `yes` | Add the point-release and security suites |
| `ENABLE_BACKPORTS` | `yes` | `yes` adds the repo with Debian's native policy and seeds ZFS from it; `no` uses base Trixie |
| `ENABLE_PROPOSED_UPDATES` | `no` | Adds packages queued for the next point release at normal APT priority |
| `INSTALL_FIRMWARE` | `yes` | Microcode + probed firmware set |
| `EXTRA_PACKAGES` | — | Space-separated |
| `ADMIN_PASSWORD` | prompted | Minimum 8 characters; also used for the encrypted pool unless overridden. Passing it on the command line leaks it to `ps` |
| `ZFS_PASSPHRASE` | `ADMIN_PASSWORD` when encrypted | Minimum 8 characters; set it separately when the admin password is not easy to type with ZFSBootMenu's US keymap. Ignored when `ENCRYPTION=no` |
| `ROOT_PASSWORD` | — | Empty leaves the root account locked; a supplied value must be at least 8 characters |
| `FORCE` | `no` | `yes` skips **only** the `ERASE` confirmation |
| `LIST_KEYBOARD` | — | List variants and exit |
| `ESP_SIZE_MIB` | `2048` | |
| `SWAP_MODE` | `random` | `random`, `luks`, `none`; `none` omits the partition and normalizes its size to `0` |
| `ZBM_CMDLINE` | `loglevel=6` | ZFSBootMenu's **own** kernel command line |
| `KERNEL_CMDLINE` | `loglevel=6 systemd.show_status=yes` | What ZBM passes to Debian |
| `ZBM_TIMEOUT` | `10` | Countdown before booting `bootfs` |
| `ZBM_FALLBACK` | `yes` | Also install to `EFI/BOOT/BOOTX64.EFI` |
| `ENCRYPTION_ALGO` | `aes-256-gcm` | |
| `POOL_COMPAT` | derived | `v3.1.0` → `openzfs-2.4-linux` with backports, `openzfs-2.3-linux` without; `off` disables the pin |

> Password variables are intended for controlled unattended installs. Supplying them inline with the command can expose them to process inspection.

> **`ZBM_CMDLINE` and `KERNEL_CMDLINE` are not the same thing.** The first configures ZFSBootMenu's own kernel (what you see while it imports the pool and asks for the passphrase). The second is stored in `org.zfsbootmenu:commandline` and configures Debian. Conflating them is the most common mistake with this setup.

---

## What happens at boot

```
firmware → rEFInd → ZFSBootMenu → zroot/ROOT/default
```

rEFInd offers four ways in, all using the same EFI image:

| Entry | Behaviour |
|---|---|
| Boot default | 10s countdown, then boots `bootfs` |
| Boot to menu | always show the boot-environment selector |
| Boot immediately | no menu, no countdown |
| Verbose debug | `loglevel=7`, ZBM's full internal tracing |

Inside ZFSBootMenu: `Ctrl-H` for help, `Ctrl-S` to browse snapshots of the selected environment, `Ctrl-R` for a recovery shell.

On encrypted desktop installs, LightDM logs in `ADMIN_USER` automatically by default because the ZFSBootMenu passphrase already gates boot. `ENCRYPTION=no` and `DESKTOP=none` force autologin off. Cinnamon locks the session on suspend by default; expect the desktop keyring to ask for its password once after the first automatic login.

Change Debian's boot verbosity later without touching the bootloader:

```bash
sudo zfs set org.zfsbootmenu:commandline="loglevel=7 systemd.show_status=yes" zroot/ROOT
sudo zfs set org.zfsbootmenu:commandline="quiet loglevel=3" zroot/ROOT   # back to silent
```

The property is inherited by every environment under `ROOT`. `%{parent}` expands to the parent's value, so you can make just one environment verbose:

```bash
sudo zfs set org.zfsbootmenu:commandline="loglevel=7 %{parent}" zroot/ROOT/default
```

ZFSBootMenu's own verbosity and countdown live in `/boot/efi/EFI/ZBM/refind_linux.conf` — plain text, no regeneration needed.

---

## After installation

### Creating a new boot environment

`canmount` is **not inheritable**, and two filesystems trying to mount at `/` will prevent the system from booting. Set it explicitly on every environment:

```bash
sudo zfs snapshot POOL/ROOT/default@pre-upgrade
sudo zfs clone -o canmount=noauto -o mountpoint=/ \
    POOL/ROOT/default@pre-upgrade POOL/ROOT/new
```

You can also do this from the ZFSBootMenu boot menu instead.

### Adding a user

A per-user dataset makes the home directory exist — and **`useradd` will not copy `/etc/skel` into a directory that already exists.** It prints `Not copying any file from skel directory into it` and carries on, leaving the account with no `.bashrc` or `.profile`. Do it explicitly:

```bash
sudo zfs create -o mountpoint=/home/NAME POOL/data/home/NAME
sudo useradd -M -d /home/NAME -s /bin/bash NAME
sudo cp -a /etc/skel/. /home/NAME/
sudo chown -R NAME:NAME /home/NAME && sudo chmod 0750 /home/NAME
sudo usermod -a -G sudo NAME
sudo passwd NAME
```

### Optional fonts and printing

The minimal desktop does not install the extended font set or printing stack:

```bash
sudo apt install fonts-noto-core fonts-noto-color-emoji fonts-liberation2 \
    fonts-dejavu-core fonts-hack
sudo apt install cups cups-filters cups-browsed avahi-daemon system-config-printer
sudo usermod -a -G lpadmin USER
```

Install CUPS before adding the user to `lpadmin`; the group does not exist yet
on a system without CUPS.

### Updating ZFSBootMenu

Choose the release and kernel series you want to replace, then verify the
signed checksum manifest and the EFI image before installing it. The installer
leaves the ZFSBootMenu public key at `/etc/signify/zfsbootmenu.pub`.

```bash
version=v3.1.0
kernel=6.12
asset="zfsbootmenu-release-x86_64-${version}-linux${kernel}.EFI"
base="https://github.com/zbm-dev/zfsbootmenu/releases/download/${version}"
tmpdir="$(mktemp -d)"

curl -fSL -o "${tmpdir}/sha256.sig" "${base}/sha256.sig"
curl -fSL -o "${tmpdir}/${asset}" "${base}/${asset}"

(cd "$tmpdir" && signify-openbsd -C \
  -p /etc/signify/zfsbootmenu.pub -x sha256.sig "$asset") &&

sudo install -m 0644 "${tmpdir}/${asset}" \
  "/boot/efi/EFI/ZBM-${kernel}/vmlinuz.EFI"
rm -r -- "$tmpdir"
```

Boot the new image successfully before replacing any backup or recovery image.

### Cleanup

The script leaves an `@install` or `@baseline` snapshot. Once you're happy:

```bash
sudo zfs list -t snapshot
sudo zfs destroy POOL/ROOT/default@install
```

If `BASELINE_MODE=clone`, the `@baseline` snapshot **cannot** be destroyed while the clone exists. That is deliberate — it's the guarantee a factory image should have.

---

## Upgrading OpenZFS and the pool

By default the script adds `trixie-backports` with Debian's native
`NotAutomatic: yes` / `ButAutomaticUpgrades: yes` policy and explicitly installs
ZFS from it once. Future ZFS updates from backports are then selected normally,
without pulling unrelated backports packages. Set `ENABLE_BACKPORTS=no` to use
base Trixie and omit the backports source.

### Order matters

By default the pool compatibility follows the selected ZFS package track:
`openzfs-2.4-linux` with backports, or `openzfs-2.3-linux` with base Trixie.
ZFSBootMenu v3.1.0 embeds OpenZFS 2.4 and can import either. This prevents a
routine OS-side `zpool upgrade` from enabling flags that the boot environment
cannot read. `POOL_COMPAT=off` removes this safety rail entirely.

When moving to a future OpenZFS release, follow this order:

1. **Install one verified new release image** while keeping the known-good
   recovery, backup and `EFI/BOOT/BOOTX64.EFI` images intact.
2. **Boot through the new image** and prove that it imports the pool and boots the OS.
3. **Refresh every remaining image** — release, recovery, backup and
   `EFI/BOOT/BOOTX64.EFI` — with a verified ZBM release that supports the target
   OpenZFS profile.
4. **Confirm the OS has the matching profile**, then deliberately move the pin
   and enable its feature flags:
   ```bash
   target=openzfs-2.5-linux
   test -r "/usr/share/zfs/compatibility.d/${target}"
   sudo zpool set compatibility="$target" zroot
   sudo zpool upgrade zroot
   ```

`zpool upgrade` is irreversible. Once the compatibility profile moves forward,
any older ZBM image that lacks those features is no longer a usable fallback.

---

## Recovery

The root account is locked by default. Use the admin account with `sudo` during normal operation; if that account is unavailable, use ZFSBootMenu's `Ctrl-R` recovery shell or a live ISO.

The login and pool credentials are only initialized from the same value. Changing the login password with `passwd` does **not** change the pool passphrase; that requires `zfs change-key`, updating the installed key file, and rebuilding the initramfs.

From any Debian live ISO:

```bash
sudo -i
apt update && apt install -y zfsutils-linux
zpool import -f -N -R /mnt POOL
zfs load-key -a                        # encrypted pools only
zfs mount POOL/ROOT/default
zfs mount -a

mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys
mount -t tmpfs tmpfs /mnt/run && mkdir /mnt/run/lock
chroot /mnt /bin/bash --login
mount /boot/efi
```

When done:

```bash
exit
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
zpool export -a
```

If the script recorded problems during installation, they are kept at `/root/INSTALL-WARNINGS.txt` on the installed system.

---

## Deviations from the upstream guides

The script is annotated inline, but the ones worth knowing up front:

- **2048 MiB ESP** instead of 512, leaving room for several ZBM images and rEFInd.
- **The pool key file is created for encrypted installs.** The guide's encrypted `zpool create` references `/etc/zfs/zroot.key` as a file "created in a previous step" — but the Debian page never shows that step. The script creates it before `zpool create`.
- **Export/import is spelled out.** The script always does `zpool export` → `zpool import -N -R /mnt` → mount; encrypted installs additionally run `zfs load-key` before mounting. The guide's encrypted tab omits this sequence, while the other guides in the same series include it.
- **The vdev is referenced by PARTUUID**, so the pool doesn't care about device enumeration order.
- **`EFI/BOOT/BOOTX64.EFI` fallback**, for firmware that silently drops NVRAM boot entries. The guide flags this problem and links to its Portable ZFSBootMenu page but doesn't automate it.
- **Verbose command lines**, microcode, expanded firmware, and `zfs-zed` — none of which the guide covers.

---

## Safety notes

- **This script erases an entire disk.** It is not for dual-booting. Back up first.
- `FORCE=yes` skips **only** the `ERASE` confirmation. It does not skip password prompts, and all preflight validation still runs.
- Test in a VM before running on hardware you care about. For QEMU/KVM, set a unique serial on each virtual disk so `/dev/disk/by-id` aliases appear.
- `ENCRYPTION=no` leaves the root pool, home directories, logs, and any persistent swap keyfiles readable at rest. Use it only when disk confidentiality is intentionally out of scope.
- **Your passphrase is likely the weakest link.** On encrypted installs it is typed inside ZBM, which uses a basic keymap — prefer unshifted ASCII you can type blind.

### A note on random-key swap

The swap partition uses **plain dm-crypt with a fresh key drawn from `/dev/urandom` on every boot**, via crypttab's `swap` option. Nothing on it survives a reboot.

This is *not* LUKS, and cannot be: LUKS requires a persistent header with keyslots, which is incompatible with a per-boot random key. The consequence is that **hibernation is impossible**, which is why `RESUME=none` is configured.

If you need hibernation, the script offers `SWAP_MODE=luks` — a persistent LUKS2 volume unlocked from a keyfile on the root pool. On an unencrypted pool that key is itself readable at rest, so LUKS swap provides no offline confidentiality. The script does not configure a resume device; that is left to you.

`/dev/urandom` is the default rather than `/dev/random` because they are cryptographically identical on modern kernels and `/dev/urandom` never blocks. Set `SWAP_RANDOM_SOURCE=/dev/random` if you prefer.

---

## Credits

This script is an automation wrapper. All the hard thinking belongs to the upstream projects.

### Upstream projects

- **[ZFSBootMenu](https://zfsbootmenu.org/)** — the boot environment manager the script installs.
  Documentation: <https://docs.zfsbootmenu.org/> · Source: <https://github.com/zbm-dev/zfsbootmenu>
  Thanks to Zach Dykstra and the ZFSBootMenu team.

- **[OpenZFS](https://openzfs.org/)** — ZFS on Linux itself.
  Documentation: <https://openzfs.github.io/openzfs-docs/> · Source: <https://github.com/openzfs/zfs>

### Prior art and inspiration

Other projects solving the same problem, each worth reading before you write your own:

- **[Sithuk/ubuntu-server-zfsbootmenu](https://github.com/Sithuk/ubuntu-server-zfsbootmenu)** — a mature, far more featureful Ubuntu installer: native ZFS or LUKS encryption, single/mirror/raidz topologies, integrated sanoid snapshot management with automatic pruning, an optional encrypted data pool on a second drive, and remote unlocking over SSH at boot so you can roll back a headless machine without physical access. If you're on Ubuntu rather than Debian, use this instead of this script.

- **[okhsunrog/archinstall_zfs](https://github.com/okhsunrog/archinstall_zfs)** — a ZFS-first Arch Linux installer with both a graphical (Slint/KMS) and terminal (ratatui) UI. Notably, it validates kernel/ZFS compatibility against OpenZFS release data before installing, and falls back from prebuilt modules to DKMS automatically — a class of problem this Debian script sidesteps only because Debian's kernel is frozen within a release.

- **[fnichol/cachyos-zfs-installer](https://github.com/fnichol/cachyos-zfs-installer)** — configures CachyOS with an optionally encrypted ZFS root, ZFSBootMenu, and automatic boot environments by reconfiguring Calamares to use ZFS + ZFSBootMenu instead of ext4 + systemd-boot. Its pacman hooks are the interesting part: a pre-hook snapshots the current boot environment whenever kernel or ZFS packages are about to update, and a post-hook prunes old environments by retention policy and regenerates the ZBM images. That is a genuinely better answer to "snapshot before upgrade" than doing it by hand.

---

## License

MIT. The upstream guides, ZFSBootMenu, and OpenZFS carry their own licenses — ZFS is CDDL.

## Contributing

Issues and pull requests welcome. Please test changes in a VM and say which guide section your change relates to, so the `[GUIDE]` / `[DEVIATION]` annotations in the script stay accurate.
