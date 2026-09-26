#!/bin/bash
# Build Linux and package a Debian/VMware image without changing host accounts.
set -euo pipefail
export LC_ALL=C
KERNEL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ACTION=${1:-help}
[[ $# == 0 ]] || shift
OUT="$(dirname "$KERNEL")/vmware-linux-5.4.18-auto"
JOBS=4
SUFFIX=
MIRROR=https://deb.debian.org/debian
DISK=20G
usage() {
    cat <<'EOF'
Usage: scripts/build-vmware-image.sh {build|pack|all} [options]
  build             Compile kernel and modules using the existing .config
  pack              Package an already built kernel into a fresh Debian 12 VM
  all               Build, then package
  --output DIR      Output directory (default: ../vmware-linux-5.4.18-auto)
  --jobs N          Parallel build jobs (default: 4)
  --localversion S  Build suffix, e.g. -lab3 (build/all only)
  --mirror URL      Debian bookworm mirror (default: https://deb.debian.org/debian)
  --disk-size SIZE  Raw disk size (default: 20G)
  -h, --help        Show help

pack/all require root and mount/loop privileges. Run build as the source owner.
No automatic host package installation. No host account/password changes.
Cockpit: https://VM_IP:9090; login as ruci and enable administrative access.
Image accounts: root / 1 and ruci / 1 (sudo). SSH enabled; root and ruci password login allowed (isolated labs only).
Existing output images are never overwritten. A failed package uses a new output
folder on retry. This script does not boot-test the resulting image.
EOF
}
while (($#)); do
    case "$1" in
        --output|--jobs|--localversion|--mirror|--disk-size)
            (($# >= 2)) || { echo "Missing value: $1" >&2; exit 2; }
            case "$1" in
                --output) OUT=$2;; --jobs) JOBS=$2;; --localversion) SUFFIX=$2;;
                --mirror) MIRROR=$2;; --disk-size) DISK=$2;;
            esac
            shift 2;;
        -h|--help) usage; exit 0;;
        *) echo "Unknown option: $1" >&2; exit 2;;
    esac
done
case "$ACTION" in help|-h|--help) usage; exit 0;; build|pack|all) ;; *) usage; exit 2;; esac
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid job count' >&2; exit 2; }
[[ "$DISK" =~ ^[1-9][0-9]*[GM]$ ]] || { echo 'Disk size must use G or M, e.g. 20G' >&2; exit 2; }
[[ "$SUFFIX" =~ ^[-a-zA-Z0-9._]*$ ]] || { echo 'Invalid localversion' >&2; exit 2; }
if [[ "$ACTION" == pack && -n "$SUFFIX" ]]; then
    echo '--localversion is only valid for build/all' >&2; exit 2
fi
OUT=$(realpath -m "$OUT")
need() { command -v "$1" >/dev/null || { echo "Missing command: $1" >&2; exit 1; }; }
for cmd in make python3 flock; do need "$cmd"; done
[[ -f "$KERNEL/.config" ]] || { echo 'Configure the kernel (.config) first' >&2; exit 1; }
if [[ "$ACTION" != build ]]; then
    [[ $EUID == 0 ]] || { echo 'pack/all require root' >&2; exit 1; }
    for cmd in debootstrap qemu-img grub-install parted mkfs.ext4 losetup \
        mount umount mountpoint unshare udevadm blkid chroot depmod tar sha256sum flock grub-script-check; do need "$cmd"; done
    [[ -d /usr/lib/grub/i386-pc ]] || { echo 'Install grub-pc-bin' >&2; exit 1; }
    # Re-execute the whole operation in a private mount namespace. Marker uses
    # an inherited namespace identity, not a caller-controlled boolean alone.
    current_ns=$(readlink /proc/self/ns/mnt)
    if [[ ${VMIMAGE_MOUNT_NS:-} != "$current_ns" ]]; then
        export VMIMAGE_SCRIPT="$KERNEL/scripts/build-vmware-image.sh"
        extra_args=()
        [[ -z "$SUFFIX" ]] || extra_args=(--localversion "$SUFFIX")
        exec unshare --mount --propagation private bash -c \
          'export VMIMAGE_MOUNT_NS=$(readlink /proc/self/ns/mnt); exec bash "$VMIMAGE_SCRIPT" "$@"' \
          vmimage "$ACTION" --output "$OUT" --jobs "$JOBS" --mirror "$MIRROR" \
          --disk-size "$DISK" "${extra_args[@]}"
    fi
