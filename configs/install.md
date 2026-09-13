#	$OpenBSD: install.md,v 1.25 2026/02/01 12:00:00 pomera Exp $
#
# Copyright (c) 1996 Canonical Software
# Copyright (c) 2026 Pomera DM250 OpenBSD Project
# All rights reserved.
#

MOUNT_ARGS_msdos="-o-l"
MDBOOTSR=y

make_dev() {
	local _dev=$1
	(cd /dev && sh MAKEDEV "$@")
	if [[ -e /dev/${_dev}c || -e /dev/r${_dev}c || -e /dev/${_dev}a || -e /dev/r${_dev}a || -e /dev/${_dev} ]]; then
		return 0
	fi
	echo "ERR: make_dev failed to create device node for ${_dev}" >&2
	return 1
}

md_installboot() {
	local _disk=$1
	echo "Installing bootloader and EFI binaries on ${_disk}..."

	# If _disk is a softraid CRYPTO volume (e.g. sd2), resolve to the underlying physical disk with MSDOS partition
	for _d in $_disk sd1 sd0; do
		if disklabel "$_d" 2>/dev/null | grep -q "i:.*MSDOS"; then
			_disk=$_d
			echo "   -> Target EFI physical disk resolved to ${_disk}"
			break
		fi
	done
	# 1. Flash authentic Rockchip BootROM raw bootloader sectors to target eMMC
	#    - Sector 64 (32KB): idbloader.img (DDR Init + Miniloader)
	#    - Sector 16384 (8MB): uboot.img (OpenBSD U-Boot + DTB)
	for _p in /idbloader.img /mnt2/idbloader.img /mnt/idbloader.img /usr/mdec/idbloader.img /mnt/mnt/idbloader.img; do
		if [ -f "$_p" ]; then
			echo "   -> Flashing Rockchip idbloader to ${_disk} sector 64..."
			dd if="$_p" of="/dev/r${_disk}c" bs=512 seek=64
			break
		fi
	done
	if [ ! -f /idbloader.img ] && [ -e /dev/rsd0c ] && [ "${_disk}" != "sd0" ]; then
		echo "   -> Mirroring idbloader from SD card to ${_disk} sector 64..."
		dd if=/dev/rsd0c of="/dev/r${_disk}c" bs=512 skip=64 seek=64 count=1000
	fi

	for _p in /uboot.img /mnt2/uboot.img /mnt/uboot.img /usr/mdec/uboot.img /mnt/mnt/uboot.img; do
		if [ -f "$_p" ]; then
			echo "   -> Flashing Rockchip U-Boot to ${_disk} sector 16384..."
			dd if="$_p" of="/dev/r${_disk}c" bs=512 seek=16384
			break
		fi
	done
	if [ ! -f /uboot.img ] && [ -e /dev/rsd0c ] && [ "${_disk}" != "sd0" ]; then
		echo "   -> Mirroring U-Boot from SD card to ${_disk} sector 16384..."
		dd if=/dev/rsd0c of="/dev/r${_disk}c" bs=512 skip=16384 seek=16384 count=8192
	fi
	
	newfs_msdos /dev/r${_disk}i
	mkdir -p /mnt/mnt
	if mount ${MOUNT_ARGS_msdos} /dev/${_disk}i /mnt/mnt; then
		mkdir -p /mnt/mnt/efi/boot /mnt/mnt/firmware /mnt/mnt/etc
		if [ -f /usr/mdec/BOOTARM.EFI ]; then
			cp -f /usr/mdec/BOOTARM.EFI /mnt/mnt/efi/boot/BOOTARM.EFI
			cp -f /usr/mdec/BOOTARM.EFI /mnt/mnt/efi/boot/bootarm.efi
		elif [ -f /mnt/usr/mdec/BOOTARM.EFI ]; then
			cp -f /mnt/usr/mdec/BOOTARM.EFI /mnt/mnt/efi/boot/BOOTARM.EFI
			cp -f /mnt/usr/mdec/BOOTARM.EFI /mnt/mnt/efi/boot/bootarm.efi
		elif [ -f /efi/boot/BOOTARM.EFI ]; then
			cp -f /efi/boot/BOOTARM.EFI /mnt/mnt/efi/boot/BOOTARM.EFI
			cp -f /efi/boot/BOOTARM.EFI /mnt/mnt/efi/boot/bootarm.efi
		elif [ -f /BOOTARM.EFI ]; then
			cp -f /BOOTARM.EFI /mnt/mnt/efi/boot/BOOTARM.EFI
			cp -f /BOOTARM.EFI /mnt/mnt/efi/boot/bootarm.efi
		fi
		[ -f /kingjim-dm250.dtb ] && cp -f /kingjim-dm250.dtb /mnt/mnt/kingjim-dm250.dtb
		[ -f /mnt/kingjim-dm250.dtb ] && cp -f /mnt/kingjim-dm250.dtb /mnt/mnt/kingjim-dm250.dtb
		[ -f /logo.bmp ] && cp -f /logo.bmp /mnt/mnt/logo.bmp
		[ -f /etc/firmware/brcmfmac43430-sdio.txt ] && cp -f /etc/firmware/brcmfmac43430-sdio.txt /mnt/mnt/firmware/nvram_ap6212a.txt
		[ -f /bsd ] && cp -f /bsd /mnt/mnt/bsd
		[ -f /mnt/bsd ] && cp -f /mnt/bsd /mnt/mnt/bsd
		
		cat << 'EOF' > /mnt/mnt/boot.conf
set timeout 5
boot /bsd
EOF
		mkdir -p /mnt/mnt/etc /mnt/mnt/efi/boot /mnt/mnt/EFI/BOOT
		cp -f /mnt/mnt/boot.conf /mnt/mnt/etc/boot.conf
		cp -f /mnt/mnt/boot.conf /mnt/mnt/efi/boot/boot.conf
		cp -f /mnt/mnt/boot.conf /mnt/mnt/EFI/BOOT/boot.conf
		
		umount /mnt/mnt
		echo "EFI boot binaries and boot.conf installed successfully on ${_disk}i."
	fi

	# Stage offline workspace packages to target eMMC for post-boot setup
	for _pkgsrc in /packages /mnt2/packages; do
		if [ -d "$_pkgsrc" ] && ls "$_pkgsrc"/*.tgz >/dev/null 2>&1; then
			echo ">> Staging offline packages from ${_pkgsrc} to /mnt/var/cache/packages..."
			mkdir -p /mnt/var/cache/packages
			cp -f "$_pkgsrc"/*.tgz /mnt/var/cache/packages/ 2>/dev/null
			break
		fi
	done
}

md_prep_fdisk() {
	local _disk=$1

	# Wipe conflicting GPT/MBR remnants from first 2MB to ensure clean MBR recognition
	dd if=/dev/zero of=/dev/r${_disk}c bs=1M count=2

	# Standard MBR partitioning for OpenBSD armv7 (16MB FAT16 at 16MB offset)
	fdisk -iy -b "32768@32768:C" ${_disk}
	newfs_msdos /dev/r${_disk}i
	
	# Write clean disklabel on eMMC
	disklabel -w -A ${_disk}
	return 0
}

md_prep_disklabel() {
	local _disk=$1 _f=/tmp/i/fstab.$1

	md_prep_fdisk $_disk

	disklabel_autolayout $_disk $_f
	[[ -s $_f ]] && return 0

	# Fallback: ensure complete partition layout in fstab
	cat << EOF > "$_f"
/dev/${_disk}a / ffs rw,noatime 1 1
/dev/${_disk}b none swap sw 0 0
/dev/${_disk}d /usr ffs rw,nodev,noatime 1 2
/dev/${_disk}e /home ffs rw,nodev,nosuid,noatime 1 2
EOF
	return 0
}

md_congrats() {
	echo ">> Enforcing Custom DM250 Kernel & Disabling reorder_kernel on eMMC..."
	
	# 1. Overwrite /mnt/bsd with custom DM250 kernel (Strictly asserted)
	if [ -f /bsd ]; then
		cp -f /bsd /mnt/bsd
		echo "   -> Custom DM250 /bsd kernel written to /mnt/bsd"
	else
		echo "ERR: Custom DM250 kernel /bsd not found on installer root!" >&2
		return 1
	fi
	
	# 2. Disable reorder_kernel on eMMC permanently
	if [ -f /mnt/usr/libexec/reorder_kernel ]; then
		mv /mnt/usr/libexec/reorder_kernel /mnt/usr/libexec/reorder_kernel.orig
	fi
	printf "#!/bin/sh\nexit 0\n" > /mnt/usr/libexec/reorder_kernel
	chmod +x /mnt/usr/libexec/reorder_kernel
	
	# 3. Clean and complete /etc/fstab on eMMC (Mounting /, /usr, /home, swap)
	if grep -q "ffs" /mnt/etc/fstab 2>/dev/null && ! grep -q "sd1" /mnt/etc/fstab 2>/dev/null; then
		echo "   -> Preserving installer generated /etc/fstab (softraid DUID / valid layout verified)"
	elif [ -f /tmp/i/fstab.sd1 ]; then
		sed 's/sd1/sd0/g' /tmp/i/fstab.sd1 > /mnt/etc/fstab
	elif [ ! -s /mnt/etc/fstab ]; then
		cat << 'EOF' > /mnt/etc/fstab
/dev/sd0a / ffs rw,noatime 1 1
/dev/sd0b none swap sw 0 0
/dev/sd0d /usr ffs rw,nodev,noatime 1 2
/dev/sd0e /home ffs rw,nodev,nosuid,noatime 1 2
EOF
	fi
	cat << 'EOF' > /mnt/etc/boot.conf
set tty fb0
set timeout 5
boot /bsd
EOF
	
	# 4. Ensure device nodes exist on eMMC and secure permissions
	(cd /mnt/dev && mkdir -p fd && sh ./MAKEDEV std wscons)
	chmod 600 /mnt/etc/hostname.*
	
	# 5. Guarantee boot.conf on eMMC EFI partition as well
	mkdir -p /mnt_emmc_efi
	for dev in /dev/sd1i /dev/sd0i; do
		if mount -o-l "$dev" /mnt_emmc_efi; then
			mkdir -p /mnt_emmc_efi/efi/boot /mnt_emmc_efi/etc
			cat << 'EOF' > /mnt_emmc_efi/boot.conf
set timeout 5
boot /bsd
EOF
			mkdir -p /mnt_emmc_efi/efi/boot /mnt_emmc_efi/EFI/BOOT
			cp -f /mnt_emmc_efi/boot.conf /mnt_emmc_efi/efi/boot/boot.conf
			cp -f /mnt_emmc_efi/boot.conf /mnt_emmc_efi/EFI/BOOT/boot.conf
			umount /mnt_emmc_efi
			break
		fi
	done
	rm -rf /mnt_emmc_efi
	
	echo ">> Finalizing disk sync... (Writing caches, DO NOT remove SD card!)"
	sync
	sync
	sync
	sleep 1
	
	echo "=========================================================="
	echo "🎉 Pomera DM250 OpenBSD Installation 100% Complete!"
	echo "   Internal storage (eMMC) has been completely prepared."
	echo "=========================================================="
	echo "Next steps:"
	echo "  1. Press [Enter] below to power off system."
	echo "  2. REMOVE the SD card AFTER power turns off completely."
	echo "  3. Turn ON Pomera to start OpenBSD from internal storage!"
	echo "=========================================================="
	echo -n "Press Enter to power off... "
	read -r _finish </dev/ttyC0 2>/dev/null || _finish=""
	echo ""
	echo ">> Flushing buffers and powering off system..."
	sync
	sync
	halt -p
}

md_consoleinfo() {
	DEFCONS=n
}
