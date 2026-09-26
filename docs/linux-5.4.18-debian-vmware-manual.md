# Linux 5.4.18 + Debian 12：VMware 虚拟机制作与操作手册

本文记录本仓库实际使用的制作方案：将自编译的 Linux 5.4.18 内核、匹配的模块和 Debian 12 amd64 rootfs 组合为可启动的 VMware 虚拟机。命令包含此次遇到的问题及其规避方法，不修改内核源码。

## 1. 成品与验证范围

| 项目 | 配置 |
| --- | --- |
| 用户空间 | Debian 12 bookworm，命令行系统，无桌面 |
| 内核 | 本次构建为 `5.4.18+`，以 `include/config/kernel.release` 为准 |
| 启动 | BIOS + MBR + GRUB，不使用 UEFI |
| 磁盘 | 20 GiB 可增长 VMDK，IDE 控制器，ext4 根分区 |
| CPU / 内存 | 默认 2 vCPU / 2 GiB，关机后可调整 |
| 网络 | VMXNET3，默认 NAT + DHCP，可换模式或增加网卡 |
| 用户 | `debian`，通过 sudo 管理系统 |
| 交付目录 | `/root/gits/vmware-linux-5.4.18` |

最终需要的文件：

```text
vmware-linux-5.4.18/
├── debian-linux-5.4.18.vmx    # 虚拟机硬件配置
├── debian-linux-5.4.18.vmdk   # 含内核、rootfs 和引导程序的虚拟磁盘
├── LOGIN.txt                # 私下保存的登录凭据，不提交到 Git
├── README.md                # 启动说明
└── SHA256SUMS               # 文件校验值
```

实际制作时使用了已有 rootfs 的副本，并修复了 GRUB UUID 和登录用户。下文给出从空镜像开始的完整流程，避免依赖该备份。

最终磁盘在 QEMU/KVM 中通过了双核启动、用户登录、sudo、VMXNET3 DHCP 和正常关机测试，`systemctl --failed` 为 0。Windows VMware 曾报告缺少 PCIe 插槽，之后已补齐 VMX 根端口配置；本文不宣称修正后的配置已经通过 Windows VMware 实机验证。

## 2. 操作环境与会话约定

宿主环境为 Debian 12 amd64、GCC 12.2、Binutils 2.40。以下制作命令以 **宿主机 root** 执行；来宾系统内的操作会单独标明。

先进入独立挂载命名空间和干净的 Bash：

```bash
unshare --mount --propagation private bash --noprofile --norc
set -euo pipefail
export LC_ALL=C

KERNEL=/root/gits/linux-5.4.18
WORK=/root/gits/vmware-linux-5.4.18
ROOTFS="$WORK/rootfs"
mkdir -p "$ROOTFS"
```

- `unshare`：隔离本次挂载，避免传播到宿主机服务的命名空间。
- `bash --noprofile --norc`：不加载 Zsh、Conda 或提示符插件。
- `set -euo pipefail`：命令失败、未定义变量、管道失败时及时停止。
- `LC_ALL=C`：避免最小 rootfs 缺少宿主机 locale 时反复报警。
- 路径变量仅在当前会话中有效；后续步骤都在这个会话执行。

不要在 Zsh 主题环境直接开启 `set -u`，否则可能出现 `RPROMPT`、`CONDA_DEFAULT_ENV: parameter not set`。若已经发生，先在 Zsh 执行 `unsetopt nounset errexit pipefail`，再进入上述 Bash。

```bash
apt-get update
apt-get install -y debootstrap qemu-utils parted e2fsprogs \
  grub-pc-bin grub2-common python3
```

作用：安装 rootfs 引导工具、虚拟磁盘转换工具、分区/文件系统工具及 BIOS GRUB。软件包下载失败时先修复软件源，不跳过签名校验。

## 3. 准备内核和模块

本步骤沿用已经准备好的 `.config`，不是从任意默认配置生成通用内核。保留 initramfs、磁盘、ext4、VMXNET3/E1000、串口控制台等所需支持。

```bash
cd "$KERNEL"
cp .config "$WORK/kernel.config.before"
./scripts/config --disable NFP
make olddefconfig

make -j4 \
  WERROR=0 \
  OBJECT_FILES_NON_STANDARD_thunk_64.o=y \
  CFLAGS_kaslr_64.o=-fcommon \
  CFLAGS_pgtable_64.o=-fcommon \
  CFLAGS_smpboot.o=-fno-stack-protector \
  2>&1 | tee "$WORK/kernel-build.log"

KVER=$(cat include/config/kernel.release)
export KVER
file arch/x86/boot/bzImage
```

| 命令/参数 | 作用与边界 |
| --- | --- |
| `scripts/config --disable NFP` | 不编译此次触发断言的 Netronome 网卡驱动；不适用于需要该网卡的机器 |
| `make olddefconfig` | 根据配置依赖补齐配置 |
| `-j4` | 使用 4 个并行任务，避免占用过多内存；可按机器资源调整 |
| `WERROR=0` | 绕过 libsubcmd 中 `xrealloc()` 警告升级，不是全局关闭所有编译错误 |
| `OBJECT_FILES_NON_STANDARD_thunk_64.o=y` | 跳过该文件的 objtool；当前配置已确认此目标为空。改变抢占、锁调试、IRQ 跟踪配置后须重新评估 |
| 两个 `-fcommon` 参数 | 避免解压启动代码中 `__force_order` 重复定义引起链接失败 |
| `CFLAGS_smpboot.o=-fno-stack-protector` | 规避次级 CPU 初始化改变栈 canary 后触发检查的问题；按文件名影响 `kernel/smpboot.o` 和 `arch/x86/kernel/smpboot.o`，降低这两个编译单元的栈保护 |
| `tee` | 同时显示并保存日志；配合 `pipefail` 保留编译失败状态 |

