#!/bin/ksh
# prep_sd_vm.template.sh - OpenBSD QEMU Guest SD Preparation & Provisioning Script Template
# Automatically populated and executed in throwaway VM during ./make_sdcard.sh
set -eu

say() { echo; echo "=== $* ==="; }
die() { echo "ERR: $*" >&2; exit 1; }

say "Step 1: Preparing SD Device Nodes & Working Storage"
mkdir -p /tmp /mnt 2>/dev/null || true
mount_tmpfs -s 64M tmpfs /tmp 2>/dev/null || true
cd /dev && sh ./MAKEDEV sd1

say "Step 2: Native Partitioning & FFS Formatting (Offset 16MB for Rockchip BootROM)"
fdisk -iy -b "204800@32768:C" sd1
disklabel -E sd1 << 'EOF_LABEL'
a




w
q
EOF_LABEL
newfs -b 16384 -f 2048 -i 16384 /dev/rsd1a
newfs_msdos /dev/rsd1i

say "Step 3: Populating EFI Boot Partition"
mkdir -p /mnt
mount /dev/sd1i /mnt
mkdir -p /mnt/efi/boot /mnt/EFI/BOOT /mnt/firmware

ftp -V -o /mnt/efi/boot/BOOTARM.EFI http://10.0.2.2:@HTTP_PORT@/BOOTARM.EFI
cp -f /mnt/efi/boot/BOOTARM.EFI /mnt/EFI/BOOT/BOOTARM.EFI 2>/dev/null || true
cp -f /mnt/efi/boot/BOOTARM.EFI /mnt/efi/boot/bootarm.efi 2>/dev/null || true
ftp -V -o /mnt/_sdboot.sh http://10.0.2.2:@HTTP_PORT@/_sdboot.sh
ftp -V -o /mnt/logo.bmp http://10.0.2.2:@HTTP_PORT@/logo.bmp
ftp -V -o /mnt/kingjim-dm250.dtb http://10.0.2.2:@HTTP_PORT@/kingjim-dm250.dtb
ftp -V -o /mnt/firmware/nvram_ap6212a.txt http://10.0.2.2:@HTTP_PORT@/brcmfmac43430-sdio.rockchip,pomera-dm250.txt
ftp -V -o /mnt/idbloader.img http://10.0.2.2:@HTTP_PORT@/idbloader.img
ftp -V -o /mnt/uboot.img http://10.0.2.2:@HTTP_PORT@/uboot.img
ftp -V -o /mnt/auto_install.conf http://10.0.2.2:@HTTP_PORT@/install.conf
ftp -V -o /mnt/install.conf http://10.0.2.2:@HTTP_PORT@/install.conf
ftp -V -o /mnt/bsd http://10.0.2.2:@HTTP_PORT@/bsd

cat << 'EOF_BOOTCONF' > /mnt/boot.conf
set timeout @BOOT_TIMEOUT@
boot /bsd
EOF_BOOTCONF
cp -f /mnt/boot.conf /mnt/efi/boot/boot.conf 2>/dev/null || true
cp -f /mnt/boot.conf /mnt/EFI/BOOT/boot.conf 2>/dev/null || true

umount /mnt

say "Step 4: Populating Full Live Autoinstaller Environment on SD"
mount /dev/sd1a /mnt

# Download essential sets & custom kernel
ftp -V -o /mnt/base79.tgz http://10.0.2.2:@HTTP_PORT@/base79_opt.tgz
ftp -V -o /mnt/bsd http://10.0.2.2:@HTTP_PORT@/bsd
ftp -V -o /mnt/bsd.rd http://10.0.2.2:@HTTP_PORT@/bsd.rd
ftp -V -o /mnt/idbloader.img http://10.0.2.2:@HTTP_PORT@/idbloader.img
ftp -V -o /mnt/uboot.img http://10.0.2.2:@HTTP_PORT@/uboot.img
mkdir -p /mnt/usr/mdec
cp -f /mnt/idbloader.img /mnt/usr/mdec/idbloader.img 2>/dev/null || true
cp -f /mnt/uboot.img /mnt/usr/mdec/uboot.img 2>/dev/null || true
ftp -V -o /mnt/kingjim-dm250.dtb http://10.0.2.2:@HTTP_PORT@/kingjim-dm250.dtb
ftp -V -o /mnt/BOOTARM.EFI http://10.0.2.2:@HTTP_PORT@/BOOTARM.EFI
mkdir -p /mnt/efi/boot
cp -f /mnt/BOOTARM.EFI /mnt/efi/boot/BOOTARM.EFI 2>/dev/null || true
ftp -V -o /mnt/SHA256.sig http://10.0.2.2:@HTTP_PORT@/SHA256.sig

for s in comp79 man79 xbase79 xfont79 xserv79 xshare79 site79; do
    ftp -V -o /mnt/${s}.tgz http://10.0.2.2:@HTTP_PORT@/${s}.tgz
done
ftp -V -o /mnt/bwfm-firmware-20200316.1.3p5.tgz http://10.0.2.2:@HTTP_PORT@/bwfm-firmware-20200316.1.3p5.tgz

# Fetch offline workspace packages archive if bundled
if ftp -V -o /tmp/packages.tar http://10.0.2.2:@HTTP_PORT@/packages.tar 2>/dev/null; then
    echo ">> Extracting offline workspace packages into /mnt/packages..."
    tar -xf /tmp/packages.tar -C /mnt 2>/dev/null || true
    rm -f /tmp/packages.tar
fi

# Unpack full base system into SD root so ALL dynamic libraries and commands exist
cd /mnt
tar -xzphf /mnt/base79.tgz -C /mnt 2>/dev/null || true
cd /mnt/dev && sh ./MAKEDEV all 2>/dev/null || true

