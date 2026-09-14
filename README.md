# Pomera DM250 OpenBSD Automated Installer

[日本語](README.ja.md) | [English](README.md)

An automated installer and setup toolkit to run **OpenBSD 7.9 (armv7)** on the **King Jim Pomera DM250**.

Enables a portable UNIX terminal environment on the DM250 hardware with **built-in Wi-Fi, CJK framebuffer console (mlterm-fb), lid-close power management, and optimized keyboard configuration**.

---

## 🌟 Key Features

| Feature | Details |
| :--- | :--- |
| **⚡ Lid-Close Power Management** | Native `rcctl` daemon (`pomera_lid_watch`) monitors the lid switch: dims backlight and throttles CPU on close, and restores display on open. Polling interval and CPU policy (auto/high) are configurable. |
| **🔋 Battery Management** | Integrated with Rockchip RK818 PMIC for battery charging and hardware power routing. Query voltage, charge/discharge status, and capacity percentage via `sysctl hw.sensors.simplebat0`. |
| **🌐 Connectivity (2.4GHz Wi-Fi)** | Built-in Wi-Fi (`bwfm0`, 2.4GHz, multi-SSID fallback and auto-reconnect daemon). *(Experimental configuration placeholders for Bluetooth PAN and USB-Ethernet drivers are also included).* |
| **💻 CUI Terminal Environment** | Lightweight CUI environment operating directly on the framebuffer without requiring X11. Includes standard (`mlterm-base`) and optimized (`mlterm-opt`) console builds, plus inline Japanese input via `mlterm-ja` (built-in SKK engine). |
| **🖱️ USB Peripherals** | Support for external keyboards and mice via USB Type-C OTG. |
| **🛡️ Factory Restore Support** | Works alongside [pomera-dm250-backup-restore-tool](https://github.com/mah-jp/pomera-dm250-backup-restore-tool) to back up internal eMMC and restore factory firmware if needed. |
| **🛠️ Kernel Patch Audit & Build** | Optional kernel patches for USB Hub stability, X11 key mapping, and mlterm-fb framebuffer console (SMODE). Automatically audits official kernel and skips recompilation if already fixed upstream. |
| **🤖 Image Generation via Native QEMU** | Drives a temporary OpenBSD QEMU VM to create authentic disklabel/FFS structures. Pre-configurable via `user_config.env` for automated installation. |

---

## 💻 Supported Host Operating Systems

The installer SD builder (`make_sdcard.sh`) works on:

- 🍏 **macOS** (Apple Silicon / Intel)
- 🐧 **Linux** (amd64 / aarch64)

---

## 🧰 Prerequisites & Hardware

1. **King Jim Pomera DM250 / DM250X / DM250XY / DM250US** (adequately charged in advance; 50%+ recommended)
2. **SD Card** (2 GB to 32 GB standard SD or microSD with adapter)
3. **Host PC** (macOS or Linux)
4. **USB Type-C Cable** (for power & charging)

> [!WARNING]
> **⚠️ Ensure battery is sufficiently charged beforehand**  
> Due to the DM250 hardware design, a completely drained (0%) battery may lack sufficient power to boot reliably even when a USB cable is connected. Start the installation process (which takes approximately 2-3 minutes) with a healthy battery charge. If using Wi-Fi and the Type-C port is available, keeping a USB charger connected during installation provides extra safety.

### Host Dependencies

`make_sdcard.sh` drives a temporary headless OpenBSD QEMU VM to create native FFS and disklabel structures.

#### 🍏 macOS (Homebrew)
```bash
brew install curl coreutils python3 qemu
```

#### 🐧 Ubuntu / Debian (apt)
```bash
sudo apt update
sudo apt install -y curl python3 qemu-system-arm qemu-efi-aarch64 mtools binutils-arm-linux-gnueabihf
```

#### 🎩 Fedora (dnf) / 🏹 Arch Linux (pacman)
```bash
# Fedora
sudo dnf install -y curl python3 qemu-system-aarch64 edk2-aarch64 mtools binutils-arm-linux-gnu

# Arch Linux
sudo pacman -S --needed curl python qemu-system-aarch64 edk2-arm mtools arm-linux-gnueabihf-binutils
```

---

## 🚀 Quick Start Guide

```
[Phase 0: Backup (Recommended)]
  Backup factory eMMC using pomera-dm250-backup-restore-tool
  ↓
[Phase 1: Configure & Build Installer SD]
  1. Configure Wi-Fi / passwords in configs/user_config.env
  2. $ ./make_sdcard.sh  (auto-detects SD card interactively)
  ↓
[Phase 2: Installation on Pomera]
  1. Insert SD -> Turn ON Pomera with [Power Button] (hold 3~4s)
  2. Boot into installer kernel
  3. Type 'yes' to confirm installation
  (Automated installation runs, stages packages, and powers off upon completion in ~2-3 minutes)
  ↓
[Phase 3: Initial Setup & Japanese IME]
  - Log in and run post-install setup commands:
  - Setup workspace: $ pomera-setup-workspace
  - Optional Japanese IME setup: $ pomera-setup-japanese
```

---

### Step 0: Create Full Factory Backup (Mandatory / Critical for Factory Restore)

> [!CAUTION]
> **🚨 Without a full backup including bootloader sectors, you CANNOT restore the device to its factory state**  
> Flashing OpenBSD will permanently overwrite the internal eMMC partitions and bootloader sectors.  
> **If you do not have a full raw backup of the internal eMMC including its bootloader region, it is impossible to revert your Pomera back to its original factory state.**  
> 
> *Note*: The backup tool provided by ichinomoto ([EKESETE.net](https://www.ekesete.net/log/?p=9504)) does not preserve the internal eMMC bootloader sectors (raw initial LBA sectors). Therefore, **its backup data is incomplete for restoring the device after installing OpenBSD using this installer**.  
> You must create a complete raw sector backup using [pomera-dm250-backup-restore-tool](https://github.com/mah-jp/pomera-dm250-backup-restore-tool) prior to installation.

```bash
git clone https://github.com/mah-jp/pomera-dm250-backup-restore-tool.git
cd pomera-dm250-backup-restore-tool
./prepare_sdcard.sh /dev/sdX
# Boot Pomera in UMS mode and run backup_emmc.sh (backs up entire eMMC including bootloader)
```

---

### Step 1: Create the OpenBSD Installer SD Card

#### ⚙️ 1-A. Pre-Configure User Settings (Recommended)
You can customize Wi-Fi networks, passwords, CPU scaling policy, and boot timeout before writing the SD card:

```bash
cp configs/user_config.env.example configs/user_config.env
# Edit with your preferred editor
nano configs/user_config.env
```

* **Customizable Parameters**:
  * `POMERA_USERNAME` / `POMERA_USER_PASSWORD` : Account username & password (Default: `pomera` / `pomera`)
  * `POMERA_ROOT_PASSWORD` : Root administrator password (Default: `pomera`)
  * `POMERA_WIFI_NETWORKS` : List of Wi-Fi SSIDs & passwords (**2.4GHz band only**; automatically connects to the strongest available network. Note: The onboard AP6212 chip does NOT support 5GHz bands [-A or -5G], only 2.4GHz bands [-G or -2G])
  * `POMERA_BOOT_TIMEOUT` : Bootloader countdown delay in seconds (Default: `5`)
  * `POMERA_LID_INTERVAL` : Lid daemon polling interval in seconds (Default: `2.0`)
  * `POMERA_CPU_POLICY` : CPU performance scaling policy (`auto`: dynamic load-based scaling / `100` or `high`: maximum clock lock, Default: `auto`)
  * `POMERA_ENABLE_SSHD` / `POMERA_ALLOW_ROOT_SSH` : SSH daemon enable & root login permission
  * `POMERA_CONFIRM_INSTALL` : Pre-install confirmation prompt before erasing internal storage (Default: `yes`. Set to `no` to skip the confirmation prompt)
  * `POMERA_SMART_KERNEL` : Optimize kernel by removing unused SoCs and PCI expansion drivers (~25% smaller) (Default: `yes`. Set to `no` for generic kernel)
  * `POMERA_PATCH_USB_HUB` : Fix USB Hub crash & disconnect issues (Default: `yes`)
  * `POMERA_PATCH_X11_KEYS` : Fix Right-Shift and Left-Alt keys under X11 (Default: `yes`)
  * `POMERA_PATCH_MLTERM_FB` : Enable high-performance direct framebuffer console for `mlterm-fb` (Default: `yes`)
  * `POMERA_PATCH_BT` : Enable Bluetooth UART 2s delay patch for AP6212A (Default: `yes`)

> [!TIP]
> **💡 Kernel Audit Feature**  
> When `POMERA_SMART_KERNEL`, `POMERA_PATCH_USB_HUB`, `POMERA_PATCH_X11_KEYS`, `POMERA_PATCH_MLTERM_FB`, or `POMERA_PATCH_BT` is set to `yes`, the installer automatically audits the binary of the official kernel (`jcs.org/dm250/bsd`). If the official kernel already satisfies the requested configuration, it skips recompilation and adopts the official binary directly. Recompilation via temporary QEMU VM runs only when needed (and build results are cached for subsequent runs).

*(Note: Root disk encryption [softraid CRYPTO] boot is permanently disabled as the OpenBSD armv7 EFI bootloader does not support crypto boot by design).*

#### 💾 1-B. Build and Flash the SD Card
Run `make_sdcard.sh` on your host PC. It automatically downloads OpenBSD 7.9 official binaries, the custom DM250 kernel, U-Boot, and firmware, then launches a temporary headless OpenBSD QEMU VM to write authentic disklabel and FFS filesystems:

```bash
# Running without arguments automatically detects external SD cards and prompts for selection:
# (If only 1 card is detected, simply press [Enter] to confirm, or enter the number [1]):
./make_sdcard.sh

# Or specify the target device directly (skips interactive selection):
# Linux:
./make_sdcard.sh /dev/sda
# macOS:
./make_sdcard.sh /dev/rdisk4

# Download and cache files only (no formatting):
./make_sdcard.sh --download-only
```

*(Note: Administrator privileges `sudo` are requested automatically only when writing to the physical SD card. You can also run `sudo ./make_sdcard.sh` upfront if preferred).*  
*(For US model `DM250US`, append `--us` flag).*  
*(Safety Guard: Internal host storage drives [e.g., `disk0` on macOS or root `/` on Linux] are automatically protected from accidental selection).*

---

### Step 2: Boot Installer & Install OpenBSD on Pomera DM250

> [!IMPORTANT]
> **🛡️ Internal Storage Protection during SD Boot**  
> The installer SD card contains authentic Rockchip RK3128 raw bootloader sectors (`idbloader.img` / `uboot.img`).  
> The hardware BootROM boots directly from the SD card on power-on. **No changes are made to the internal storage (eMMC) until you explicitly type `yes` at the confirmation prompt**. Aborting the installation and ejecting the SD card boots the original factory firmware.

> [!WARNING]
> **⚠️ Physical Write-Protect (Lock) Switch on SD Card**  
> The physical switch on the side of the SD card **must be in the UNLOCKED (write-enabled) position**.  
> During the installation process, the OpenBSD installer initializes and mounts internal storage, which requires generating a temporary mount table (`/etc/fstab`) on the root filesystem. If the SD card is locked in read-only mode by hardware, the installation will abort with a `Read-only file system` error.  
> *(※ Once the installation finishes and the system shuts down after pressing [Enter], the SD card can be safely removed).*

1. Power OFF Pomera DM250 completely and insert the prepared SD card (ensure the physical write-protect lock is OFF).
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
   *(Pressing `N` or Enter aborts the installation and drops into a maintenance menu. Internal storage is not modified).*
4. The installer runs automatically:
   - Partitions internal eMMC (`sd1`)
   - Installs OpenBSD base sets and X11
   - Executes `site79.tgz` hook to install the custom DM250 kernel (`/bsd`), disable `reorder_kernel`, configure Multi-SSID Wi-Fi, and enable lid power management.
5. When `🎉 OpenBSD INSTALLATION COMPLETED SUCCESSFULLY!` appears on screen:  
   **Press [Enter] on the keyboard to power off**.  
   *(※ Wait until the screen goes black and the unit completely powers off before removing the SD card).*
6. Turn ON Pomera to start OpenBSD from internal storage (`[Pomera DM250] Starting OpenBSD from Internal Storage...`).
7. A login prompt will appear on console:
   ```text
   OpenBSD/armv7 (pomera.my.domain) (console)
 
   login: 
   ```
   Log in with username **`pomera`** and password **`pomera`** (or your custom credentials set in `configs/user_config.env`).

> [!TIP]
> **💡 How to Adjust Screen Backlight Brightness**  
> You can control the DM250 display backlight depending on your environment:
> 
> 1. **Plain Console (CUI / Immediate post-login / Anytime)**:  
>    Adjust directly using the `pomera-brightness` command (operates without root password):
>    - `pomera-brightness down` : Dim screen brightness by 10%
>    - `pomera-brightness up` : Brighten screen brightness by 10%
>    - `pomera-brightness 50` : Set brightness directly to 50% (10-100%)
>    - `pomera-brightness` : Output current brightness percentage
> 
> 2. **CUI / mlterm-fb (`tmux` session)**:  
>    After running `pomera-setup-workspace` (Step 3), press hotkeys directly inside `tmux`:
>    - **`Alt + F1`** : Dim brightness (Mac-style)
>    - **`Alt + F2`** : Brighten brightness (Mac-style)  
>    *(※ No tmux prefix required; operates directly)*

> [!TIP]
> **💡 mlterm-fb Terminal Options (mlterm-opt / mlterm-base / mlterm-ja)**  
> The installer provides both standard and optimized versions of `mlterm-fb` (direct framebuffer terminal):
> - **`mlterm-opt`** (or `mlterm-fb-pomera`): Optimized low-latency edition (recommended, row bounding box differential updates + DECSET 2026 support)
> - **`mlterm-base`** (or `mlterm-fb`): Standard baseline edition (shadowfb direct framebuffer)
> - **`mlterm-ja`**: Japanese input terminal (`mlterm-opt -M skk:dict=/usr/local/share/skk/SKK-JISYO.L`)

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

### Step 3: Workspace & Japanese IME Setup

> Base system components, Wi-Fi auto-connect, lid daemon, and tailored dotfiles are already configured during Step 2.
> Packages (Vim, tmux, mlterm, Noto CJK, etc.) are staged into `/var/cache/packages`. Running `pomera-setup-workspace` upon first login finishes the installation cleanly without memory constraints. Everything works standalone and offline on the DM250.

#### 1. Workspace & Dev Environment Setup (`pomera-setup-workspace`)
```bash
pomera-setup-workspace
```
- Core tools (`vim`, `tmux`, `curl`, `git`)
- Direct framebuffer console binaries (`mlterm-opt`, `mlterm-base`, `mlterm-ja`)
- Japanese fonts (Noto Sans CJK)
- 1024x600 display optimized dotfiles (`~/.tmux.conf`, `~/.vimrc`, `~/.profile`)

> [!TIP]
> **Convenient Keyboard Shortcuts**:
> - **Brightness Control (tmux sessions)**:
>   - `Alt + F1`: Dim screen brightness (Mac-style)
>   - `Alt + F2`: Brighten screen brightness (Mac-style)
> - **CUI / Direct Framebuffer (mlterm-fb)**:
>   - `mlterm-opt`: Launch optimized low-latency CJK terminal
>   - `mlterm-base`: Launch standard baseline CJK terminal
>   - `mlterm-ja`: Launch Japanese input terminal with inline IME

#### 2. Japanese IME Input Setup (`pomera-setup-japanese`)
If you write in Japanese, run the second stage script:
```bash
pomera-setup-japanese
```
- Installs `skk-jisyo` (large dictionary `SKK-JISYO.L`)
- Configures JIS-friendly toggle shortcuts (`Shift + Space`, `Ctrl + Space`) in `~/.mlterm/key`
- Enables direct inline spot-preedit conversion via mlterm's built-in SKK engine in `~/.mlterm/main`

---

## 🛠️ On-Device Utilities

### System & Power Management

| Command | Description |
| :--- | :--- |
| `pomera-status [OPTIONS]` (or `pstat`) | Display one-line battery percentage/charging, CPU clock/policy, Wi-Fi SSID, and time (`--tmux`, `--short`, `--json`, `-w`). |
| `pomera-brightness [up\|down\|<%>]` | Adjust backlight brightness manually (`Alt+F1`/`Alt+F2` in tmux). |
| `doas pomera-tune [status\|apply]` | Optimize RAM and power by disabling unused daemons (`smtpd`, `sndiod`, `pflogd`) and virtual consoles (`ttyC1`-`ttyC5`). |
| `sysctl hw.sensors.simplebat0` | Display battery voltage, charging/discharging status, and capacity percentage (`percent0`). |
| `sysctl -n hw.sensors.simplebat0.percent0` | Output battery percentage only (e.g. `96.00%`). |
| `sysctl hw.cpuspeed` | Display current CPU operating clock speed in MHz (max: 1200 MHz). |
| `sysctl hw.perfpolicy` / `hw.setperf` | Check CPU scaling policy (`auto`/`high`) and clock percentage ratio (0-100%). |
| `doas rcctl [start\|stop\|restart\|check] pomera_lid_watch` | Manage the lid power management daemon via native OpenBSD `rcctl`. |
| `doas rcctl set pomera_lid_watch flags "-i 2.0 -p auto"` | Adjust lid polling interval (seconds) or CPU scaling policy. |
| `doas rcctl [start\|stop\|restart\|check] pomera_power_led` | Lightweight battery LED daemon (orange charging, green full, red low). |
| `doas rcctl [start\|stop\|restart\|check] pomera_wifi_watch` | Wi-Fi link monitoring & auto-reconnect daemon on link drops. |
| `doas pomera-wifi-reconnect` | Reset Wi-Fi interface (`bwfm0`) and re-acquire DHCP lease. |
| `doas pomera-suspend` | Suspend SoC to low-power state (wake via Power button or lid switch). |
| `doas gpioctl gpio1 red_led 1` / `green_led 1` | Control front status LEDs (`0` to turn off). |

### Workspace & Connectivity

| Command | Description |
| :--- | :--- |
| `mlterm-opt` | Launch optimized low-latency CJK terminal (`mlterm-fb-pomera`). |
| `mlterm-base` | Launch standard baseline CJK terminal (`mlterm-fb`). |
| `mlterm-ja` | Launch Japanese input terminal with inline IME (built-in SKK). |
| `pomera-setup-workspace` | Automatically set up CUI workspace (`mlterm-fb`, fonts, Vim, tmux, and dotfiles). |
| `pomera-setup-japanese` | Automatically set up Japanese IME (built-in SKK direct inline conversion) for `mlterm-fb`. |
| `pomera-font [-y] [udev\|moraler\|noto]` | Switch terminal fonts (slashed-zero UDEV Gothic, Moralerspace, or Noto) for `mlterm-fb` (auto-downloads on first use). |
| `doas pomera-bt-pan connect <BD_ADDR>` | *(Experimental)* Connect to smartphone Bluetooth Tethering (PAN) (requires 4noha's panctl daemon; unverified on hardware). |

### 🔧 Host PC Diagnostics & Simulator Tools (Advanced / Developers)

> [!NOTE]
> The tools below are orchestrated automatically by `make_sdcard.sh` and do NOT need to be run manually during standard installation. They are provided for troubleshooting, development, and modular verification.

| Tool | Description |
| :--- | :--- |
| `sudo python3 scripts/inspect_sd.py /dev/rdiskN` | Inspect physical sector layout, MBR, BootROM sectors (LBA 64/16384), and Disklabel. |
| `python3 scripts/inspect_kernel.py [kernel]` | Audit if a kernel binary is optimized DM250 smart kernel or contains USB/X11/mlterm-fb/Bluetooth fixes. |
| `python3 scripts/build_kernel_qemu.py [--config DM250]` | Automatically build patched (USB, X11 keys, mlterm-fb, BT) & slimmed kernel (`DM250` / `GENERIC`) via native QEMU VM. |
| `scripts/build_uboot.sh` | Standalone compilation of autoboot U-Boot image (`uboot.img`). |
| `scripts/run_qemu.sh [image_path]` | Run local QEMU simulation of the OpenBSD image before writing to physical hardware. |

---

## 🤝 Acknowledgements & Credits

This project builds upon and references prior research, open-source software, and contributions from the following individuals and projects:

- **Joshua Stein (jcs)**: [Installing OpenBSD on the Pomera DM250](https://jcs.org/2026/04/09/openbsd-dm250) — Initial DM250 OpenBSD kernel patches, U-Boot port, LVDS display driver, and AP6212 NVRAM configuration.
- **4noha**: [openbsd-pomera-dm250](https://github.com/4noha/openbsd-pomera-dm250) — Cross-build tooling, hardware kernel patches (AP6212A BT delay, rkdrm SMODE), `mlterm-fb` framebuffer optimization patches, battery and lid monitoring scripts, and Bluetooth PAN research.
- **ARAKI Ken**: [mlterm](https://github.com/arakiken/mlterm) — Multilingual terminal emulator with direct framebuffer backend (`mlterm-fb`) and built-in SKK IME engine.
- **ichinomoto**: [EKESETE.net](https://www.ekesete.net/log/?p=9504) — Prior research on DM200 / DM250 hardware architecture, Debian rootfs bring-up, and eMMC backup methodologies.
- **yuru7**: [UDEV Gothic](https://github.com/yuru7/udev-gothic) / [Moralerspace](https://github.com/yuru7/moralerspace) — Programming typography (SIL Open Font License 1.1).
- **Google LLC / Noto Fonts Project**: [Noto Sans CJK](https://github.com/notofonts/noto-cjk) — Monospace typography (SIL Open Font License 1.1).
- **OpenBSD Project**: [OpenBSD](https://www.openbsd.org/) — Base operating system and installer infrastructure.

---

## ⚠️ Disclaimer & Trademarks

- "Pomera" and "ポメラ" are registered trademarks of KING JIM CO., LTD. (株式会社キングジム).
- This project is an independent, unofficial volunteer open-source research and engineering effort. It is neither affiliated with, endorsed by, nor supported by KING JIM CO., LTD.
- Please **DO NOT** contact KING JIM CO., LTD. or official device support regarding this software or any issues arising from its use.
- This software is provided "as is", without warranty of any kind. Use at your own risk. The authors and contributors shall not be held liable for any hardware malfunction, data loss, voided warranties, or damages resulting from the use of this software.

---

## 📄 License

[MIT License](LICENSE)