fi
mkdir -p "$OUT"
exec 9>"$OUT/.build.lock"
need flock
flock -n 9 || { echo 'Output directory is in use' >&2; exit 1; }
if [[ "$ACTION" != build ]]; then
    for name in system.raw debian-linux-5.4.18.vmdk debian-linux-5.4.18.vmx vmware-linux-5.4.18.zip rootfs; do
        [[ ! -e "$OUT/$name" ]] || { echo "Refusing to overwrite $OUT/$name; use another --output" >&2; exit 1; }
    done
fi
if [[ "$ACTION" != pack ]]; then
    cp "$KERNEL/.config" "$OUT/kernel.config.before"
    if [[ -n "$SUFFIX" ]]; then
        "$KERNEL/scripts/config" --file "$KERNEL/.config" --set-str LOCALVERSION "$SUFFIX"
        "$KERNEL/scripts/config" --file "$KERNEL/.config" --disable LOCALVERSION_AUTO
    fi
    "$KERNEL/scripts/config" --file "$KERNEL/.config" --disable NFP
    make -C "$KERNEL" olddefconfig
    # The objtool exception is valid only for an empty thunk_64.o.
    if grep -Eq '^CONFIG_(PREEMPTION|TRACE_IRQFLAGS|DEBUG_LOCK_ALLOC)=y' "$KERNEL/.config"; then
        echo 'Configuration produces nonempty thunk_64.o; review objtool workaround first.' >&2; exit 1
    fi
    make -C "$KERNEL" -j"$JOBS" WERROR=0 OBJECT_FILES_NON_STANDARD_thunk_64.o=y \
        CFLAGS_kaslr_64.o=-fcommon CFLAGS_pgtable_64.o=-fcommon \
        CFLAGS_smpboot.o=-fno-stack-protector 2>&1 | tee "$OUT/kernel-build.log"
fi
[[ "$ACTION" != build ]] || { echo "Build complete: $KERNEL/arch/x86/boot/bzImage"; exit 0; }
for file in arch/x86/boot/bzImage System.map modules.order include/config/kernel.release; do
    [[ -s "$KERNEL/$file" ]] || { echo "Missing build artifact: $file" >&2; exit 1; }