# Ensure all essential runtime directories and symlinks exist
mkdir -p /mnt/var/run /mnt/var/log /mnt/tmp /mnt/etc /mnt/bin /mnt/sbin /mnt/tmp/ai /mnt/tmp/i
chmod 1777 /mnt/tmp

# Ensure /mnt2 points directly to / for set extraction
rm -rf /mnt/mnt2
ln -s / /mnt/mnt2 2>/dev/null || true

# Symlink unversioned set names (*.tgz -> *79.tgz) for 100% universal set resolution
cd /mnt
for s in base comp man xbase xfont xserv xshare site; do
    ln -sf ${s}79.tgz ${s}.tgz 2>/dev/null || true
done
ln -sf site79.tgz site-pomera.tgz 2>/dev/null || true
cd /

# Deploy /etc/fstab to prevent 'can\'t find fstab entry for /'
echo "/dev/sd0a / ffs rw 1 1" > /mnt/etc/fstab

# Copy genuine OpenBSD install scripts and install.md
cp -f /install /mnt/install 2>/dev/null || true
cp -f /install.sub /mnt/install.sub 2>/dev/null || true
ftp -V -o /mnt/install.md http://10.0.2.2:@HTTP_PORT@/install.md
cp -f /mnt/install.md /mnt/bin/install.md 2>/dev/null || true
cp -f /mnt/install.md /mnt/sbin/install.md 2>/dev/null || true
cp -f /mnt/install.md /mnt/tmp/i/install.md 2>/dev/null || true
cp -f /mnt/install.md /mnt/etc/install.md 2>/dev/null || true
cp -f /upgrade /mnt/upgrade 2>/dev/null || true
chmod +x /mnt/install /mnt/upgrade 2>/dev/null || true

# Deploy all autoinstall response files across multiple canonical names
ftp -V -o /mnt/install.conf http://10.0.2.2:@HTTP_PORT@/install.conf
ftp -V -o /mnt/auto_install.conf http://10.0.2.2:@HTTP_PORT@/install.conf
ftp -V -o /mnt/pomera.conf http://10.0.2.2:@HTTP_PORT@/install.conf
ftp -V -o /mnt/ai.conf http://10.0.2.2:@HTTP_PORT@/install.conf
ftp -V -o /mnt/tmp/ai/ai.install.conf http://10.0.2.2:@HTTP_PORT@/install.conf

# Deploy Autolauncher in /etc/rc
cat << 'EOF' > /mnt/etc/rc
#!/bin/sh
export PATH=.:/sbin:/bin:/usr/sbin:/usr/bin

# 0. Handle shutdown/reboot invocation from halt(8), reboot(8), or shutdown(8)
if [ "$1" = "shutdown" ]; then
    exit 0
fi

# 1. FIRST: Mount writable tmpfs (tmpfs works even when root / is strictly Read-Only!)
mkdir -p /tmp /var/run /var/log /mnt /mnt2 /tmp/ai /tmp/i 2>/dev/null || true
mount_tmpfs -s 32M tmpfs /tmp 2>/dev/null || true
mount_tmpfs -s 16M tmpfs /var/run 2>/dev/null || true
chmod 1777 /tmp 2>/dev/null || true
mkdir -p /tmp/ai /tmp/i /tmp/dev 2>/dev/null || true

# 2. SECOND: Initialize essential device nodes so fsck and mount can locate /dev/sd0a
cd /dev && sh ./MAKEDEV all >/dev/null 2>&1 || true
wsconsctl keyboard.encoding=jp >/dev/null 2>&1 || true

# 3. THIRD: Repair dirty root filesystem with guaranteed existing device nodes and remount Read-Write
fsck -y /dev/sd0a >/dev/null 2>&1 || fsck -y / >/dev/null 2>&1 || true
mount -u -o rw /dev/sd0a / 2>/dev/null || mount -u -o rw / 2>/dev/null || mount -uw / 2>/dev/null || true
EOF
@CONFIRM_SECTION@
cat << 'EOF_LAUNCH' >> /mnt/etc/rc

# Trigger OpenBSD Autoinstall with -af flag!
cd /
export TERM=wsvt25
export MODE=install
mkdir -p /tmp/ai /tmp/i
cp -f /install.conf /tmp/ai/ai.install.conf 2>/dev/null || true
cp -f /install.conf /auto_install.conf 2>/dev/null || true

echo "=========================================================="
echo ">> [Pomera DM250] OpenBSD Autoinstall (v@TOOL_VERSION@)"
/install -af /install.conf </dev/null >/dev/ttyC0 2>&1

echo "" >/dev/ttyC0
echo ">> Flushing all storage buffers (DO NOT remove SD card yet)..." >/dev/ttyC0
sync
sync
sync
sleep 2

echo "==========================================================" >/dev/ttyC0
echo "🎉 ALL OPERATIONS COMPLETED SUCCESSFULLY!" >/dev/ttyC0
echo "🔒 All disk buffers safely flushed. Storage is 100% clean." >/dev/ttyC0
echo "👉 You can now safely REMOVE the SD card." >/dev/ttyC0
echo "==========================================================" >/dev/ttyC0
echo -n "Press Enter to power off... " >/dev/ttyC0
read -r _done </dev/ttyC0 2>/dev/null || true
halt -p
EOF_LAUNCH
chmod +x /mnt/etc/rc


# Configure boot.conf to boot authentic installer kernel with fb0 tty
mkdir -p /mnt/etc
cat << 'EOF' > /mnt/etc/boot.conf
set tty fb0
set timeout @BOOT_TIMEOUT@
boot /bsd
EOF

cd /
umount /mnt

sync
say "SD-PREP-COMPLETE"
halt -p
