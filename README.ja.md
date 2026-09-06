# Pomera DM250 OpenBSD 自動インストーラー

[日本語](README.ja.md) | [English](README.md)

キングジム **ポメラ DM250**（DM250X, DM250XY, DM250US含む）に **OpenBSD 7.9 (armv7)** を導入し、日常的に持ち運べる究極のUNIXポータブル端末を構築するためのワンストップ自動インストーラーです。

**Wi-Fi・Bluetoothテザリング・USB-NIC/マウス対応・蓋閉じ超省電力/開け即時最速復帰・CUIとGUI(X11)の自在な切替** を誰でも簡単にセットアップできるように設計されています。

---

## 🌟 主な特徴

| 機能 | 詳細 |
| :--- | :--- |
| **⚡ 蓋開閉の超省電力＆最速復帰** | 専用デーモン `pomera-lid-watch` が蓋センサーを監視。閉じた瞬間にバックライト0秒消灯＆CPU省電力化。開けると最速で復帰して即入力可能。 |
| **🌐 充実のネットワーク** | 内蔵 Wi-Fi (`bwfm0`、複数SSID自動切替)、スマホテザリング用 Bluetooth PAN (`pomera-bt-pan`)、USB-Ethernet (`ure0`, `axe0`, `axen0`, `urndis0`, `cdce0`) に標準対応。 |
| **🔒 フルディスク暗号化 (FDE)** | OpenBSD `softraid CRYPTO` による eMMC 暗号化に対応。万が一の紛失・盗難時にも機密メモやSSH鍵を強固に保護。 |
| **💻 CUI & GUI デュアル対応** | 標準は超軽量・高速な CUI (wsconsコンソール / VT100 / tmux)。`pomera-gui-toggle` で軽量X11デスクトップ (`xenodm` + `cwm` + `mlterm`) へいつでもワンタッチ切替可能。 |
| **🖱️ USB周辺機器プラグ＆プレイ** | USB Type-C OTG経由で標準的なUSBマウス、キーボード、有線LANアダプタを挿すだけで即認識。 |
| **🛡️ 100%原状復帰可能な安全設計** | [pomera-dm250-recovery-tool](https://github.com/mah-jp/pomera-dm250-recovery-tool) と連携し、導入前に純正eMMCの完全バックアップを取得可能。いつでも工場出荷時に戻せます。 |
| **🤖 ネイティブQEMUエンジン自動構築** | 一時的な OpenBSD QEMU VM を介して本物の disklabel/FFS を生成。`user_config.env` による事前設定（Wi-Fi・パスワード・暗号化）で実機インストールも完全自動で完走。 |

---

## 💻 対応する母艦OS

SDカード作成スクリプト（`make_sdcard.sh`）は以下の環境で動作します：

- 🍏 **macOS** (Apple Silicon M1/M2/M3/M4 および Intel x86_64, macOS Sonoma / Sequoia)
- 🐧 **Linux amd64 / aarch64** (Ubuntu 22.04/24.04, Debian 12, Fedora 39/40, Arch Linux, Raspberry Pi OS)

---

## 🧰 必要な機材・前提環境

1. **ポメラ DM250 / DM250X / DM250XY / DM250US 本体**（十分充電されていること）
2. **SDカード**（2 GB 〜 32 GB の標準SDまたはmicroSD＋アダプタ）
3. **母艦PC**（macOS または Linux）
4. **USB Type-C ケーブル**（データ転送対応）
5. *(推奨)* USB Type-A to Type-C 変換アダプタ および USB有線LANアダプタ（USB-NIC）

### 母艦PCの事前準備（ツールインストール）

`make_sdcard.sh` は本物の OpenBSD ディスクラベルを生成するため、内部で一時的な OpenBSD QEMU VM を駆動します。

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

*(※ Phase 3 の Ansible 追加プロビジョニングを利用する場合は、母艦に `ansible` もインストールしてください)*

---

## 🚀 クイックスタートガイド

```
[Phase 0: セーフティネット (推奨)]
  pomera-dm250-recovery-tool で純正eMMCのフルバックアップを取得
  ↓
[Phase 1: カスタム設定 & インストーラSDの作成]
  1. configs/user_config.env で Wi-Fi やパスワードを設定
  2. $ sudo ./make_sdcard.sh  (外付けSDを自動検知して対話選択)
  ↓
[Phase 2: ポメラ本体での全自動インストール]
  1. SDカードを挿入して [電源ボタン] を3〜4秒長押し
  2. インストーラが自動起動: [Pomera DM250] Booting OpenBSD Installer (SD Card)...
  3. 'yes' と入力してインストール承認
  (無人インストールとカーネル・設定配置が自動完走して安全に電源OFF)
  ↓
[Phase 3: 任意・追加環境構築 (Ansible)]
  $ cd ansible && ansible-playbook -i inventory.ini pomera_setup.yml
```

---

### Step 0: 純正eMMCのバックアップ（強く推奨）

作業前に、[pomera-dm250-recovery-tool](https://github.com/mah-jp/pomera-dm250-recovery-tool) を使ってポメラの内部eMMCをPCへ丸ごとバックアップしておきます。

```bash
git clone https://github.com/mah-jp/pomera-dm250-recovery-tool.git
cd pomera-dm250-recovery-tool
./prepare_sdcard.sh /dev/sdX
# ポメラをUMSモードで起動して backup_emmc.sh を実行
```

---

### Step 1: OpenBSD インストーラSDカードの作成

#### ⚙️ 1-A. ユーザー環境の事前設定 (推奨)
あらかじめ Wi-Fi の接続先やログインパスワード、フルディスク暗号化の有無を設定できます：

```bash
cp configs/user_config.env.example configs/user_config.env
# お好みのエディタで編集
nano configs/user_config.env
```

* **設定可能な項目**:
  * `POMERA_USERNAME` / `POMERA_USER_PASSWORD` : ユーザー名とパスワード（デフォルト: `pomera` / `pomera`）
  * `POMERA_ROOT_PASSWORD` : root パスワード（デフォルト: `pomera`）
  * `POMERA_WIFI_NETWORKS` : 接続先 Wi-Fi（複数指定可能、電波の強い方へ自動接続）
  * `POMERA_ENABLE_SSHD` / `POMERA_ALLOW_ROOT_SSH` : SSHD 自動起動設定
  * `POMERA_CONFIRM_INSTALL` : インストール開始前の安全確認プロンプト（デフォルト: `yes`。`no` で完全無人化）

> ⚠️ **ディスク暗号化について**: OpenBSD 32-bit ARM (`armv7`) の EFI ブートローダー（`BOOTARM.EFI`）の仕様上、ルート暗号化（softraid CRYPTO）ブートは非対応です。そのため本ツールでは暗号化を常に無効化（`no`）にして安全にインストールします。

#### 💾 1-B. SDカードの作成
母艦PCで `make_sdcard.sh` を実行します。OpenBSD 7.9 armv7 公式バイナリ、DM250専用カスタムカーネル、U-Boot、ファームウェア等が自動ダウンロードされ、一時的な OpenBSD QEMU VM を駆動して SD カードへ本物の disklabel/FFS を書き込みます。

```bash
# デバイス名を省略すると、接続されている外付けSDカードを安全に一覧表示＆対話選択できます:
sudo ./make_sdcard.sh

# デバイスを直接指定する場合:
# Linux:
sudo ./make_sdcard.sh /dev/sdb
# macOS:
sudo ./make_sdcard.sh /dev/rdisk4

# ダウンロードとキャッシュのみ行う場合:
./make_sdcard.sh --download-only
```

*(※ USモデル `DM250US` の場合は `--us` オプションを付与してください)*  
*(※ 安全のため、母艦PCの内蔵システムディスク [macOSのdisk0やLinuxのルートドライブ] は自動的に保護され、誤ってフォーマットされることはありません)*

---

### Step 2: ポメラ DM250 でのインストーラー起動 ＆ インストール実行

> [!IMPORTANT]
> **🛡️ 本体eMMC非破壊・ゼロリスク仕様**  
> 本ツールのインストーラーSDカードには、Rockchip RK3128 のハードウェア BootROM が直接読み込むブートローダー（`idbloader.img` / `uboot.img`）が書き込まれています。  
> 特殊なキー操作は一切不要で、**本体eMMCには事前に1バイトも書き込みを行いません**。インストーラー起動後に確認プロンプトで `yes` を入力するまで、本体の純正システムやデータは完全に保護されます（途中で中止してSDカードを抜けば、そのまま純正ポメラOSが起動します）。

1. ポメラの電源を完全に切り、作成したSDカードを挿入します（USB給電ケーブルは抜いておきます）。
2. 通常通り **[電源ボタン]** を押して電源を入れます（3〜4秒長押し）。  
   *(SDカード上のブートローダーから自動起動し、`[Pomera DM250] Booting OpenBSD Installer (SD Card)...` と表示されてインストーラーカーネルが自動的に読み込まれます)*
3. 画面に安全確認プロンプトが表示されます：
   ```text
   ==========================================================
     WARNING: ALL DATA ON INTERNAL STORAGE (eMMC)
     WILL BE COMPLETELY ERASED!
     OpenBSD 7.9 will be installed onto internal storage.
   ==========================================================
   Start installation? (yes/N): 
   ```
   **`yes`** と入力して [Enter] を押すと、初めて本体eMMCの初期化とインストールが開始されます。  
   *(※ `N` や空Enterを入力するとインストールを直ちに中断し、メンテナンスメニューへ安全に移行します。本体eMMCは一切変更されません)*
4. 以降は完全手放しでインストールが走り、内蔵eMMC（`sd1`）の自動初期化、ベースセット導入、`site79.tgz`（DM250カスタムカーネル `/bsd` 配置、`reorder_kernel` 事前無効化、複数SSID Wi-Fi / USB-NIC DHCP設定、蓋開閉監視デーモン登録）がすべて自動実行されます。
5. 画面に `🎉 ALL OPERATIONS COMPLETED SUCCESSFULLY!` が表示されたら：
   **SDカードをポメラから抜き、キーボードで [Enter] を押して電源を切ります**。
6. 電源ボタンを押すと、内蔵ストレージから OpenBSD が起動します（`[Pomera DM250] Starting OpenBSD from Internal Storage...`）！

> [!TIP]
> **💡 既にカスタムOS（OpenBSD等）がインストール済みの状態からSDカードを起動する場合**
> 
> 内蔵eMMCに既にOSがインストールされている環境でSDカードのインストーラーを再起動したい場合、そのまま本体のOS起動へ移ってしまうことがあります。  
> その場合は、電源投入直後に**キーボードの何かキーを押して** U-Boot の自動起動を止め、プロンプト（`=> `）を出した後に以下の2行を入力することで、SDカードから確実に起動させることができます：
> 
> ```text
> => load mmc 1:1 0x62000000 efi/boot/bootarm.efi
> => bootefi 0x62000000
> ```

---

### Step 3: デスクトップ＆開発環境のセットアップ (任意)

> [!NOTE]
> 本インストーラーによる自動インストール（Step 2）の時点で、**JIS日本語キーボード、Wi-Fi自動接続、USB-NIC、蓋開閉省電力デーモン** などの基本機能はすべてセットアップ完了しています。  
> Step 3 は、日本語フォント、X11デスクトップ環境（`cwm`/`mlterm`）、エディタ（`vim`）、tmux設定などの追加環境を導入したい場合に行うオプショナルな手順です。外部PCは不要で、ポメラ単体で完結します。

ポメラが起動しログインしたら、Wi-FiまたはUSB-NICでネットワークに接続し、以下のコマンドを実行します：

```bash
pomera-setup-desktop
```

対話プロンプトに従って待つだけで、以下の環境が一括セットアップされます：
- 必須ツールの導入（`vim`, `tmux`, `curl`, `git`）
- 日本語フォント（Noto Sans CJK）＆ 日本語ターミナル（`mlterm`）
- 超軽量ウィンドウマネージャ（`cwm`）＆ アプリランチャー（`dmenu`）
- 1024x600 画面に最適化された dotfiles（`~/.tmux.conf`, `~/.cwmrc`, `~/.profile`, `~/.xsession`）

---

## 🛠️ ポメラ上での便利コマンド

| コマンド | 説明 |
| :--- | :--- |
| `pomera-setup-desktop` | 日本語フォント、GUI (`cwm`/`mlterm`)、Vim、tmux、dotfiles を一括自動セットアップ。 |
| `doas pomera-gui-toggle [gui\|cui\|toggle]` | CUIコンソールとX11 GUIモード（`xenodm`/`cwm`）を即座に切り替え。 |
| `doas pomera-bt-pan connect <BD_ADDR>` | スマホのBluetoothテザリング（PAN）にワンタッチ接続。 |
| `doas gpioctl gpio1 red_led 1` / `green_led 1` | 前面の赤/緑ステータスLEDを点灯・消灯。 |
| `wsconsctl display.brightness=0..100` | 画面の明るさを手動調整。 |

---

## 🤝 謝辞・クレジット

- **Joshua Stein (jcs)**: [OpenBSD on Pomera DM250](https://jcs.org/2026/04/09/openbsd-dm250) のカーネル・U-Boot・ディスプレイドライバ開発
- **4noha**: [openbsd-pomera-dm250](https://github.com/4noha/openbsd-pomera-dm250) ツールチェーンおよびバッテリー/蓋スクリプト
- **mah-jp**: [pomera-dm250-recovery-tool](https://github.com/mah-jp/pomera-dm250-recovery-tool) U-Boot UMS バックアップ/リカバリツール

---

## 📄 ライセンス

[MIT License](LICENSE)
