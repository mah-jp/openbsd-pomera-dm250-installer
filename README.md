# Pomera DM250 OpenBSD Automated Installer

[日本語](README.ja.md) | [English](README.md)

A complete automated installer and provisioning toolkit to run **OpenBSD 7.9 (armv7)** on the **King Jim Pomera DM250**.

Turn your dedicated Japanese digital typewriter into a portable UNIX terminal with **Wi-Fi, Bluetooth PAN tethering, USB Ethernet/Mouse support, instant lid-close power saving / ultra-fast wakeup, and seamless CUI ↔ GUI (X11) switching**.

---

## 🌟 Key Features

| Feature | Details |
| :--- | :--- |
| **⚡ Instant Sleep & Wakeup** | Custom daemon (`pomera-lid-watch`) monitors lid sensor: 0ms backlight cutoff & CPU throttling on close, instant full-power restore on open. |
| **🌐 Complete Connectivity** | Built-in Wi-Fi (`bwfm0`, multi-SSID auto-fallback), Bluetooth PAN tethering (`pomera-bt-pan`), and Plug & Play USB-Ethernet (`ure0`, `axe0`, `axen0`, `urndis0`, `cdce0`). |
| **🔒 Full-Disk Encryption (FDE)** | OpenBSD `softraid CRYPTO` support on internal eMMC. Protects sensitive notes and SSH keys in case of loss or theft. |
| **💻 CUI & GUI Dual Mode** | High-performance CUI (Console / VT100 / tmux) by default. Switch to lightweight X11 GUI (`xenodm` + `cwm` + `mlterm`) anytime via `pomera-gui-toggle`. |
| **🖱️ USB Peripherals** | Plug & Play support for standard USB mice, keyboards, and USB Ethernet dongles via USB Type-C OTG. |
| **🛡️ Safety & Non-Destructive** | Integrated with [pomera-dm250-recovery-tool](https://github.com/mah-jp/pomera-dm250-recovery-tool) for full eMMC factory backup and 100% restore capability. |
| **🤖 Native QEMU Engine Builder** | Drives a temporary OpenBSD QEMU VM to create authentic disklabel/FFS structures. Pre-configurable via `user_config.env` for 100% unattended installation. |

---

## 💻 Supported Host Operating Systems

The installer SD builder (`make_sdcard.sh`) works on:

- 🍏 **macOS** (Apple Silicon M1/M2/M3/M4 & Intel x86_64, macOS Sonoma / Sequoia)
- 🐧 **Linux amd64 / aarch64** (Ubuntu 22.04/24.04, Debian 12, Fedora 39/40, Arch Linux, Raspberry Pi OS)

---

## 🧰 Prerequisites & Hardware

1. **King Jim Pomera DM250 / DM250X / DM250XY / DM250US** (adequately charged)
2. **SD Card** (2 GB to 32 GB standard SD or microSD with adapter)
3. **Host PC** (macOS or Linux)
4. **USB Type-C Cable** & optional USB-A to Type-C adapter / USB-NIC

### Host Dependencies

`make_sdcard.sh` drives a temporary headless OpenBSD QEMU VM to ensure 100% native FFS/disklabel compliance.

#### 🍏 macOS (Homebrew)
```bash
brew install curl coreutils python3 qemu
```

#### 🐧 Ubuntu / Debian (apt)
```bash
sudo apt update
sudo apt install -y curl python3 qemu-system-arm qemu-efi-aarch64
```

#### 🎩 Fedora (dnf) / 🏹 Arch Linux (pacman)
```bash
# Fedora
sudo dnf install -y curl python3 qemu-system-aarch64 edk2-aarch64

# Arch Linux
sudo pacman -S --needed curl python qemu-system-aarch64 edk2-arm
```

*(Note: If you plan to run Phase 3 Ansible post-provisioning from your host, install `ansible` as well).*

---

## 🚀 Quick Start Guide

```
[Phase 0: Safety Net]
  Backup factory eMMC using pomera-dm250-recovery-tool
  ↓
[Phase 1: Pre-Configure & Build Installer SD]
  1. Configure Wi-Fi / passwords in configs/user_config.env
  2. $ sudo ./make_sdcard.sh  (auto-detects SD card interactively)
  ↓
[Phase 2: One-Touch Install on Pomera]
  1. Insert SD -> Turn ON Pomera with [Power Button] (hold 3~4s)
  2. Hands-free auto-boot into installer kernel
  3. Type 'yes' to confirm installation
  (Autoinstall runs, extracts sets, and powers off upon completion)
  ↓
[Phase 3: Optional Ansible Desktop Setup]
  $ cd ansible && ansible-playbook -i inventory.ini pomera_setup.yml
```

---

### Step 0: Create Full Factory Backup (Recommended)

Before flashing, create a complete, bit-for-bit backup of your Pomera's internal eMMC using [pomera-dm250-recovery-tool](https://github.com/mah-jp/pomera-dm250-recovery-tool):

```bash
git clone https://github.com/mah-jp/pomera-dm250-recovery-tool.git
cd pomera-dm250-recovery-tool
./prepare_sdcard.sh /dev/sdX
# Boot Pomera in UMS mode and run backup_emmc.sh
```

---

### Step 1: Create the OpenBSD Installer SD Card

#### ⚙️ 1-A. Pre-Configure User Settings (Recommended)
You can customize Wi-Fi networks, user/root passwords, and disk encryption before writing the SD card:

```bash
cp configs/user_config.env.example configs/user_config.env
# Edit with your preferred editor
nano configs/user_config.env
```

* **Customizable Parameters**:
  * `POMERA_USERNAME` / `POMERA_USER_PASSWORD` : Account username & password (Default: `pomera` / `pomera`)
  * `POMERA_ROOT_PASSWORD` : Root administrator password (Default: `pomera`)
  * `POMERA_WIFI_NETWORKS` : List of Wi-Fi SSIDs & passwords (automatically connects to the best available network)
  * `POMERA_ENABLE_SSHD` / `POMERA_ALLOW_ROOT_SSH` : SSH daemon enable & root login permission
  * `POMERA_CONFIRM_INSTALL` : Pre-install confirmation prompt before erasing internal storage (Default: `yes`. Set to `no` for unattended zero-touch installation)

> ⚠️ **Disk Encryption Note**: The OpenBSD 32-bit ARM (`armv7`) EFI bootloader (`BOOTARM.EFI`) does not support booting from a `softraid CRYPTO` root volume by architectural specification. Therefore, root disk encryption is permanently disabled (`no`) in this installer to guarantee reliable hardware boot.

#### 💾 1-B. Build and Flash the SD Card
Run `make_sdcard.sh` on your host PC. It automatically downloads OpenBSD 7.9 official binaries, the custom DM250 kernel, U-Boot, and firmware, then launches a temporary headless OpenBSD QEMU VM to write authentic disklabel and FFS filesystems:

```bash
# Running without arguments automatically detects external SD cards and prompts for selection:
sudo ./make_sdcard.sh

# Or specify the target device directly:
# Linux:
sudo ./make_sdcard.sh /dev/sdb
# macOS:
sudo ./make_sdcard.sh /dev/rdisk4

# Download and cache files only (no formatting):
./make_sdcard.sh --download-only
```

*(For US model `DM250US`, append `--us` flag).*  
*(Safety Guard: Internal host storage drives [e.g., `disk0` on macOS or root `/` on Linux] are automatically protected from accidental selection).*

---

### Step 2: Boot Installer & Install OpenBSD on Pomera DM250

> [!IMPORTANT]
> **🛡️ 100% Non-Destructive Zero-Risk SD Boot**  
> The installer SD card contains authentic Rockchip RK3128 raw bootloader sectors (`idbloader.img` / `uboot.img`).  
> The hardware BootROM directly boots from the SD card on power-on **WITHOUT writing a single byte to internal eMMC**. Your factory OS and data remain completely untouched until you explicitly type `yes` at the confirmation prompt (ejecting the SD card boots normal factory Pomera OS).

1. Power OFF Pomera DM250 completely and insert the prepared SD card.
2. Turn ON Pomera by pressing the **[Power Button]** (hold 3-4 seconds).  
   *(The device boots directly from the SD card, automatically loading the installer kernel: `[Pomera DM250] Booting OpenBSD Installer (SD Card)...`).*
3. A safety confirmation prompt will appear on the console:
   ```text
   ==========================================================
     WARNING: ALL DATA ON INTERNAL STORAGE (eMMC)
     WILL BE COMPLETELY ERASED!
     OpenBSD 7.9 will be installed onto internal storage.
   ==========================================================
   Start installation? (yes/N): 
   ```
   Type **`yes`** and press **`[Enter]`** to begin installation on internal eMMC.  
   *(Pressing `N` or Enter aborts immediately and drops into a maintenance menu. Internal storage is NOT modified).*
4. The installer runs automatically:
   - Partitions internal eMMC (`sd1`)
   - Installs OpenBSD base sets and X11
   - Executes `site79.tgz` hook to install the custom DM250 kernel (`/bsd`), disable `reorder_kernel`, configure Multi-SSID Wi-Fi / USB-NIC DHCP, and enable lid power management.
5. When `🎉 ALL OPERATIONS COMPLETED SUCCESSFULLY!` appears on screen:
   **Eject the SD card** and press **`[Enter]`** to power off.
6. Turn ON Pomera to start OpenBSD from internal storage (`[Pomera DM250] Starting OpenBSD from Internal Storage...`)!

> [!TIP]
> **💡 Booting from SD card when a custom OS (OpenBSD, etc.) is already installed**
> 
> If a custom OS is already installed on internal eMMC and you want to boot the SD card installer, the system might immediately boot into the installed OS.  
> In that case, press **any key** right after powering on to interrupt autoboot and drop into the U-Boot prompt (`=> `), then execute the following two commands to boot from the SD card:
> 
> ```text
> => load mmc 1:1 0x62000000 efi/boot/bootarm.efi
> => bootefi 0x62000000
> ```

---

### Step 3: Desktop & Development Setup (Optional)

> [!NOTE]
> Following the automated install in Step 2, essential hardware features (**JIS Keyboard, Wi-Fi auto-connect, USB Ethernet, and lid-close power management**) are fully operational out of the box.  
> Step 3 is an optional post-setup step if you want to deploy Japanese fonts, an X11 lightweight desktop (`cwm` + `mlterm`), editor (`vim`), and tmux optimizations directly on the device without needing an external PC.

After booting into OpenBSD, connect to network (Wi-Fi or USB-NIC) and run:

```bash
pomera-setup-desktop
```

This automatically configures:
- Essential tools (`vim`, `tmux`, `curl`, `git`)
- Japanese fonts (Noto Sans CJK) & terminal (`mlterm`)
- Ultra-lightweight window manager (`cwm`) & launcher (`dmenu`)
- 1024x600 display optimized dotfiles (`~/.tmux.conf`, `~/.cwmrc`, `~/.profile`, `~/.xsession`)

---

## 🛠️ On-Device Utilities

| Command | Description |
| :--- | :--- |
| `pomera-setup-desktop` | Automatically set up Japanese fonts, GUI (`cwm`/`mlterm`), Vim, tmux, and dotfiles. |
| `doas pomera-gui-toggle [gui\|cui\|toggle]` | Switch between CUI console and X11 GUI mode (`xenodm`/`cwm`). |
| `doas pomera-bt-pan connect <BD_ADDR>` | Connect to smartphone Bluetooth Tethering (PAN). |
| `doas gpioctl gpio1 red_led 1` / `green_led 1` | Control front status LEDs. |
| `wsconsctl display.brightness=0..100` | Adjust screen brightness manually. |

---

## 🤝 Acknowledgements & Credits

- **Joshua Stein (jcs)**: [OpenBSD on Pomera DM250](https://jcs.org/2026/04/09/openbsd-dm250) kernel, U-Boot, and display patches.
- **4noha**: [openbsd-pomera-dm250](https://github.com/4noha/openbsd-pomera-dm250) toolchain and battery/lid scripts.
- **mah-jp**: [pomera-dm250-recovery-tool](https://github.com/mah-jp/pomera-dm250-recovery-tool) for U-Boot UMS backup/recovery.

---

## 📄 License

[MIT License](LICENSE)
