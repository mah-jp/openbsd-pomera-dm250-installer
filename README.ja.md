# Pomera DM250 OpenBSD 自動インストーラー

[日本語](README.ja.md) | [English](README.md)

King Jim **Pomera DM250**（DM250X, DM250XY, DM250US含む）に **OpenBSD 7.9 (armv7)** を導入し、ポータブルなUNIX環境を構築するための自動インストーラーです。

**内蔵Wi-Fi・日本語コンソール（mlterm-fb）・蓋開閉連動の省電力制御・キーボード最適化** などを自動でセットアップし、スムーズに導入できるように設計されています。

---

## 🌟 主な特徴

| 機能 | 詳細 |
| :--- | :--- |
| **⚡ 蓋開閉連動の省電力と復帰** | 専用デーモン `pomera_lid_watch`（`rcctl` 対応）が蓋センサーを監視。閉じた際にバックライト消灯およびCPU省電力化を行い、開けると画面が復帰します。検知間隔やCPUポリシー（auto/high）の設定変更にも対応しています。 |
| **🔋 バッテリー管理** | 内蔵 PMIC (RK818) と連動し、充電器接続時の自動給電・充電に対応。カーネルセンサー（`sysctl hw.sensors.simplebat0`）から電圧・充放電状態・残量パーセントを取得可能です。 |
| **🌐 内蔵 Wi-Fi (2.4GHz)** | 内蔵 Wi-Fi (`bwfm0`、2.4GHz、複数SSID自動切替・監視常駐デーモン) に標準対応。*(※ 実験的機能として Bluetooth PAN や USB-Ethernet ドライバの設定枠も保持)* |
| **💻 CUI ライティング環境** | フレームバッファ直描画の日本語コンソール `mlterm-fb`（標準版 / 最適化版）に対応。X11を介さずに直接フレームバッファを描画するため軽量で、テキスト執筆やターミナル操作に適した環境を提供します。 |
| **🖱️ USB周辺機器対応** | USB Type-C OTG経由で標準的なUSBマウスや外付けキーボード等の接続に対応。 |
| **🛡️ 純正状態への復帰手順** | [pomera-dm250-backup-restore-tool](https://github.com/mah-jp/pomera-dm250-backup-restore-tool) と連携し、導入前に純正eMMCのバックアップを取得可能。必要に応じて工場出荷時の状態に復元できます。 |
| **🛠️ パッチ自動検査＆ビルド** | USBハブ安定化、X11キー修正、mlterm-fb直描画用カーネルパッチ（SMODE）を選択可能。公式カーネルを自動検査し、未修正時のみQEMUリコンパイルを実行、対応済みであれば再ビルドをスキップして公式版を採用します。 |
| **🤖 ネイティブQEMUによるイメージ生成** | 一時的な OpenBSD QEMU VM を介して公式仕様準拠の disklabel/FFS を生成。`user_config.env` による事前設定（Wi-Fi・パスワード・省電力）を反映した自動インストールが可能です。 |

---

## 💻 対応する母艦OS

SDカード作成スクリプト（`make_sdcard.sh`）は以下の環境で動作します：

- 🍏 **macOS** (Apple Silicon / Intel)
- 🐧 **Linux** (amd64 / aarch64)

---

## 🧰 必要な機材・前提環境

1. **Pomera DM250 / DM250X / DM250XY / DM250US 本体**（事前に十分充電されていること。目安50%以上、満充電推奨）
2. **SDカード**（2 GB 〜 32 GB の標準SDまたはmicroSD＋アダプタ）
3. **母艦PC**（macOS または Linux）
4. **USB Type-C ケーブル**（給電・充電用）

> [!WARNING]
> **⚠️ 事前に本体バッテリーを十分に充電してください**  
> Pomera DM250 はハードウェアの特性上、バッテリーが完全放電（0%）すると起動電力の不足によりUSB給電下でも起動が不安定になる場合があります。インストール作業（所要約2〜3分程度）は、十分にバッテリー残量がある状態で開始してください。なお、Wi-Fi利用時などType-Cポートが空いている場合は、USB充電器を接続して給電しながら作業するとより安全です。

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
[Phase 0: バックアップ (推奨)]
  pomera-dm250-backup-restore-tool で純正eMMCのバックアップを取得
  ↓
[Phase 1: 設定 & インストーラSDの作成]
  1. configs/user_config.env で Wi-Fi やパスワードを設定
  2. $ sudo ./make_sdcard.sh  (外付けSDを自動検知して対話選択)
  ↓
[Phase 2: Pomera 本体でのインストール]
  1. SDカードを挿入して [電源ボタン] を3〜4秒長押し
  2. インストーラが自動起動: [Pomera DM250] Booting OpenBSD Installer (SD Card)...
  3. 'yes' と入力してインストール承認
  (自動インストール、パッケージ配置、設定適用が進行し、約2〜3分で完了して電源OFF)
  ↓
[Phase 3: 起動後の初期セットアップ / 日本語入力の追加]
  - ログイン後、画面の案内に従ってセットアップコマンドを実行
  - ワークスペース導入: $ pomera-setup-workspace
  - 日本語入力 (IME) を追加する場合: $ pomera-setup-japanese
```

---

### Step 0: 純正eMMCの完全バックアップ（必須・工場出荷状態への復元に不可欠）

> [!CAUTION]
> **🚨 ブートローダー領域を含む完全バックアップがない場合、二度と純正（工場出荷状態）に戻せません**  
> 本インストーラーを実行すると、Pomera 本体内蔵eMMCのパーティションおよびブートローダー領域が上書きされます。  
> **本体eMMCのブートローダー領域を含む完全なバックアップが存在しない場合、Pomeraを工場出荷状態に戻すことは二度とできなくなります。**  
> 
> ※ ichinomoto 氏（[EKESETE.net](https://www.ekesete.net/log/?p=9504)）で公開されているバックアップツールでは、本体eMMCのブートローダー領域（先頭の raw セクター領域）のバックアップは残されません。そのため、**工場出荷状態への復元を行うには不十分です**。  
> 必ずブートローダー領域を含む eMMC 全体を丸ごと保存できる [pomera-dm250-backup-restore-tool](https://github.com/mah-jp/pomera-dm250-backup-restore-tool) を使用し、作業前に母艦PCへ完全なバックアップを作成してください。

```bash
git clone https://github.com/mah-jp/pomera-dm250-backup-restore-tool.git
cd pomera-dm250-backup-restore-tool
./prepare_sdcard.sh /dev/sdX
# Pomera をUMSモードで起動して backup_emmc.sh を実行（eMMC全領域を完全バックアップ）
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
  * `POMERA_CONFIRM_INSTALL` : インストール開始前の安全確認プロンプト（デフォルト: `yes`。`no` で確認プロンプトをスキップ）
  * `POMERA_SMART_KERNEL` : 不要な他社SoCやPCIドライバを削ぎ落としたDM250特化型カーネル（約25%削減、デフォルト: `yes`。`no` で標準カーネル）
  * `POMERA_PATCH_USB_HUB` : USBハブ使用時の切断・クラッシュ防止パッチ（デフォルト: `yes`）
  * `POMERA_PATCH_X11_KEYS` : X11 GUI使用時の右Shiftおよび左Altキー修正パッチ（デフォルト: `yes`）
  * `POMERA_PATCH_MLTERM_FB` : 高速フレームバッファ直描画 `mlterm-fb` 用カーネルパッチ（デフォルト: `yes`）
  * `POMERA_PATCH_BT` : Bluetooth UART 2秒初期化待機パッチ（AP6212A用、デフォルト: `yes`）

> [!TIP]
> **💡 カーネル検査機能**  
> `POMERA_SMART_KERNEL`、`POMERA_PATCH_USB_HUB`、`POMERA_PATCH_X11_KEYS`、`POMERA_PATCH_MLTERM_FB`、`POMERA_PATCH_BT` を `yes` に設定した場合、インストーラーは公式カーネル（jcs.org）のバイナリを自動検査します。公式カーネルで既に要求機能が満たされている場合はリコンパイルを行わず公式バイナリを採用し、未対応の場合のみ一時的な QEMU VM でリコンパイルを行います（ビルド結果はキャッシュされるため次回以降も再利用されます）。

*(※ OpenBSD armv7 EFI ブートローダーの仕様上、ルートディスク暗号化 [softraid CRYPTO] ブートは非対応のため自動的に無効化されます)*

#### 💾 1-B. SDカードの作成
母艦PCで `make_sdcard.sh` を実行します。OpenBSD 7.9 armv7 公式バイナリ、DM250専用カスタムカーネル、U-Boot、ファームウェア等が自動ダウンロードされ、一時的な OpenBSD QEMU VM を介して SD カードへ公式仕様準拠の disklabel/FFS を書き込みます。

```bash
# デバイス名を省略すると、接続されている外付けSDカードを安全に一覧表示＆対話選択できます:
# （検出デバイスが1台の場合は [Enter] を押すだけで自動選択、または番号 [1] でも選択可能）
sudo ./make_sdcard.sh

# デバイスを直接指定する場合（対話選択をスキップ）:
# Linux:
sudo ./make_sdcard.sh /dev/sda
# macOS:
sudo ./make_sdcard.sh /dev/rdisk4

# ダウンロードとキャッシュのみ行う場合:
./make_sdcard.sh --download-only
```

*(※ USモデル `DM250US` の場合は `--us` オプションを付与してください)*  
*(※ 安全のため、母艦PCの内蔵システムディスク [macOSのdisk0やLinuxのルートドライブ] は自動的に保護され、誤ってフォーマットされることはありません)*

---

### Step 2: Pomera DM250 でのインストーラー起動 ＆ インストール実行

> [!IMPORTANT]
> **🛡️ インストーラー起動時の本体ストレージ保護**  
> 本ツールのインストーラーSDカードには、Rockchip RK3128 のハードウェア BootROM が直接読み込むブートローダー（`idbloader.img` / `uboot.img`）が書き込まれています。  
> 特殊なキー操作は不要で、SDカード上のブートローダーから起動します。**インストーラー起動後の確認プロンプトで `yes` を入力するまで、本体ストレージ（eMMC）に対する書き込みは行われません**。途中で作業を中断してSDカードを取り出せば、元の純正システムが起動します。

> [!WARNING]
> **⚠️ SDカードの物理「書き込み禁止スイッチ（Lock）」について**  
> SDカード側面の物理スイッチは **必ず書き込み可能（Unlock）な状態** にしておいてください。  
> OpenBSD のインストーラーは、内蔵eMMCを初期化・マウントする過程で一時的なマウントテーブル（`/etc/fstab`）の作成などを行うため、SDカードがハードウェア的に書き込み禁止になっているとエラー（`Read-only file system`）で中断します。  
> *(※ インストール完了後に [Enter] を押して電源が切れた後であれば、SDカードを安全に取り出せます)*

1. Pomera の電源を完全に切り、作成したSDカード（書き込み可能状態）を挿入します。
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
   **`yes`** と入力して [Enter] を押すと、本体eMMCの初期化とインストールが開始されます。  
   *(※ `N` や空Enterを入力するとインストールを中断し、メンテナンスメニューへ移行します。本体eMMCは変更されません)*
4. 確認後は自動でインストール処理が進行し、内蔵eMMC（`sd1`）の初期化、ベースセット導入、`site79.tgz`（DM250カスタムカーネル `/bsd` 配置、`reorder_kernel` 事前無効化、複数SSID Wi-Fi設定、蓋開閉監視デーモン登録）が順次実行されます。
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
> **💡 画面の輝度（明るさ）を調整する方法**  
> Pomera DM250 の液晶バックライトは、動作環境（素のCUI、tmux、X11 GUI）に応じて以下の方法で調整できます：
> 
> 1. **素のコンソール（CUI / 初回ログイン直後・いつでも）**:  
>    コマンド `pomera-brightness` で直接調整します（一般ユーザー権限で動作します）。
>    - `pomera-brightness down` : 画面を 10% 暗くする
>    - `pomera-brightness up` : 画面を 10% 明るくする
>    - `pomera-brightness 50` : 輝度を 50% に直接設定（10〜100%）
>    - `pomera-brightness` : 現在の輝度パーセントを表示
> 
> 2. **CUI / mlterm-fb 環境（`tmux` 起動時）**:  
>    Step 3 で `pomera-setup-workspace` を実行後、`tmux` セッション内ではショートカットキーで直接調整できます。
>    - **`Alt + F1`** : 画面を暗くする（Mac風）
>    - **`Alt + F2`** : 画面を明るくする（Mac風）  
>    *(※ tmuxのプレフィックスキー不要でそのまま押せます)*


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
> 自動インストール（Step 2）の完了時点で、**JIS日本語キーボード、Wi-Fi接続設定、蓋開閉監視デーモン、各種設定ファイル（dotfiles）** などの基本機能はセットアップされています。  
> パッケージ群（Vim, tmux, mlterm, Noto CJK等）は内蔵ストレージ（`/var/cache/packages`）にあらかじめ退避されているため、初回ログイン後に `pomera-setup-workspace` を実行することでオフラインのままセットアップを完了できます。

#### 1. ワークスペース環境のセットアップ (`pomera-setup-workspace`)
```bash
pomera-setup-workspace
```
- 基本ツールの導入（`vim`, `tmux`, `curl`, `git`）
- 日本語フォント（Noto Sans CJK）およびターミナル（`mlterm-opt` / `mlterm-base`）の配置
- 1024x600 画面に合わせた設定ファイル群（`~/.vimrc`, `~/.tmux.conf`, `~/.mlterm` 等）

> [!TIP]
> **ターミナル実行バイナリ**:
> - **`mlterm-opt`**: 行単位差分転送（Row Bounding Box）および DECSET 2026 同期描画に対応した最適化版
> - **`mlterm-base`**: 標準 shadowfb を用いた安定版
> - **`mlterm-ja`**: 日本語入力（mlterm 内蔵 SKK 直接インライン変換）を有効にしてターミナルを起動

#### 2. 日本語入力（IME）のセットアップ (`pomera-setup-japanese`)
日本語入力を利用する場合は、続けて以下を実行します：
```bash
pomera-setup-japanese
```
- 日本語入力環境（`skk-jisyo` / `SKK-JISYO.L`）のセットアップ
- Pomera 向けキー設定（`Shift + Space` や `Ctrl + Space` でかなモード ON/OFF）
- `mlterm-fb` 内蔵の SKK エンジンによるカーソル位置での直接インライン変換（常駐デーモン不要）

---

## 🛠️ Pomera 上での便利コマンド

### システム＆ハードウェア制御

| コマンド | 説明 |
| :--- | :--- |
| `pomera-status [OPTIONS]` (または `pstat`) | バッテリー残量・充電状態・CPUクロック・Wi-Fi接続・時刻を一覧表示（`--tmux`, `--short`, `--json`, `-w` 対応）。 |
| `pomera-brightness [up\|down\|<%>]` | 画面のバックライト明るさを手動調整（`Alt+F1`/`Alt+F2` でも操作可能）。 |
| `sysctl hw.sensors.simplebat0` | バッテリー電圧・充電状態・残量パーセント（`percent0`）を表示。 |
| `sysctl -n hw.sensors.simplebat0.percent0` | バッテリー残量パーセントのみを取得（例: `96.00%`）。 |
| `sysctl hw.cpuspeed` | 現在の CPU 動作クロック周波数を表示（単位: MHz、最大 1200 MHz）。 |
| `sysctl hw.perfpolicy` / `hw.setperf` | CPU 制御ポリシー（`auto`/`high`）およびクロック比率（0〜100%）を確認。 |
| `doas rcctl [start\|stop\|restart\|check] pomera_lid_watch` | 蓋開閉省電力デーモンの起動・停止・再起動・ステータス確認。 |
| `doas rcctl set pomera_lid_watch flags "-i 2.0 -p auto"` | 蓋検知間隔（秒）や蓋オープン時の CPU ポリシーを変更。 |
| `doas rcctl [start\|stop\|restart\|check] pomera_power_led` | バッテリーLEDインジケーター（充電中橙、満充電緑、残量低下赤）の常駐監視デーモン。 |
| `doas rcctl [start\|stop\|restart\|check] pomera_wifi_watch` | Wi-Fiリンク監視＆リンク切断時の自動再接続常駐デーモン。 |
| `doas pomera-wifi-reconnect` | Wi-Fi（`bwfm0`）インターフェースを再起動してDHCPを再取得。 |
| `doas pomera-suspend` | SoC/PLLを休止してサスペンドへ移行（電源ボタンや蓋開閉で復帰）。 |
| `doas gpioctl gpio1 red_led 1` / `green_led 1` | 前面の赤/緑ステータスLEDを手動で点灯・消灯（`0` で消灯）。 |

### CUI ワークスペース＆ネットワーク

| コマンド | 説明 |
| :--- | :--- |
| `pomera-setup-workspace` | ワークスペース環境（Vim、tmux、mlterm-fb、Noto CJK、dotfiles）のセットアップ・再初期化。 |
| `pomera-setup-japanese` | CUI日本語入力システム (mlterm 内蔵 SKK 直接インライン変換) のセットアップ。 |
| `pomera-font [udev\|moraler\|noto]` | ターミナルフォント（斜線ゼロ入り UDEV Gothic、Moralerspace、Noto）を切り替え。 |
| `doas pomera-bt-pan connect <BD_ADDR>` | *(実験的)* スマホのBluetoothテザリング（PAN）接続スクリプト（※要4noha氏のpanctlデーモン、実機未検証）。 |

### 🔧 ホストPC側での診断・シミュレーターツール (上級者・開発向け)

> [!NOTE]
> 以下のツールは `make_sdcard.sh` が内部で自動的に呼び出すため、通常のインストール作業でユーザーが手動実行する必要はありません。トラブルシューティングや個別検証を行いたい場合にご利用ください。

| ツール | 説明 |
| :--- | :--- |
| `sudo python3 scripts/inspect_sd.py /dev/rdiskN` | 作成したSDカードのMBR、ブートローダーセクタ（LBA 64/16384）、Disklabelを物理検査。 |
| `python3 scripts/inspect_kernel.py [kernel]` | カーネルバイナリが DM250 スマートカーネルか、USB/X11キー/mlterm-fb/Bluetooth修正を含むかを自動監査。 |
| `python3 scripts/build_kernel_qemu.py [--config DM250]` | QEMU ネイティブVM上でパッチ適用（USB, X11キー, mlterm-fb, BT）・軽量特化カーネル（`DM250` / `GENERIC`）を自動ビルド。 |
| `scripts/build_uboot.sh` | DM250向けの自動起動 U-Boot バイナリ（`uboot.img`）を単体ビルド。 |
| `scripts/run_qemu.sh [image_path]` | 実機に挿す前に、作成したイメージをローカルPC（Mac/Linux）のQEMUシミュレータで起動テスト。 |

---

## 🤝 謝辞・クレジット

本プロジェクトは、以下の先行研究、オープンソースソフトウェア、および開発成果を参照・利用しています。

- **Joshua Stein (jcs) 氏**: [Installing OpenBSD on the Pomera DM250](https://jcs.org/2026/04/09/openbsd-dm250) — DM250 向け OpenBSD カーネル、U-Boot、LVDS ドライバ、および AP6212 NVRAM 設定の開発。
- **4noha 氏**: [openbsd-pomera-dm250](https://github.com/4noha/openbsd-pomera-dm250) — クロスビルド手順、実機向けカーネルパッチ（AP6212A BT初期化、rkdrm SMODE対応）、mlterm-fb 最適化パッチ、バッテリー・蓋開閉制御スクリプト、Bluetooth PAN 研究。
- **ARAKI Ken 氏**: [mlterm](https://github.com/arakiken/mlterm) — 多言語端末エミュレータ。フレームバッファ直描画版（`mlterm-fb`）および内蔵 SKK IME エンジン。
- **ichinomoto 氏**: [EKESETE.net](https://www.ekesete.net/log/?p=9504) — DM200 / DM250 向け Debian rootfs、ハードウェア解析、および eMMC バックアップ手順の確立。
- **yuru7 氏**: [UDEV Gothic](https://github.com/yuru7/udev-gothic) / [Moralerspace](https://github.com/yuru7/moralerspace) — プログラミング向け日本語フォント（SIL Open Font License 1.1）。
- **Google LLC / Noto Fonts プロジェクト**: [Noto Sans CJK](https://github.com/notofonts/noto-cjk) — 日本語等幅フォント（SIL Open Font License 1.1）。
- **OpenBSD プロジェクト**: [OpenBSD](https://www.openbsd.org/) — 基本オペレーティングシステムおよびインストーラー基盤。

---

## ⚠️ 免責事項・商標について

- 「Pomera」および「ポメラ」は、King Jim（株式会社キングジム）の登録商標です。
- 本プロジェクトは個人有志による非公式の研究・開発成果であり、King Jim（株式会社キングジム）とは一切関係ありません。本ソフトウェアおよび手順に関して、**メーカー（King Jim）へのお問い合わせは固くお断りいたします**。
- 本ソフトウェアの使用や導入に伴い生じた機器の故障、データの破損・消失、メーカー保証の失効などについて、作者およびプロジェクト貢献者は一切の責任を負いかねます。すべて自己責任の上でご利用ください。

---

## 📄 ライセンス

[MIT License](LICENSE)
