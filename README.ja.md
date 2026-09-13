# Pomera DM250 OpenBSD 自動インストーラー

[日本語](README.ja.md) | [English](README.md)

キングジム **ポメラ DM250**（DM250X, DM250XY, DM250US含む）に **OpenBSD 7.9 (armv7)** を導入し、日常的に持ち運べる究極のUNIXポータブル端末を構築するためのワンストップ自動インストーラーです。

**Wi-Fi・Bluetoothテザリング・USB-NIC/マウス対応・蓋閉じ超省電力/開け即時最速復帰・CUIとGUI(X11)の自在な切替** を誰でも簡単にセットアップできるように設計されています。

---

## 🌟 主な特徴

| 機能 | 詳細 |
| :--- | :--- |
| **⚡ 蓋開閉の超省電力＆最速復帰** | 専用デーモン `pomera_lid_watch`（`rcctl` 対応）が蓋センサーを監視。閉じた瞬間にバックライト0秒消灯＆CPU省電力化。開けると最速で復帰して即入力可能。検知秒数やCPUポリシー（auto/high）も自在に調整可能。 |
| **🔋 高精度バッテリー管理** | 内蔵 PMIC (RK818) と連動し、充電器接続時の自動給電・充電に対応。カーネルセンサー（`sysctl hw.sensors.simplebat0`）から電圧・充放電状態・残量パーセントを正確に取得。 |
| **🌐 充実のネットワーク (2.4GHz Wi-Fi)** | 内蔵 Wi-Fi (`bwfm0`、2.4GHz専用、複数SSID自動切替)、スマホテザリング用 Bluetooth PAN (`pomera-bt-pan`)、USB-Ethernet (`ure0`, `axe0`, `axen0`, `urndis0`, `cdce0`) に標準対応。 |
| **💻 CUI & GUI デュアル対応** | 標準は超軽量・高速な CUI (wsconsコンソール / VT100 / tmux)。フレームバッファ直描画の超高速日本語コンソール `mlterm-fb` に対応し、`pomera-gui-toggle` で軽量X11デスクトップ (`xenodm` + `cwm` + `mlterm`) へもワンタッチ切替可能。 |
| **🖱️ USB周辺機器プラグ＆プレイ** | USB Type-C OTG経由で標準的なUSBマウス、キーボード、有線LANアダプタを挿すだけで即認識。 |
| **🛡️ 100%原状復帰可能な安全設計** | [pomera-dm250-backup-restore-tool](https://github.com/mah-jp/pomera-dm250-backup-restore-tool) と連携し、導入前に純正eMMCの完全バックアップを取得可能。いつでも工場出荷時に戻せます。 |
| **🛠️ パッチ自動検査＆スマートビルド** | USBハブ安定化、X11キー修正、mlterm-fb直描画用カーネルパッチ（SMODE）を選択可能。公式カーネルを自動検査し、未修正時のみQEMUリコンパイルを実行、対応済みなら0秒で公式版を採用。 |
| **🤖 ネイティブQEMUエンジン自動構築** | 一時的な OpenBSD QEMU VM を介して本物の disklabel/FFS を生成。`user_config.env` による事前設定（Wi-Fi・パスワード・省電力）で実機インストールも完全自動で完走。 |

---

## 💻 対応する母艦OS

SDカード作成スクリプト（`make_sdcard.sh`）は以下の環境で動作します：

- 🍏 **macOS** (Apple Silicon M1/M2/M3/M4 および Intel x86_64, macOS Sonoma / Sequoia)
- 🐧 **Linux amd64 / aarch64** (Ubuntu 22.04/24.04, Debian 12, Fedora 39/40, Arch Linux, Raspberry Pi OS)

---

## 🧰 必要な機材・前提環境

1. **ポメラ DM250 / DM250X / DM250XY / DM250US 本体**（事前に十分充電されていること。目安50%以上、満充電推奨）
2. **SDカード**（2 GB 〜 32 GB の標準SDまたはmicroSD＋アダプタ）
3. **母艦PC**（macOS または Linux）
4. **USB Type-C ケーブル**（データ転送対応）
5. *(推奨)* USB Type-A to Type-C 変換アダプタ および USB有線LANアダプタ（USB-NIC）

> [!WARNING]
> **⚠️ 事前に本体バッテリーを十分に充電してください**  
> ポメラDM250はハードウェアの特性上、バッテリーが完全放電（0%）すると起動電力の不足によりUSB給電下でも起動が不安定になる場合があります。インストール作業（所要約2〜3分程度）は、十分にバッテリー残量がある状態で開始してください。なお、Wi-Fi利用時などType-Cポートが空いている場合は、USB充電器を接続して給電しながら作業するとより安全です。

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

---

## 🚀 クイックスタートガイド

```
[Phase 0: セーフティネット (推奨)]
  pomera-dm250-backup-restore-tool で純正eMMCのフルバックアップを取得
  ↓
[Phase 1: カスタム設定 & インストーラSDの作成]
  1. configs/user_config.env で Wi-Fi やパスワードを設定
  2. $ sudo ./make_sdcard.sh  (外付けSDを自動検知して対話選択)
  ↓
[Phase 2: ポメラ本体での全自動インストール]
  1. SDカードを挿入して [電源ボタン] を3〜4秒長押し
  2. インストーラが自動起動: [Pomera DM250] Booting OpenBSD Installer (SD Card)...
  3. 'yes' と入力してインストール承認
  (無人インストール、パッケージ退避、設定配置が約2〜3分で自動完走して安全に電源OFF)
  ↓
[Phase 3: 起動後の初回セットアップ / 日本語入力の追加]
  - ログイン後、画面の案内に従ってコマンドを実行するだけで完了！
  - ワークスペース一括導入: $ pomera-setup-workspace
  - 日本語入力 (IME) を追加する場合: $ pomera-setup-japanese
```

---

### Step 0: 純正eMMCのバックアップ（強く推奨）

作業前に、[pomera-dm250-backup-restore-tool](https://github.com/mah-jp/pomera-dm250-backup-restore-tool) を使ってポメラの内部eMMCをPCへ丸ごとバックアップしておきます。

```bash
git clone https://github.com/mah-jp/pomera-dm250-backup-restore-tool.git
cd pomera-dm250-backup-restore-tool
./prepare_sdcard.sh /dev/sdX
# ポメラをUMSモードで起動して backup_emmc.sh を実行
```

---

### Step 1: OpenBSD インストーラSDカードの作成

#### ⚙️ 1-A. ユーザー環境の事前設定 (推奨)
あらかじめ Wi-Fi の接続先やログインパスワード、CPU制御ポリシーなどを設定できます：

```bash
cp configs/user_config.env.example configs/user_config.env
# お好みのエディタで編集
nano configs/user_config.env
```

* **設定可能な項目**:
  * `POMERA_USERNAME` / `POMERA_USER_PASSWORD` : ユーザー名とパスワード（デフォルト: `pomera` / `pomera`）
  * `POMERA_ROOT_PASSWORD` : root パスワード（デフォルト: `pomera`）
  * `POMERA_WIFI_NETWORKS` : 接続先 Wi-Fi（**2.4GHz 帯専用**。複数指定可能、電波の強い方へ自動接続。※内蔵AP6212の仕様上、5GHz帯［-Aや-5Gなど］には非対応ですので必ず2.4GHz帯のSSIDを指定してください）
  * `POMERA_BOOT_TIMEOUT` : ブートローダーの待機秒数（デフォルト: `5` 秒）
  * `POMERA_LID_INTERVAL` : 蓋開閉検知デーモンの監視間隔秒数（デフォルト: `2.0` 秒）
  * `POMERA_CPU_POLICY` : CPU 動作ポリシー（`auto`: 負荷連動可変省電力 / `100` または `high`: 最高性能固定、デフォルト: `auto`）
  * `POMERA_ENABLE_SSHD` / `POMERA_ALLOW_ROOT_SSH` : SSHD 自動起動設定
  * `POMERA_CONFIRM_INSTALL` : インストール開始前の安全確認プロンプト（デフォルト: `yes`。`no` で完全無人化）
  * `POMERA_SMART_KERNEL` : 不要な他社SoCやPCIドライバを削ぎ落としたDM250特化型カーネル（約25%削減、デフォルト: `yes`。`no` で標準カーネル）
  * `POMERA_PATCH_USB_HUB` : USBハブ使用時の切断・クラッシュ防止パッチ（デフォルト: `yes`）
  * `POMERA_PATCH_X11_KEYS` : X11 GUI使用時の右Shiftおよび左Altキー修正パッチ（デフォルト: `yes`）
  * `POMERA_PATCH_MLTERM_FB` : 高速フレームバッファ直描画 `mlterm-fb` 用カーネルパッチ（デフォルト: `yes`）
  * `POMERA_PATCH_BT` : Bluetooth UART 2秒初期化待機パッチ（AP6212A用、デフォルト: `yes`）

> [!TIP]
> **💡 スマート・カーネル検査機能**  
> `POMERA_SMART_KERNEL`、`POMERA_PATCH_USB_HUB`、`POMERA_PATCH_X11_KEYS`、`POMERA_PATCH_MLTERM_FB`、`POMERA_PATCH_BT` を `yes` に設定した場合、インストーラーは公式カーネル（jcs.org）のバイナリを自動検査します。公式カーネルで既に要求機能が満たされている場合はリコンパイルを行わず公式バイナリをそのまま採用（待ち時間0秒）し、未対応の場合のみ一時的な QEMU VM で安全にリコンパイルを行います（ビルド結果はキャッシュされるため次回以降も即座に再利用されます）。

*(※ OpenBSD armv7 EFI ブートローダーの仕様上、ルートディスク暗号化 [softraid CRYPTO] ブートは非対応のため自動的に無効化されます)*

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

# Pomera DM250 特化型スマートカーネル（不要SoC・PCIドライバの削除、約25%削減）を適用する場合:
./make_sdcard.sh --smart-kernel

# 高速日本語コンソール mlterm-fb 用カーネルパッチを適用する場合:
./make_sdcard.sh --patch-mlterm-fb

# パッチ適用済みカーネルのQEMUリコンパイルを明示的に実行する場合:
./make_sdcard.sh --build-kernel
```

*(※ USモデル `DM250US` の場合は `--us` オプションを付与してください)*  
*(※ 安全のため、母艦PCの内蔵システムディスク [macOSのdisk0やLinuxのルートドライブ] は自動的に保護され、誤ってフォーマットされることはありません)*

---

### Step 2: ポメラ DM250 でのインストーラー起動 ＆ インストール実行

> [!IMPORTANT]
> **🛡️ 本体eMMC非破壊・ゼロリスク仕様**  
> 本ツールのインストーラーSDカードには、Rockchip RK3128 のハードウェア BootROM が直接読み込むブートローダー（`idbloader.img` / `uboot.img`）が書き込まれています。  
> 特殊なキー操作は一切不要で、**本体eMMCには事前に1バイトも書き込みを行いません**。インストーラー起動後に確認プロンプトで `yes` を入力するまで、本体の純正システムやデータは完全に保護されます（途中で中止してSDカードを抜けば、そのまま純正ポメラOSが起動します）。

> [!WARNING]
> **⚠️ SDカードの物理「書き込み禁止スイッチ（Lock）」について**  
> SDカード側面の物理スイッチは **必ず書き込み可能（Unlock）な状態** にしておいてください。  
> OpenBSD のインストーラーは、内蔵eMMCを初期化・マウントする過程で一時的なマウントテーブル（`/etc/fstab`）の作成などを行うため、SDカードがハードウェア的に書き込み禁止になっているとエラー（`Read-only file system`）で中断してしまいます。  
> *(※ インストール完了後に [Enter] を押して電源が切れた後であれば、SDカードはクリーンに保護されているため安全に取り出せます)*

1. ポメラの電源を完全に切り、作成したSDカード（書き込み可能状態）を挿入します。
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
5. 画面に `🎉 OpenBSD INSTALLATION COMPLETED SUCCESSFULLY!` が表示されたら：  
   **キーボードで [Enter] を押して電源を切ります**。  
   *(※ 画面が消えて電源が完全に切れた後で、SDカードを取り出してください)*
6. 再度電源ボタンを押すと、内蔵ストレージから OpenBSD が起動します（`[Pomera DM250] Starting OpenBSD from Internal Storage...`）。
7. 画面にログインプロンプトが表示されます：
   ```text
   OpenBSD/armv7 (pomera.my.domain) (console)

   login: 
   ```
   ユーザー名 **`pomera`**、パスワード **`pomera`**（または `configs/user_config.env` で指定した値）を入力してログインします。

> [!TIP]
> **💡 CUI と GUI (X11) の使い分け**  
> - **一時的に X11 GUI デスクトップを起動する**: ログイン後、`startx` を実行します。
> - **次回起動時からも常にグラフィカルログイン (xenodm) にする**: `doas pomera-gui-toggle gui` を実行します。
> - **超軽量・高解像度日本語コンソール (CUI) のまま使う**: そのままコンソールや tmux、`mlterm-fb` をお使いください。いつでも `doas pomera-gui-toggle cui` でCUI固定に戻せます。

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

### Step 3: ワークスペース＆日本語入力（IME）環境の導入

> [!NOTE]
> 本インストーラーによる自動インストール（Step 2）の時点で、**JIS日本語キーボード、Wi-Fi自動接続、USB-NIC、蓋開閉省電力デーモン、各種dotfiles（設定ファイル）** などの基本機能はすべてセットアップ完了しています。  
> 安定性と高速化のため、オフラインパッケージ群（Vim, tmux, mlterm, Noto CJK, cwm等）は内蔵ストレージ（`/var/cache/packages`）に自動退避されています。初回ログイン時に `pomera-setup-workspace` を実行することで、メモリ不足やエラーなく安全にワークスペースが完成します。外部PCやインターネット接続は不要で、ポメラ単体・完全オフラインで完結します。

#### 1. ワークスペース環境のセットアップ (`pomera-setup-workspace`)
```bash
pomera-setup-workspace
```
- 必須ツールの導入（`vim`, `tmux`, `curl`, `git`）
- 日本語フォント（Noto Sans CJK）＆ 残像のない高速ターミナル（`mlterm` / `mlterm-fb`）
- 超軽量ウィンドウマネージャ（`cwm`）＆ アプリランチャー（`dmenu`）
- 1024x600 画面に最適化された dotfiles（`~/.cwmrc`, `~/.tmux.conf`, `~/.xsession` 等）

> [!TIP]
> **便利なキーボードショートカット**:
> - **画面輝度調整（X11およびtmux/mlterm-fb共通）**:
>   - `Alt + F1`: 画面を暗くする ※Mac風
>   - `Alt + F2`: 画面を明るくする ※Mac風
>   - `Alt + ↑` / `Alt + ↓`: 画面の明るさを 10% 刻みで増減（cwmデスクトップ時）
> - **デスクトップ（cwm）**:
>   - `Alt + Enter`: ターミナル（mlterm）起動
>   - `Ctrl + Alt + m`: ウィンドウの最大化 / 復帰
>   - `Ctrl + Alt + q`: ウィンドウを閉じる
>   - `Ctrl + Alt + Backspace` または `Ctrl + Alt + Shift + q`: X11を終了してコンソール（CUI）に戻る
> - **CUI / フレームバッファ（mlterm-fb）**:
>   - `mlterm-fb`: フレームバッファ直描画の超高速・高解像度日本語コンソールを起動（X11不要、`Alt+F1`/`Alt+F2` 輝度調整対応）

#### 2. 日本語入力（IME）のセットアップ (`pomera-setup-japanese`)
日本語入力を利用する場合は、続けて以下を実行します：
```bash
pomera-setup-japanese
```
- 日本語入力フレームワーク（`uim`, `uim-anthy`）の自動インストール
- ポメラ向けキー設定（`Shift + Space`, `Ctrl + Space`, `半角/全角` でIMEオン/オフ）
- `startx` 時にバックグラウンドで `uim-xim` を自動起動するよう `~/.xsession` を構成

---

## 🛠️ ポメラ上での便利コマンド

### システム＆ハードウェア制御

| コマンド | 説明 |
| :--- | :--- |
| `pomera-brightness [up\|down\|<%>]` | 画面のバックライト明るさを手動調整（`Alt+F1`/`Alt+F2` でも操作可能）。 |
| `sysctl hw.sensors.simplebat0` | バッテリー電圧・充電状態・残量パーセント（`percent0`）を表示。 |
| `sysctl -n hw.sensors.simplebat0.percent0` | バッテリー残量パーセントのみをサクッと取得（例: `96.00%`）。 |
| `sysctl hw.cpuspeed` | 現在の CPU 動作クロック周波数を表示（単位: MHz、最大 1200 MHz）。 |
| `sysctl hw.perfpolicy` / `hw.setperf` | CPU 制御ポリシー（`auto`/`high`）およびクロック比率（0〜100%）を確認。 |
| `doas rcctl [start\|stop\|restart\|check] pomera_lid_watch` | 蓋開閉省電力デーモンの起動・停止・再起動・ステータス確認。 |
| `doas rcctl set pomera_lid_watch flags "-i 2.0 -p auto"` | 蓋検知間隔（秒）や蓋オープン時の CPU ポリシーを変更。 |
| `doas rcctl [start\|stop\|restart\|check] pomera_power_led` | バッテリーLEDインジケーター（充電中橙、満充電緑、残量低下赤）の常駐監視デーモン。 |
| `doas rcctl [start\|stop\|restart\|check] pomera_wifi_watch` | Wi-Fiリンク監視＆リンク切断時の自動再接続常駐デーモン。 |
| `doas pomera-wifi-reconnect` | Wi-Fi（`bwfm0`）インターフェースを即座に再起動してDHCPを再取得。 |
| `doas pomera-suspend` | SoC/PLLを休止してディープサスペンドへ移行（電源ボタンや蓋開閉で復帰）。 |
| `doas gpioctl gpio1 red_led 1` / `green_led 1` | 前面の赤/緑ステータスLEDを手動で点灯・消灯（`0` で消灯）。 |

### デスクトップ＆ネットワーク

| コマンド | 説明 |
| :--- | :--- |
| `pomera-setup-workspace` | ワークスペース環境（Vim、tmux、mlterm、Noto CJK、cwm、dotfiles）を一括セットアップ・再初期化。 |
| `pomera-setup-japanese` | 日本語入力システム (`uim`/`uim-anthy`) および XIM 設定を自動セットアップ。 |
| `pomera-font [udev\|moraler\|noto]` | ターミナルフォント（斜線ゼロ入り UDEV Gothic、Moralerspace、Noto）をワンタッチ切替（X11版 / `mlterm-fb` 共通）。 |
| `doas pomera-gui-toggle [gui\|cui\|toggle]` | CUIコンソールとX11 GUIモード（`xenodm`/`cwm`）を即座に切り替え。 |
| `doas pomera-bt-pan connect <BD_ADDR>` | スマホのBluetoothテザリング（PAN）にワンタッチ接続（※要4noha氏のpanctlデーモン）。 |

### 🔧 ホストPC側での診断・シミュレーターツール (上級者・開発向け)

> [!NOTE]
> 以下のツールは `make_sdcard.sh` が内部で自動的に呼び出すため、通常のインストール作業でユーザーが手動実行する必要はありません。トラブルシューティングや個別検証を行いたい場合にご利用ください。

| ツール | 説明 |
| :--- | :--- |
| `sudo python3 scripts/inspect_sd.py /dev/rdiskN` | 作成したSDカードのMBR、ブートローダーセクタ（LBA 64/16384）、Disklabelを物理検査。 |
| `python3 scripts/inspect_kernel.py [kernel]` | カーネルバイナリが DM250 スマートカーネルか、USB/X11キー/mlterm-fb/Bluetooth修正を含むかを自動監査。 |
| `python3 scripts/build_kernel_qemu.py [--config DM250]` | QEMU ネイティブVM上でパッチ適用（USB, X11キー, mlterm-fb, BT）・軽量特化カーネル（`DM250` / `GENERIC`）を自動ビルド。 |
| `scripts/build_uboot.sh` | DM250専用のハンズフリー auto-boot U-Bootバイナリ（`uboot.img`）を単体ビルド。 |
| `scripts/run_qemu.sh [image_path]` | 実機に挿す前に、作成したイメージをローカルPC（Mac/Linux）のQEMUシミュレータで起動テスト。 |

---

## 🤝 謝辞・クレジット

- **Joshua Stein (jcs)**: [OpenBSD on Pomera DM250](https://jcs.org/2026/04/09/openbsd-dm250) のカーネル・U-Boot・ディスプレイドライバ開発
- **4noha**: [openbsd-pomera-dm250](https://github.com/4noha/openbsd-pomera-dm250) ツールチェーン、カーネルパッチ、バッテリー/蓋スクリプト、Bluetooth PAN研究
- **ARAKI Ken**: 多言語端末エミュレータ [mlterm](https://github.com/arakiken/mlterm) の開発（フレームバッファ直描画コンソール `mlterm-fb` の中核）
- **ichinomoto**: DM250実機ハックの安全性を確立した [EKESETE](https://github.com/ichinomoto/dm250_ekesete) eMMCバックアップツールの開発と先駆的研究
- **mah-jp**: [pomera-dm250-backup-restore-tool](https://github.com/mah-jp/pomera-dm250-backup-restore-tool) U-Boot UMS バックアップ/リカバリツール

---

## ⚠️ 免責事項・商標について

- 「ポメラ」および「Pomera」は、株式会社キングジムの登録商標です。
- 本プロジェクトは個人有志による非公式の研究・開発成果であり、株式会社キングジム様とは一切関係ありません。本ソフトウェアおよび手順に関して、**メーカー（株式会社キングジム様）へのお問い合わせは固くお断りいたします**。
- 本ソフトウェアの使用や導入に伴い生じた機器の故障、データの破損・消失、メーカー保証の失効などについて、作者およびプロジェクト貢献者は一切の責任を負いかねます。すべて自己責任の上でご利用ください。

---

## 📄 ライセンス

[MIT License](LICENSE)