这是针对旧内核与当前工具链的兼容规避，不代表修复了所有旧内核缺陷。每次重编译应保持这些参数一致。若已有使用全部参数构建成功的内核，可跳过重编译，但仍需设置 `KVER`。

成功标志：日志中出现 `Kernel: arch/x86/boot/bzImage is ready`，make 返回 0。只看到 `.ko` 输出不能证明整体成功。

## 4. 创建并挂载磁盘

以下仅用于**新建镜像**。已有 `system.raw` 时不要重新分区或格式化，使用第 13 节的恢复流程。

```bash
test ! -e "$WORK/system.raw"
truncate -s 20G "$WORK/system.raw"
parted -s "$WORK/system.raw" \
  mklabel msdos mkpart primary ext4 1MiB 100% set 1 boot on

LOOPDEV=$(losetup --find --show --partscan "$WORK/system.raw")
printf '%s\n' "$LOOPDEV" > "$WORK/loop-device"
udevadm settle
lsblk "$LOOPDEV"

mkfs.ext4 -L debian-root \
  -O ^metadata_csum_seed,^orphan_file "${LOOPDEV}p1"
mount "${LOOPDEV}p1" "$ROOTFS"
```

- `truncate`：创建逻辑容量为 20 GiB 的稀疏镜像。
- `parted`：创建 MBR 分区表、从 1 MiB 开始的根分区和启动标记。
- `losetup`：把文件映射为 loop 块设备并扫描分区。
- `$LOOPDEV` 如 `/dev/loop1`，代表整盘；`${LOOPDEV}p1` 代表第一分区，不要硬编码设备号。
- `mkfs.ext4`：格式化新分区，关闭旧内核不支持的两个新特性。
- `mount`：使镜像内文件系统可通过 `$ROOTFS` 访问。

## 5. 安装 Debian rootfs

```bash
debootstrap --arch=amd64 --variant=minbase \
  bookworm "$ROOTFS" http://mirrors.aliyun.com/debian

cat > "$ROOTFS/etc/apt/sources.list" <<'EOF'
deb http://mirrors.aliyun.com/debian bookworm main
deb http://mirrors.aliyun.com/debian bookworm-updates main
deb http://mirrors.aliyun.com/debian-security bookworm-security main
EOF

mount --rbind /dev "$ROOTFS/dev"
mount --make-rslave "$ROOTFS/dev"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"

cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

chroot "$ROOTFS" apt-get update
chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends \
  systemd-sysv udev initramfs-tools iproute2 iputils-ping \
  sudo ca-certificates locales vim-tiny open-vm-tools systemd-resolved
```

- `debootstrap`：安装最小 Debian 用户空间，不安装 Debian 默认内核。
- `/dev`、`/proc`、`/sys`：供 chroot 内的软件安装及 initramfs 生成访问必要的系统接口。
- `--make-rslave`：避免 `/dev` 的卸载反向传播。
- `policy-rc.d`：安装软件时不在制作环境中启动来宾服务。
- `chroot`：以镜像的目录为根运行命令；这里运行的仍是宿主机内核。
- `open-vm-tools`：提供 VMware 来宾集成；`systemd-resolved` 负责 DNS。

## 6. 安装自定义内核及模块

```bash
make -C "$KERNEL" INSTALL_MOD_PATH="$ROOTFS" \
  INSTALL_MOD_STRIP=1 modules_install

mkdir -p "$ROOTFS/boot"
cp "$KERNEL/arch/x86/boot/bzImage" "$ROOTFS/boot/vmlinuz-$KVER"
cp "$KERNEL/System.map" "$ROOTFS/boot/System.map-$KVER"
cp "$KERNEL/.config" "$ROOTFS/boot/config-$KVER"
rm -f "$ROOTFS/lib/modules/$KVER/build" "$ROOTFS/lib/modules/$KVER/source"
chroot "$ROOTFS" depmod -a "$KVER"
```

- `INSTALL_MOD_PATH`：将模块安装到镜像，避免装进宿主机 `/lib/modules`。
- `INSTALL_MOD_STRIP=1`：移除模块调试信息，减小磁盘体积。
- 三个 `cp`：安装启动内核、符号表和构建配置。
- 删除 `build/source` 链接：避免镜像内留下指向宿主机源码的失效路径。
- `depmod`：生成模块依赖索引。模块必须匹配同一内核构建。

## 7. 配置分区、用户与网络