done
KVER=$(cat "$KERNEL/include/config/kernel.release")
[[ "$KVER" =~ ^[a-zA-Z0-9._+-]+$ ]] || { echo 'Invalid kernel release' >&2; exit 1; }
ROOTFS="$OUT/rootfs"
LOOPDEV=
cleanup() {
    status=$?
    trap - EXIT
    if mountpoint -q "$ROOTFS"; then
        if ! umount -R "$ROOTFS"; then
            echo 'Unmount failed; disk will NOT be converted. Inspect remaining mounts.' >&2
            exit 1
        fi
    fi
    if [[ -n "$LOOPDEV" ]]; then losetup -d "$LOOPDEV" || status=1; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
exec > >(tee -a "$OUT/image-build.log") 2>&1
truncate -s "$DISK" "$OUT/system.raw"
parted -s "$OUT/system.raw" mklabel msdos mkpart primary ext4 1MiB 100% set 1 boot on
LOOPDEV=$(losetup --find --show --partscan "$OUT/system.raw")
udevadm settle
mkfs.ext4 -L debian-root -O ^metadata_csum_seed,^orphan_file "${LOOPDEV}p1"
mkdir "$ROOTFS"
mount "${LOOPDEV}p1" "$ROOTFS"
debootstrap --arch=amd64 --variant=minbase bookworm "$ROOTFS" "$MIRROR"
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR bookworm main
deb $MIRROR bookworm-updates main
deb https://security.debian.org/debian-security bookworm-security main
EOF
# minbase may not contain CA certificates yet; use HTTP until installed.
sed -i 's|https://|http://|g' "$ROOTFS/etc/apt/sources.list"
mount --rbind /dev "$ROOTFS/dev"
mount --make-rslave "$ROOTFS/dev"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"
printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"
chroot "$ROOTFS" apt-get update
chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd-sysv udev initramfs-tools iproute2 iputils-ping sudo ca-certificates \
    locales vim-tiny open-vm-tools systemd-resolved openssh-server \
    cockpit cockpit-system cockpit-networkmanager network-manager policykit-1
make -C "$KERNEL" INSTALL_MOD_PATH="$ROOTFS" INSTALL_MOD_STRIP=1 modules_install
mkdir -p "$ROOTFS/boot"
cp "$KERNEL/arch/x86/boot/bzImage" "$ROOTFS/boot/vmlinuz-$KVER"
cp "$KERNEL/System.map" "$ROOTFS/boot/System.map-$KVER"
cp "$KERNEL/.config" "$ROOTFS/boot/config-$KVER"
rm -f "$ROOTFS/lib/modules/$KVER/build" "$ROOTFS/lib/modules/$KVER/source"
chroot "$ROOTFS" depmod -a "$KVER"
ROOT_UUID=$(blkid -s UUID -o value "${LOOPDEV}p1")
[[ -n "$ROOT_UUID" ]]
printf 'UUID=%s / ext4 defaults 0 1\n' "$ROOT_UUID" > "$ROOTFS/etc/fstab"
echo debian-kernel54 > "$ROOTFS/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 debian-kernel54\n::1 localhost ip6-localhost\n' > "$ROOTFS/etc/hosts"
chroot "$ROOTFS" ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
chroot "$ROOTFS" useradd -m -s /bin/bash -G sudo ruci
printf 'root:1\nruci:1\n' | chroot "$ROOTFS" chpasswd
# Debian reads sshd_config.d before defaults; first value wins.
mkdir -p "$ROOTFS/etc/ssh/sshd_config.d" "$ROOTFS/run/sshd"
cat > "$ROOTFS/etc/ssh/sshd_config.d/00-vmware-lab.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
EOF
chroot "$ROOTFS" /usr/sbin/sshd -t
# Regenerate host keys on first boot, so independently cloned images differ.
cat > "$ROOTFS/etc/systemd/system/ssh-host-keys.service" <<'EOF'
[Unit]
Description=Generate SSH host keys on first boot
Before=ssh.service
[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes
EOF
mkdir -p "$ROOTFS/etc/systemd/system/ssh.service.d"
cat > "$ROOTFS/etc/systemd/system/ssh.service.d/host-keys.conf" <<'EOF'
[Unit]
Requires=ssh-host-keys.service
After=ssh-host-keys.service
EOF
rm -f "$ROOTFS"/etc/ssh/ssh_host_*
# Cockpit networking uses NetworkManager, not systemd-networkd.
# Fresh images have no hardware-bound connection profiles: NM automatically
# creates DHCP connections for newly discovered Ethernet adapters.
rm -f "$ROOTFS/etc/systemd/network/20-vmware.network"
mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
cat > "$ROOTFS/etc/NetworkManager/conf.d/10-vmware.conf" <<'EOF'
[main]
plugins=ifupdown,keyfile
dns=systemd-resolved
[ifupdown]
managed=true
EOF
# Do not configure Ethernet here: leave those devices to NetworkManager.
mkdir -p "$ROOTFS/etc/network"
printf 'auto lo\niface lo inet loopback\n' > "$ROOTFS/etc/network/interfaces"
systemctl --root="$ROOTFS" disable systemd-networkd.service systemd-networkd.socket \
    systemd-networkd-wait-online.service
systemctl --root="$ROOTFS" mask systemd-networkd.service systemd-networkd.socket
systemctl --root="$ROOTFS" enable NetworkManager.service systemd-resolved \
    cockpit.socket open-vm-tools.service serial-getty@ttyS0.service ssh.service
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
mkdir -p "$ROOTFS/etc/initramfs-tools/conf.d"
printf 'MODULES=most\nCOMPRESS=gzip\n' > "$ROOTFS/etc/initramfs-tools/conf.d/custom-kernel"
printf 'ahci\nata_piix\nsd_mod\next4\nmptspi\nvmxnet3\ne1000\n' > "$ROOTFS/etc/initramfs-tools/modules"
chroot "$ROOTFS" update-initramfs -c -k "$KVER"
grub-install --target=i386-pc --boot-directory="$ROOTFS/boot" \
    --modules='part_msdos ext2' --no-floppy "$LOOPDEV"
cat > "$ROOTFS/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
serial --unit=0 --speed=115200
terminal_input console serial
terminal_output console serial
menuentry 'Debian 12 - Linux $KVER' {
    insmod part_msdos
    insmod ext2
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    linux /boot/vmlinuz-$KVER root=UUID=$ROOT_UUID ro console=tty0 console=ttyS0,115200n8
    initrd /boot/initrd.img-$KVER
}
EOF
grub-script-check "$ROOTFS/boot/grub/grub.cfg"
rm -f "$ROOTFS/usr/sbin/policy-rc.d" "$ROOTFS/var/lib/dbus/machine-id"
: > "$ROOTFS/etc/machine-id"
chroot "$ROOTFS" apt-get clean
sync
umount -R "$ROOTFS"
losetup -d "$LOOPDEV"
LOOPDEV=
udevadm settle
[[ -z $(losetup -j "$OUT/system.raw") ]] || { echo 'Image still mapped; refusing conversion' >&2; exit 1; }
qemu-img convert -f raw -O vmdk -o subformat=monolithicSparse,adapter_type=ide \
    "$OUT/system.raw" "$OUT/debian-linux-5.4.18.vmdk"
cat > "$OUT/debian-linux-5.4.18.vmx" <<'EOF'
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "14"
displayName = "Debian - Custom Linux 5.4.18"
guestOS = "debian12-64"
firmware = "bios"
numvcpus = "2"
cpuid.coresPerSocket = "2"
memsize = "2048"
ide0:0.present = "TRUE"
ide0:0.fileName = "debian-linux-5.4.18.vmdk"
ide0:0.deviceType = "disk"
ethernet0.present = "TRUE"
ethernet0.startConnected = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "vmxnet3"
ethernet0.addressType = "generated"
svga.present = "TRUE"
floppy0.present = "FALSE"
pciBridge0.present = "TRUE"
EOF
for bridge in 4 5 6 7; do
    printf 'pciBridge%s.present = "TRUE"\npciBridge%s.virtualDev = "pcieRootPort"\npciBridge%s.functions = "8"\n' \
        "$bridge" "$bridge" "$bridge" >> "$OUT/debian-linux-5.4.18.vmx"
done
printf 'root / 1\nruci / 1 (sudo)\nConsole and SSH login enabled; root password login allowed.\n' > "$OUT/LOGIN.txt"
chmod 600 "$OUT/LOGIN.txt"
cat > "$OUT/README.md" <<EOF
# Debian 12 / Linux $KVER
Open debian-linux-5.4.18.vmx in VMware Workstation with the VMDK in the same folder.
Defaults: BIOS, 2 CPUs, 2 GiB RAM, $DISK IDE disk, VMXNET3 NAT with DHCP.
CPU, RAM and VMware NAT/bridge settings can be changed after shutdown.
Guest IP, DNS, routes and Ethernet profiles are managed by NetworkManager/Cockpit.
Console users root and ruci both have password 1. ruci has sudo access.
These weak passwords are for isolated lab use; change them before wider access.
SSH is enabled (port 22), including root password login. No desktop.
Connect using ssh root@VM_IP or ssh ruci@VM_IP. Host keys are generated on first boot.
Cockpit: https://VM_IP:9090 (first-use self-signed certificate).
Log in as ruci / 1, enable administrative access to manage networking and services.
Cockpit root web login follows Debian defaults; root SSH login remains enabled.
Cockpit socket starts at boot and launches the web service on demand.
Kernel source is unchanged by the script; .config may change.
Check uname -r, ip -br address, systemctl --failed; shut down using sudo poweroff.
The script checks packaging integrity, but does not perform an actual boot test.
EOF
(cd "$OUT"; sha256sum debian-linux-5.4.18.vmdk debian-linux-5.4.18.vmx > SHA256SUMS)
python3 - "$OUT" <<'PY'
from pathlib import Path
import sys,zipfile
b=Path(sys.argv[1]); output=b/'vmware-linux-5.4.18.zip'
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=1) as z:
    for name in ['debian-linux-5.4.18.vmx','debian-linux-5.4.18.vmdk','LOGIN.txt','README.md','SHA256SUMS']:
        z.write(b/name,'vmware-linux-5.4.18/'+name)
with zipfile.ZipFile(output) as z:
    if z.testzip() is not None: raise SystemExit('ZIP integrity failure')
print('Package complete:',output)
PY