```bash
ROOT_UUID=$(blkid -s UUID -o value "${LOOPDEV}p1")
test -n "$ROOT_UUID"
printf 'UUID=%s / ext4 defaults 0 1\n' "$ROOT_UUID" > "$ROOTFS/etc/fstab"

echo debian-kernel54 > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 debian-kernel54
::1 localhost ip6-localhost ip6-loopback
EOF

chroot "$ROOTFS" ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
chroot "$ROOTFS" useradd -m -s /bin/bash -G sudo debian
chroot "$ROOTFS" passwd debian
```

作用：获取分区 UUID、设置开机挂载和主机名、设定时区、创建可 sudo 的用户。`passwd` 交互输入密码；将账号和密码私下保存到 `LOGIN.txt`，不要将真实密码写入本文或提交到 Git。

```bash
mkdir -p "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/20-vmware.network" <<'EOF'
[Match]
Driver=vmxnet3 e1000 e1000e

[Network]
DHCP=yes
EOF

systemctl --root="$ROOTFS" enable systemd-networkd systemd-resolved \
  open-vm-tools.service serial-getty@ttyS0.service
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
```

作用：让匹配的虚拟网卡自动使用 DHCP，启用 DNS、VMware 集成与串口登录。`--root` 只创建来宾的开机启用链接，不启动宿主机服务。DNS 链接此时可能暂不可用；后续若还需在 chroot 下载包，应先提供临时可用的 DNS 配置。

## 8. 生成 initramfs

```bash
mkdir -p "$ROOTFS/etc/initramfs-tools/conf.d"
cat > "$ROOTFS/etc/initramfs-tools/conf.d/custom-kernel" <<'EOF'
MODULES=most
COMPRESS=gzip
EOF

cat > "$ROOTFS/etc/initramfs-tools/modules" <<'EOF'
ahci
ata_piix
sd_mod
ext4
mptspi
vmxnet3
e1000
EOF

chroot "$ROOTFS" update-initramfs -c -k "$KVER"
```

作用：将启动所需的磁盘、文件系统等模块放进初始内存文件系统。使用旧内核支持的 gzip。已有同版本 initramfs 时使用 `-u` 更新，而不是 `-c`。

## 9. 安装 GRUB：不要遗漏 UUID

```bash
ROOT_UUID=$(blkid -s UUID -o value "${LOOPDEV}p1")
test -n "$ROOT_UUID"

grub-install --target=i386-pc \
  --boot-directory="$ROOTFS/boot" \
  --modules="part_msdos ext2" --no-floppy "$LOOPDEV"

cat > "$ROOTFS/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=3
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

cat "$ROOTFS/etc/fstab"
cat "$ROOTFS/boot/grub/grub.cfg"
ls -lh "$ROOTFS/boot/vmlinuz-$KVER" "$ROOTFS/boot/initrd.img-$KVER"
```

- `i386-pc`：GRUB 的 BIOS 平台名称，可启动本次 64 位内核。
- 安装目标是整盘 `$LOOPDEV`，不是分区 `${LOOPDEV}p1`。
- GRUB 的 `ext2` 模块也用于读取此处的 ext4。
- `root=UUID=...` 指定 Linux 根分区，不能为空，且须与 fstab 一致。
- 未加引号的 `<<EOF` 会在写文件时展开变量；必须先确认变量已定义。
- 双控制台保留 VGA 输出和串口测试能力；普通 Windows VMware 用户无需配置串口。

## 10. 卸载、转换为 VMDK

```bash
rm -f "$ROOTFS/usr/sbin/policy-rc.d"
truncate -s 0 "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/dbus/machine-id"

cd "$WORK"
sync
umount -R "$ROOTFS"
losetup -d "$LOOPDEV"
udevadm settle
losetup -j "$WORK/system.raw"
```

作用：移除安装期服务策略，清空机器标识以便首次启动生成，写回数据并释放所有挂载。最后一条应没有输出。卸载失败时停止，不在源镜像仍被写入时转换。

```bash
test ! -e "$WORK/debian-linux-5.4.18.vmdk"
qemu-img convert -p -f raw -O vmdk \
  -o subformat=monolithicSparse,adapter_type=ide \
  "$WORK/system.raw" "$WORK/debian-linux-5.4.18.vmdk"
qemu-img info "$WORK/debian-linux-5.4.18.vmdk"
```

作用：生成单文件可增长 VMDK，容量仍为 20 GiB，实际占用取决于数据量。重新制作时使用新输出文件名或先备份旧文件。RAW 后续变化不会自动同步到 VMDK。

## 11. 创建 VMX：必须包含 PCIe 根端口

```bash
cat > "$WORK/debian-linux-5.4.18.vmx" <<'EOF'
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "14"
displayName = "Debian 12 - Linux 5.4.18"
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
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"
EOF
```

VMX 定义硬件，不含系统数据。磁盘采用相对路径，复制到 Windows 后仍可使用。`pciBridge*` 提供 PCI/PCIe 拓扑，避免 VMXNET3 启动时报告“Ethernet0 没有可用的 PCIe 插槽”。配置格式参考 [Broadcom PCIe 根端口示例](https://knowledge.broadcom.com/external/article/399033)，该文章本身针对另一种 ESXi 配置错误。

## 12. 验证、打包和 Windows 启动

### 12.1 可选的 Linux 启动测试

```bash
apt-get install -y --no-install-recommends qemu-system-x86
qemu-system-x86_64 -accel kvm -m 2048 -smp 2 \
  -drive "file=$WORK/debian-linux-5.4.18.vmdk,format=vmdk,if=ide" \
  -snapshot -nic user,model=vmxnet3 \
  -display none -serial stdio -monitor none -no-reboot
```

作用：从最终 VMDK 启动，验证双核、IDE 磁盘和 VMXNET3。`-snapshot` 将测试写入放入临时层，不改变交付磁盘。没有 KVM 时可改用 `-accel tcg`，速度较慢。QEMU 不读取 VMX，因此不能验证 VMware 专有配置。

在来宾内登录后执行：

```bash
uname -r                 # 应与 KVER 相同，本次为 5.4.18+
nproc                    # 检查可用 CPU 数量
findmnt /                # 确认根分区挂载
ip -br address           # 检查网卡地址
ip route                 # 检查默认路由
getent hosts deb.debian.org  # 检查 DNS；需要测试环境可联网
systemctl --failed       # 检查失败服务
sudo poweroff            # 正常关机
```

### 12.2 打包 ZIP

将登录信息保存为 `$WORK/LOGIN.txt`，并准备 `$WORK/README.md`。可复制本文作为完整使用手册：

```bash
cp "$KERNEL/docs/linux-5.4.18-debian-vmware-manual.md" "$WORK/README.md"
chmod 600 "$WORK/LOGIN.txt"
cd "$WORK"
sha256sum debian-linux-5.4.18.vmdk debian-linux-5.4.18.vmx > SHA256SUMS
export WORK
python3 - <<'PY'
import os
import zipfile
from pathlib import Path
base = Path(os.environ['WORK'])
archive = base.parent / (base.name + '.zip')
names = ['debian-linux-5.4.18.vmx', 'debian-linux-5.4.18.vmdk',
         'LOGIN.txt', 'README.md', 'SHA256SUMS']
for name in names:
    if not (base / name).is_file():
        raise SystemExit('Missing file: ' + name)
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=1) as z:
    for name in names:
        z.write(base / name, base.name + '/' + name)
with zipfile.ZipFile(archive) as z:
    bad = z.testzip()
    if bad:
        raise SystemExit('ZIP verification failed: ' + bad)
print(archive)
PY
```

作用：生成校验清单和 ZIP，并校验 ZIP 各文件 CRC。只打包交付文件，不打包 RAW、中间挂载目录和备份。ZIP 包含登录凭据，应按自己的虚拟机凭据管理；文档中不嵌入真实密码。

### 12.3 Windows VMware Workstation 操作

1. 下载 ZIP 并完整解压，VMX 与 VMDK 放在同一目录。
2. 选择“打开虚拟机”，打开 `.vmx`。
3. 出现移动/复制提示时，选择“我已复制该虚拟机”，生成新的 VMware 标识和 MAC。
4. 若旧版 VMware 不识别 Debian 12 类型，在设置中选择兼容的 Debian 64 位或其他 Linux 64 位。虚拟硬件版本也需由 VMware 版本支持。
5. 启动后按 `LOGIN.txt` 登录，执行上一节检查命令。

普通用户进入 root：

```bash
sudo -i          # 输入 debian 用户密码，进入 root Shell
exit             # 返回普通用户
sudo passwd root # 可选：设置 root 密码，以便控制台直接登录
```

默认未安装 SSH 服务。若需要，可在来宾内安装 `openssh-server`，通过普通用户登录后再 sudo。

### 12.4 后期修改硬件与网络

| 需求 | 操作 |
| --- | --- |
| CPU/内存 | 正常关机后在 VMware 设置中调整；CPU 核数与每插槽核数应匹配 |
| NAT | 使用宿主机共享出网，初始配置采用此模式 |
| 桥接 | 虚拟机连接宿主机所在局域网，地址由该网络 DHCP 或手工配置提供 |
| 仅主机 | 用于宿主机与虚拟机通信，通常不自动提供外网 |
| 增加网卡 | 关机后在 VMware 添加，VMXNET3/E1000 系列默认匹配 DHCP 配置 |
| 静态 IP/多网卡路由 | 修改来宾 `/etc/systemd/network/`，按网卡名或 MAC 匹配；多条默认路由需设置优先级 |
| 磁盘扩容 | VMware 扩大虚拟磁盘后，仍需在来宾中扩大分区和文件系统 |

手工修改 VMX 前关闭虚拟机和 VMware，避免配置被缓存覆盖。

## 13. 常见故障与恢复

### 13.1 已卸载，想重新修复 GRUB

在独立挂载命名空间中重新设置第 2 节变量，然后查询映射：

```bash
losetup -j "$WORK/system.raw"
```

无映射时重新执行 `LOOPDEV=$(losetup --find --show --partscan "$WORK/system.raw")`；有映射时核对完整文件路径后将 `LOOPDEV` 设为输出的设备。不要不加检查地填 `/dev/loop0`。

```bash
udevadm settle
mount "${LOOPDEV}p1" "$ROOTFS"
KVER=$(cat "$KERNEL/include/config/kernel.release")
ROOT_UUID=$(blkid -s UUID -o value "${LOOPDEV}p1")
test -n "$ROOT_UUID"
```

接着执行第 9 节安装和配置 GRUB，再卸载并重新转换 VMDK。只修复 GRUB 不需要挂载 chroot 的 `/dev`、`/proc`、`/sys`，也不要重新格式化。

### 13.2 `losetup -d` 后仍有 loop 设备

```bash
losetup -l -O NAME,AUTOCLEAR,BACK-FILE
lsblk -o NAME,MAJ:MIN,TYPE,MOUNTPOINTS "$LOOPDEV"
findmnt -R "$ROOTFS"
```

`AUTOCLEAR=1` 表示已经请求解除，但仍有占用。普通残留挂载先用 `umount -R "$ROOTFS"` 清理。不要在待卸载目录下保留 Shell 工作目录或 chroot 会话。

若当前会话看不到挂载，检查其他挂载命名空间：

```bash
lsns -t mnt -o NS,PID,COMMAND
# 用实际查到的 PID 替换下面的 1234；这里只查看
nsenter -t 1234 -m -- findmnt -rn -o SOURCE,TARGET
```

此次曾因挂载传播到 systemd 服务命名空间，造成表面卸载但 loop 不释放。须按当时的实际 PID、路径和占用情况处理，不能复用旧 PID 清单。先核对后在相应命名空间内清理镜像目录的子挂载；不要直接强制卸载或批量停止系统服务。新制作流程使用 `unshare --mount --propagation private` 预防该问题。

### 13.3 错误速查

| 现象 | 原因/处理 |
| --- | --- |
| `RPROMPT` 或 `CONDA_DEFAULT_ENV` 未定义 | Zsh 插件与 `set -u` 冲突；使用独立干净 Bash |
| `make ... Error 2` | 失败汇总；查看日志中最早的具体错误，而非最后的并行输出 |
| `xrealloc use-after-free` | 本次通过 `WERROR=0` 绕过警告升级，未修复潜在源码问题 |
| `objtool: missing symbol table` | 当前空 `thunk_64.o` 通过单文件跳过参数规避 |
| NFP `BUILD_BUG_ON failed` | 不需要 Netronome 网卡时关闭 `CONFIG_NFP` |
| `multiple definition of __force_order` | 两个解压代码文件加入 `-fcommon` |
| 双核启动 `start_secondary` 栈保护 panic | 保留 `CFLAGS_smpboot.o=-fno-stack-protector`，重新编译、复制内核并转换 VMDK |
| GRUB 能进但找不到根分区 | 检查 `search --fs-uuid`、`root=UUID=` 和 fstab，不能有空 UUID |
| 根分区挂载失败 | 检查 initramfs 是否含磁盘/ext4 模块，是否使用 gzip，ext4 特性是否兼容 |
| Ethernet0 没有可用的 PCIe 插槽 | 补齐第 11 节 VMX 的 PCIe 根端口；替换 VMX 即可，不必重新下载磁盘 |
| 修改 RAW 后 VMware 中仍是旧系统 | VMDK 是独立转换产物，需要重新转换 |
| 编译成功但不能启动 | 编译只检查构建；还需实际验证引导、SMP、模块和用户空间 |

查看编译错误：

```bash
rg -n -C 4 'error:|Error [0-9]+|multiple definition|undefined reference|No rule to make target' \
  "$WORK/kernel-build.log"
```

保留构建日志、配置和启动验证结果。源码目录不应提交虚拟磁盘、ZIP 或登录密码。

## 14. 在已安装的虚拟机内更新内核（保留 GRUB）

不需要重新制作 VMDK，也不需要重新安装 GRUB。流程是：源码机器编译并打包 → 传入虚拟机 → 安装内核和模块 → 生成 initramfs → 给原 GRUB 添加菜单项 → 重启验证。

每次更新使用不同版本后缀，例如 `-lab2`、`-lab3`，避免覆盖旧内核及 `/lib/modules/`。以下沿用当前配置及其兼容参数；若改动抢占、IRQ 跟踪等配置，需要重新评估 `thunk_64.o` 的跳过参数。保留旧内核、旧模块、旧 initramfs 和旧菜单项用于回退。

### 14.1 源码机器：编译新版本

在源码机器执行，不是在虚拟机里执行：

```bash
bash --noprofile --norc
set -euo pipefail
cd /root/gits/linux-5.4.18

./scripts/config --set-str LOCALVERSION "-lab2"
./scripts/config --disable LOCALVERSION_AUTO
make olddefconfig

make -j4 \
  WERROR=0 \
  OBJECT_FILES_NON_STANDARD_thunk_64.o=y \
  CFLAGS_kaslr_64.o=-fcommon \
  CFLAGS_pgtable_64.o=-fcommon \
  CFLAGS_smpboot.o=-fno-stack-protector

KVER=$(cat include/config/kernel.release)
printf '新内核版本：%s\n' "$KVER"
```

- `LOCALVERSION`：设置独立的版本后缀。
- 关闭 `LOCALVERSION_AUTO`：避免自动添加 Git 版本标识；最终仍以 `kernel.release` 输出为准。
- `olddefconfig`：补齐配置依赖。
- `make`：同时构建内核和模块；各兼容参数的作用见第 3 节。

### 14.2 源码机器：生成内核更新包

继续在同一 Bash 会话执行：

```bash
STAGE=$(mktemp -d /tmp/kernel-update.XXXXXX)

make INSTALL_MOD_PATH="$STAGE" \
  INSTALL_MOD_STRIP=1 modules_install

mkdir -p "$STAGE/boot"
cp arch/x86/boot/bzImage "$STAGE/boot/vmlinuz-$KVER"
cp System.map "$STAGE/boot/System.map-$KVER"
cp .config "$STAGE/boot/config-$KVER"
rm -f "$STAGE/lib/modules/$KVER/build" \
      "$STAGE/lib/modules/$KVER/source"

tar -C "$STAGE" -czf "/tmp/kernel-$KVER.tar.gz" boot lib
printf '更新包：/tmp/kernel-%s.tar.gz\n' "$KVER"
```

- `mktemp`：建立独立暂存目录，避免混入以前版本的模块。
- `modules_install`：安装到暂存目录，不修改源码机器正在运行的系统。
- `tar`：只打包内核与模块，不包含完整 rootfs 或虚拟磁盘。

将更新包复制到虚拟机 `/home/debian/`，例如使用共享文件夹。若虚拟机已安装、启用 SSH 且网络可达，可在源码机器执行：

```bash
scp "/tmp/kernel-$KVER.tar.gz" debian@虚拟机IP:/home/debian/
```

`虚拟机IP` 须替换为实际地址；初始镜像没有安装 SSH 服务，不能直接假定 SCP 可用。

### 14.3 虚拟机内部：安装更新包

从此处开始，命令均在 **VMware 内的 Debian** 执行，不能在源码宿主机上执行。将 `KVER` 改成第 14.1 节实际输出的版本：

```bash
sudo -i
bash --noprofile --norc
set -euo pipefail

KVER=5.4.18-lab2
PACKAGE="/home/debian/kernel-$KVER.tar.gz"
test -f "$PACKAGE"

# 任一检查失败则停止，避免覆盖已安装版本
test ! -e "/boot/vmlinuz-$KVER"
test ! -e "/lib/modules/$KVER"

tar --no-same-owner -xzf "$PACKAGE" -C /
test -s "/boot/vmlinuz-$KVER"
test -d "/lib/modules/$KVER"
depmod -a "$KVER"

mkdir -p /etc/initramfs-tools/conf.d
printf 'MODULES=most\nCOMPRESS=gzip\n' \
  > /etc/initramfs-tools/conf.d/custom-kernel
update-initramfs -c -k "$KVER"

ls -lh "/boot/vmlinuz-$KVER" "/boot/initrd.img-$KVER"
ls "/lib/modules/$KVER"
```

- `sudo -i`：使用普通用户密码进入 root Shell。
- 两条不存在检查：防止旧文件被覆盖；若失败，检查是否之前已安装，不要盲目删除旧版本。
- `tar -C /`：把自己制作的可信更新包解压到来宾系统根目录。
- `depmod`：建立新版本模块依赖索引。
- `update-initramfs -c`：首次生成该版本的启动镜像；保留 gzip 兼容性。

若更新了文件后需要重新生成同版本 initramfs，用 `update-initramfs -u -k "$KVER"`。新配置必须继续支持实际的磁盘控制器、ext4、initramfs 及网卡。

### 14.4 虚拟机内部：追加 GRUB 菜单项

本镜像使用手写 `/boot/grub/grub.cfg`。先备份再追加，不执行 `grub-install` 或 `update-grub`；后者可能覆盖手写配置。

```bash
GRUBCFG=/boot/grub/grub.cfg
test -s "$GRUBCFG"
cp -a "$GRUBCFG" "$GRUBCFG.bak.$(date +%Y%m%d-%H%M%S)"

ROOT_UUID=$(findmnt -n -o UUID --target /)
test -n "$ROOT_UUID"

# 已存在同名条目则停止，避免重复添加
if grep -Fq "menuentry 'Debian - Linux $KVER'" "$GRUBCFG"; then
    echo "该版本的启动项已经存在，请先检查 grub.cfg"
    exit 1
fi

cat >> "$GRUBCFG" <<EOF

menuentry 'Debian - Linux $KVER' {
    insmod part_msdos
    insmod ext2
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    linux /boot/vmlinuz-$KVER root=UUID=$ROOT_UUID ro console=tty0 console=ttyS0,115200n8
    initrd /boot/initrd.img-$KVER
}
EOF

sed -i 's/^set timeout=.*/set timeout=10/' "$GRUBCFG"
grub-script-check "$GRUBCFG"
cat "$GRUBCFG"
```

- `findmnt`：读取正在运行的来宾根分区 UUID，不使用源码机器的分区信息。
- `cat >>`：保留旧菜单项，追加新内核及其 initramfs 路径。
- `timeout=10`：留出十秒钟手动选择内核。
- `grub-script-check`：检查配置语法，不能替代实际启动测试。检查失败时先恢复备份，不要直接重启。

### 14.5 首次启动与回退

```bash
sync
reboot
```

在 VMware 控制台的 GRUB 菜单选择 `Debian - Linux 5.4.18-lab2`，不要只等待默认旧内核启动。登录后执行：

```bash
uname -r             # 应显示新版本，例如 5.4.18-lab2
nproc                # 检查可用 CPU 数量
findmnt /            # 检查根分区
ip -br address       # 检查网络地址
systemctl --failed   # 检查失败服务
```

若新内核 panic 或无法挂载根分区，重启虚拟机，在 GRUB 中选择原来的 `Debian 12 - Linux 5.4.18+`。不要删除原版本的 `/boot` 文件和 `/lib/modules/5.4.18+/`。

### 14.6 验证后将新内核设为默认（可选）

在虚拟机中执行，菜单标题必须与第 14.4 节一致：

```bash
sudo cp -a /boot/grub/grub.cfg /boot/grub/grub.cfg.before-default-change
sudo sed -i \
  's/^set default=.*/set default="Debian - Linux 5.4.18-lab2"/' \
  /boot/grub/grub.cfg
sudo grub-script-check /boot/grub/grub.cfg
```

作用：只更改默认选择，不更换 GRUB，也不删除旧启动项。下次重启自动进入新内核，仍可手动选择旧内核回退。

## 15. 自动编译与 VMware 打包脚本

仓库提供 [`scripts/build-vmware-image.sh`](../scripts/build-vmware-image.sh)。本节的新脚本生成 **root / 1、ruci / 1** 账号，取代前文手动方案中的 debian 用户；ruci 可使用 sudo。密码仅设置在新镜像的 chroot 中，不修改宿主机账号。弱密码只适合隔离实验环境，进入其他网络前应修改。

脚本不会修改 C 源码，会在编译阶段关闭 `.config` 中的 NFP，按指定参数更新版本后缀。它沿用第 3 节的 GCC 12 兼容参数；检测到非空 thunk 配置会停止，要求重新评估 objtool 规避。

### 15.1 准备依赖

已有能够完成内核编译的工具链和 `.config`。另在宿主机安装镜像制作依赖：

```bash
sudo apt-get update
sudo apt-get install -y debootstrap qemu-utils parted e2fsprogs \
  grub-pc-bin grub2-common python3 util-linux udev kmod
```

脚本不会自动执行宿主机的软件安装。打包需要 root、loop 设备和 mount namespace 权限。

### 15.2 分步执行

```bash
cd /root/gits/linux-5.4.18

# 第一步：仅编译内核和模块，4 个并行任务
bash scripts/build-vmware-image.sh build --jobs 4

# 第二步：使用已编译产物，生成新的 VMware 镜像和 ZIP
sudo bash scripts/build-vmware-image.sh pack
```

`pack` 不重新编译，要求 `bzImage`、模块和配置来自同一完整成功的构建。编译后若修改源码或配置，应先重新执行 `build`。脚本执行 `modules_install`，不是将模块装进宿主机。

默认输出 `/root/gits/vmware-linux-5.4.18-auto/`，不会覆盖此前的 `/root/gits/vmware-linux-5.4.18/`。已有镜像、VMX 或 rootfs 时拒绝覆盖。若中途中断，检查日志和挂载状态，下一次选择新的 `--output` 目录。

### 15.3 一次完成

```bash
sudo bash scripts/build-vmware-image.sh all \
  --jobs 4 \
  --output /root/gits/vmware-linux-5.4.18-ruci
```

作用：先编译，再从镜像站下载新的 Debian 12 rootfs，安装内核和模块，设置账号、DHCP、initramfs、BIOS GRUB 和 PCIe 根端口，最后卸载、转换 VMDK 并生成 ZIP。需要网络和足够磁盘空间。整个操作在私有挂载命名空间中执行，退出时尝试清理本次挂载及 loop 映射。

### 15.4 自定义参数

```bash
sudo bash scripts/build-vmware-image.sh all \
  --jobs 4 \
  --localversion -lab3 \
  --disk-size 30G \
  --mirror https://mirrors.aliyun.com/debian \
  --output /root/gits/vmware-linux-lab3

bash scripts/build-vmware-image.sh --help
```

| 参数 | 作用 |
| --- | --- |
| `build` | 仅编译内核和模块 |
| `pack` | 打包完整 VMware 系统；不是第 14 节的内核更新 tar 包 |
| `all` | 顺序执行编译和 VMware 打包 |
| `--jobs` | 编译并行数，默认 4 |
| `--localversion` | 编译版本后缀，仅 build/all 支持；未指定时沿用现有配置 |
| `--output` | 输出目录，建议为每次镜像制作选择新目录 |
| `--disk-size` | 虚拟磁盘容量，默认 20G |
| `--mirror` | Debian bookworm 主仓库镜像；安全更新使用 Debian 安全仓库 |

输出 ZIP 位于 `输出目录/vmware-linux-5.4.18.zip`，只包含 VMX、VMDK、LOGIN.txt、README.md 和 SHA256SUMS。中间 RAW、日志及空 rootfs 目录保留在输出目录，便于诊断。即使版本带后缀，交付文件名也保持固定，实际内核版本写入 README 和 GRUB。

### 15.5 使用与验证

下载 ZIP 到 Windows、完整解压，然后用 VMware 打开 VMX。默认 2 vCPU、2 GiB 内存、NAT，可在关机后修改。控制台登录：

```text
root，密码 1
ruci，密码 1
```

ruci 登录后执行 `sudo -i`，输入密码 1 可切换 root。自动脚本现已安装 `openssh-server`，启用 `ssh.service`，允许 root 和 ruci 使用密码 1 登录。SSH 主机密钥在首次启动时生成，避免独立复制的新镜像共用制作时的密钥。

在虚拟机控制台执行 `ip -br address` 获取 IP，然后在 Windows PowerShell 连接：

```powershell
ssh root@虚拟机IP
# 或者
ssh ruci@虚拟机IP
```

脚本中的 SSH 配置位于 `/etc/ssh/sshd_config.d/00-vmware-lab.conf`：`PermitRootLogin yes`、`PasswordAuthentication yes`。打包时运行 `sshd -t` 检查配置，启动时由依赖服务生成主机密钥，再启动 SSH。root/1 是弱凭据，只用于隔离实验网络。

本次脚本更新只影响之后 `pack` / `all` 生成的镜像，不会自动修改已经下载或正在运行的虚拟机。此前手动制作的镜像仍按第 12 节描述，未预装 SSH。

脚本检查构建退出码、GRUB 语法和 ZIP 完整性，但不会自动进行虚拟机启动测试。每次产物须按第 12 节验证：`uname -r`、双核启动、磁盘挂载、DHCP 和正常关机。失败时查看输出目录的 `kernel-build.log` 或 `image-build.log`。


### 15.6 已运行虚拟机增量补装 SSH

无需重新编译内核或打包。在 **虚拟机内** 执行以下命令（不在源码宿主机执行）：

```bash
sudo -i
apt-get update
apt-get install -y openssh-server

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-vmware-lab.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
EOF

# 按实验环境要求启用 root 并设置密码
printf 'root:1\n' | chpasswd
ssh-keygen -A
mkdir -p /run/sshd
/usr/sbin/sshd -t && systemctl enable --now ssh && systemctl restart ssh

/usr/sbin/sshd -T | grep -E '^(permitrootlogin|passwordauthentication) '
systemctl --no-pager status ssh
ip -br address
```

作用：安装服务、允许 root 密码认证、设置 root 密码、生成缺少的主机密钥、验证并启动服务。此增量步骤不会创建 ruci 用户；旧镜像若只有 debian 用户仍可继续使用它。检查输出应包含 `permitrootlogin yes` 和 `passwordauthentication yes`，若有其他 SSH 配置冲突须先处理。客户端使用 `ssh root@虚拟机IP`，密码为 1。


### 15.7 Cockpit Web 管理与网卡配置

自动打包脚本现安装 `cockpit`、`cockpit-system`、`cockpit-networkmanager`、`network-manager` 和 `policykit-1`，开机启用 `cockpit.socket`、`NetworkManager.service`。Cockpit 使用 socket 激活：开机监听 9090，浏览器访问时启动 Web 服务，空闲时服务可退出，不必要求 `cockpit.service` 一直 running。

**网络管理方式变更**：第 7 节手动流程及早期镜像使用 systemd-networkd；新版自动脚本改用 NetworkManager，禁用并屏蔽 networkd 服务及其 socket，删除旧的 `20-vmware.network`。避免两个服务同时管理网卡。DNS 继续使用 systemd-resolved。新镜像不绑定固定 MAC 或接口名，NetworkManager 为新发现的以太网卡自动建立 DHCP 连接，后续可在 Cockpit 中修改为静态地址。

启动虚拟机后，在控制台检查：

```bash
ip -br address
nmcli device status
nmcli connection show
systemctl is-enabled cockpit.socket NetworkManager.service
systemctl status cockpit.socket --no-pager
```

在 Windows 浏览器打开 `https://虚拟机IP:9090`，确认访问的是自己的虚拟机；首次使用的自签名证书会出现浏览器提示。使用 **ruci / 1** 登录，点击“管理访问权限 / Administrative access”并按提示认证，即可管理系统服务、日志、终端，以及网卡 IP、DHCP、DNS、路由、桥接、Bond、VLAN 等。是否能应用某种网络类型还取决于内核驱动、虚拟硬件和外部网络配置。

root 的控制台和 SSH 登录保持启用；Cockpit Web 的 root 登录遵循 Debian 软件包默认限制，不等同于 SSH 的 `PermitRootLogin`。使用有 sudo 权限的 ruci 即可管理系统，不需要开放额外的全局 polkit 免认证规则。

Cockpit 只能管理来宾可见的网卡配置。CPU、内存、添加虚拟网卡、切换 VMware NAT/桥接/仅主机模式仍在 VMware 中操作。远程修改当前连接的 IP/路由可能断开 SSH 或浏览器连接，建议先打开 VMware 控制台。

脚本默认不部署防火墙；如以后启用防火墙，需要允许管理来源访问 TCP 9090。root/ruci 的实验密码均为 1，不应将该管理界面直接暴露到公网。

这项变更作用于以后执行 `pack` / `all` 生成的新镜像，不自动迁移已运行虚拟机的网络配置。可按以下命令生成新镜像，不重新编译内核：

```bash
sudo bash scripts/build-vmware-image.sh pack \
  --output /root/gits/vmware-linux-5.4.18-cockpit
```

参考：[Cockpit 的 NetworkManager 集成](https://docs.cockpit-project.org/cockpit-guide/latest/guide/feature-networkmanager.html)、[Cockpit 的 socket 启动方式](https://docs.cockpit-project.org/cockpit-guide/latest/guide/startup.html)。
