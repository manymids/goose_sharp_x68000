# Goose Sharp X68000

Goose 言語で CPU・メモリ・周辺機器・描画を実装した、Windows 向けの Sharp X68000 エミュレータです。Win32 GUI と、stdio 経由で外部ツールから操作する ARCL MCP に対応します。`arcl_windows_x68k` からの移植を基に開発しています。

互換性は開発中です。超連射68KとフロッピーなしのX68000版Doomで起動・保存復帰を検証していますが、すべてのソフトや実機の動作を保証するものではありません。BIOS・CG-ROM・OS・ゲーム・ディスクイメージは同梱しません。

## 配布構成

このフォルダはソース配布用の構成です。ビルド済みexe、BIOS、媒体イメージ、開発用テスト・計測ツールは含まれていません。

```text
goose_sharp_x68000/
  README.md
  THIRD_PARTY_NOTICES.md
  .gitignore
  src/
    main.goose           起動・GUI・ARCLの入口
    main.build           C/C++ソースとWin32ライブラリの指定
    m68k_*.goose          CPU・MMU
    mcp_server.goose      ARCL MCP
    x68k_*.goose          機器・描画・保存・共有サービス
    x68k_bridge.c/.h      Win32・ファイル・音声出力
    x68k_config.c/.h      GUI設定の読込・保存
    sound/               FMGEN・ADPCM・音源接続
```

以下の起動例は、プロジェクトのルートにexeをビルドし、このルートをカレントディレクトリにする前提です。`src` はソースの配置先であり、通常の実行用ディレクトリにはしません。

## 最初の起動

Windows の x64 環境を対象にしています。まず後述の手順で `src/main.goose` をビルドし、プロジェクトのルートに `arcl_windows_x68k_goose.exe` を作成してください。別途配布されたexeがある場合も、同じ配置で使用できます。

起動時の**カレントディレクトリ**に `keropi` フォルダを用意します。exe の場所とカレントディレクトリが異なる場合も、この基準は変わりません。

```text
goose_sharp_x68000/
  src/                         配布済みのソース
  arcl_windows_x68k_goose.exe   ビルド後に作成
  arcl_windows_x68k_goose.ini   GUI実行時に作成
  keropi/
    iplrom.dat     必須: 131,072 bytes（128 KiB）
    cgrom.dat      必須: 786,432 bytes（768 KiB）
    sram.dat       任意: 16,384 bytes（16 KiB）
```

ROM はご自身で使用権限を確認して用意してください。`sram.dat` は未配置でも起動でき、正常終了時に BIOS ディレクトリへ保存します。RAM は12MB固定で、SRAM内のRAM容量情報もこれに合わせます。

PowerShell でこのフォルダへ移動して起動します。

```powershell
Set-Location C:\work\goose_sharp_x68000
.\arcl_windows_x68k_goose.exe
```

初回は **FD0・FD1・HDDとも未指定**です。特定のゲームや隣のプロジェクトを探索して自動挿入することはありません。GUIのディスクメニューからイメージを選択してください。初期設定は10MHz、表示倍率1倍、初期表示幅768です。

別の BIOS ディレクトリや、起動用ディスクを直接指定することもできます。

```powershell
.\arcl_windows_x68k_goose.exe --system-dir C:\MyROMs\keropi C:\Disks\boot.xdf
.\arcl_windows_x68k_goose.exe --clock 16 C:\Disks\system.hdf
```

## GUIの操作

| メニュー・キー | 操作 |
|---|---|
| File → Reset / F5 | 機械をリセットし、GUIでは実行を再開 |
| FD0 → Open / Eject | 起動側フロッピーを挿入・取り出し。挿入成功時はリセット |
| FD1 → Open / Eject | 2台目のフロッピーを挿入・取り出し |
| HDD → Open / Eject | SASI HDDを挿入・取り出し。挿入成功時はFDを両方取り出してリセット |
| View → 1x / 2x Scale | ウィンドウの表示倍率 |
| View → Initial Screen | 初期表示サイズ768×512 / 512×512の設定 |
| Clock | CPUクロックを変更 |
| Esc / Alt+F4 | GUIを終了 |

画面の実際の解像度は、ゲスト側のCRTC設定により起動後も変化します。Initial Screen は初期表示の設定であり、ゲストの映像モードを固定する機能ではありません。

キーボード入力に加え、方向キーと `Z` / `X`、Space / Enter を1ポート目のジョイパッド入力に対応させています。マウス/SCCは未対応です。

## GUI設定の保存と優先順位

通常GUIは、カレントディレクトリの `arcl_windows_x68k_goose.ini` を読み込みます。クロック・表示・ディスクをメニューで変更したときと、正常終了時に設定を保存します。

保存するのは BIOSディレクトリ、FD0・FD1・HDDの選択、クロック、倍率、初期表示幅です。ディスクの取り出しも保存されます。ディスクが移動・削除されて読み込めない場合は、警告してその媒体なしで起動します。

通常GUIの優先順位は、**明示した起動引数 → 保存済みGUI設定 → 初期値**です。

- ディスクを引数で指定すると、保存済み媒体をすべて無視し、そのディスクだけで起動します。
- `--no-disk` は保存済み媒体をすべて無視して空の状態で起動します。
- `--clock` / `--system-dir` / `--scale` / `--mode` は、それぞれ保存済みの値より優先します。
- 通常GUIで使った最終設定は、次回GUI起動用に保存されます。
- **ARCL（`--mcp`）とヘッドレス（`--no-window`）はGUI設定を読み書きしません。** 起動引数とARCL操作が優先され、GUIで最後に使ったクロックやディスクに影響されません。

設定例です。自動保存されるパスは絶対パスです。手動編集した相対パスは、起動時のカレントディレクトリを基準に解決します。BIOSの場所はこの項目か `--system-dir` で変更できます。

```ini
[gui]
version=1
clock_mhz=10
scale=1
screen_width=768
bios_dir=.\keropi
fd0=
fd1=
hdd=
```

初期化したい場合は、アプリを終了してからINIを別名へ退避してください。設定保存は一時ファイルへの書き込み後に置換し、書き込みに失敗した場合は既存設定を残します。書き込み権限のあるカレントディレクトリを使用してください。

## 対応内容

| 項目 | 実装・範囲 |
|---|---|
| CPU / RAM | Motorola 68000、RAM 12MB固定 |
| クロック | 10 / 16 / 25 / 50 / 75 / 100 / 150 / 200 / 250 MHz |
| 映像 | TVRAM/GVRAM、CRTC、パレット、スプライト、BG、面の合成 |
| 周辺機器 | MFP、FDC、DMAC、SASIの実装 |
| フロッピー | FD0・FD1、raw `.2HD` / `.xdf`、DIM、D88。rawイメージとして `.img` / `.bin` も選択可能 |
| HDD | SASI、`.hdf` / `.hds`、最大40MiB。GUIのHDDメニューでは `.img` も選択可能 |
| 音声 | YM2151 / ADPCMの合成、Win32 waveOut出力 |
| 画面保存 | BMP出力 |
| 保存状態 | 同一プロセス内の通常スロット・名前付きsnapshot・rewind |

コマンドラインのディスク引数では `.hdf` / `.hds` をHDDとして、それ以外をフロッピーとして扱います。ディスクへのゲスト書き込みはメモリ上で保持し、元のイメージファイルへ書き戻しません。GUI設定が記憶するのは媒体の選択であり、次回起動時はファイルから読み直します。

## ARCL MCP

stdio対応のMCPクライアントから、次のように起動します。初期状態は一時停止です。`arcl_run` で指定フレーム数を実行するか、`arcl_resume` で継続実行します。

```powershell
.\arcl_windows_x68k_goose.exe --mcp --no-window --system-dir C:\work\goose_sharp_x68000\keropi
```

クライアント登録の例です。`command` と `--system-dir` を使用環境の絶対パスへ変更してください。媒体の指定は任意です。

```json
{
  "mcpServers": {
    "x68000": {
      "command": "C:\\work\\goose_sharp_x68000\\arcl_windows_x68k_goose.exe",
      "args": ["--mcp", "--no-window", "--system-dir", "C:\\work\\goose_sharp_x68000\\keropi"]
    }
  }
}
```

標準入力・標準出力には改行区切りのJSON-RPCを使用し、診断は標準エラーへ出力します。`--no-window` を外すと、ARCL接続と画面表示を併用できます。その場合もGUI設定ファイルは使用しません。

既定で公開するレイヤーは L0 と L1 です。デバッグ・機器観測・snapshot等を使う場合は `--mcp-layers all`、または `l0,l1,l2` のように指定します。実行制御・通常保存の基本ツールはレイヤー指定によらず利用できます。

| 分類 | 主なツール |
|---|---|
| 実行制御 | `arcl_status`、`arcl_run`、`arcl_pause`、`arcl_resume`、`arcl_reset` |
| 入力・画面（L0） | `arcl_key`、`arcl_type`、`arcl_joypad`、`arcl_clear_input`、`arcl_input_state`、`arcl_input_macro`、`arcl_screenshot` |
| コンソール（L1） | `arcl_console_read`、`arcl_command`、`arcl_mount` |
| デバッグ（L2） | `arcl_registers`、`arcl_read_mem`、`arcl_write_mem`、`arcl_step`、`arcl_breakpoint`、`arcl_disasm` |
| 機器観測（L3） | `arcl_video`、`arcl_irq`、`arcl_dma`、`arcl_vram`、`x68k_opm` |
| 保存 | `arcl_save_state`、`arcl_load_state`、`arcl_snapshot` / `arcl_rewind`（L4） |

正確な公開ツールと引数は接続先の `tools/list` で確認できます。通常保存は0〜9の10スロット、名前付きsnapshotは最大32件、rewindは8件です。これらはメモリ上の保存で、終了後のファイル再開には対応していません。

成功した復元は一時停止し、古いホスト入力・再生待ち音声・派生画面を無効にします。保存済みMFPキューとジョイパッド値は機械状態として復元します。新しい画面が必要な場合は次のフレームを実行してください。PCブレーク等によるフレーム途中からの完全再開は保証しません。

## コマンドライン

```text
arcl_windows_x68k_goose.exe [options] [disk-image]
```

| オプション | 意味 |
|---|---|
| `--system-dir PATH` | BIOSディレクトリ。初期値は `カレント\keropi` |
| `--clock MHZ` | CPUクロック。初期値10 |
| `--scale 1\|2` | 初期ウィンドウ倍率 |
| `--mode 512\|768` | 初期表示幅。`512x512` / `768x512` も指定可能 |
| `--no-disk` | 保存済み媒体を無視して空で起動 |
| `--mcp` | ARCL MCPを有効化。GUI設定は不使用 |
| `--mcp-layers LIST` | 公開するレイヤー。例: `all`、`l0,l1,l2` |
| `--no-window` | ウィンドウを開かない。GUI設定は不使用 |
| `--frames N` | 通常実行をNフレームで終了。ARCLでは使用しない |
| `--dump-frame PATH` | 通常実行のBMP保存先。拡張子は `.bmp` を推奨 |
| `--dump-after-frames N` | 画面保存するフレーム。初期値1200 |
| `--ram N` | 互換用に受理するが、RAMは12MB固定 |
| `--help` / `-h` | ヘルプを表示して終了 |

ヘッドレスで一定フレームを実行し、画面を保存する例です。ARCL以外で `--no-window` を使う場合は、`--frames` または `--dump-frame` が必要です。

```powershell
.\arcl_windows_x68k_goose.exe --no-window --system-dir .\keropi `
  --frames 1200 --dump-frame screen.bmp .\Disks\boot.xdf
```

## ソースからのビルド

Gooseコンパイラ・標準ライブラリと、MSVCのC/C++ビルド環境・Windows SDKが必要です。Gooseコンパイラはこのソース配布に含まれていません。MSVCのコマンドが利用できる開発用PowerShell等で、**プロジェクトのルート**から実行します。

```powershell
Set-Location C:\work\goose_sharp_x68000
goose build .\src\main.goose -o .\arcl_windows_x68k_goose.exe
```

デバッグビルドは別名にします。

```powershell
goose build .\src\main.goose --debug -o .\arcl_windows_x68k_goose_debug.exe
```

Gooseがソースと同じフォルダの [src/main.build](src/main.build) を使用します。`c_sources` と `c_include` の相対パスはこの配置を前提としているため、`src` 内のファイルと `sound` フォルダはまとめて維持してください。C/C++部分は `src/x68k_bridge.c`、`src/x68k_config.c`、`src/sound/` です。

`-o` でexeをプロジェクトのルートへ出力することで、実行時の `keropi` とINIの場所も分かりやすくなります。`src` 内にexeを置いた場合でも、BIOSやINIの基準はexeの場所ではなく、起動時のカレントディレクトリです。

この公開用構成には、元の開発ツリー用 `tools/architecture/build.ps1` は含まれていません。ここでは上記のGooseコマンドを使用してください。

## 実装と検証の範囲

| 配置 | 担当 |
|---|---|
| [src/main.goose](src/main.goose) | 起動引数・GUI/ARCLのイベントループ |
| `src/m68k_*` | CPU命令・MMU |
| `src/x68k_mfp/fdc/dmac/sasi.goose` | 周辺機器 |
| [src/x68k_ppu.goose](src/x68k_ppu.goose) | 走査線・描画合成 |
| [src/x68k_emu.goose](src/x68k_emu.goose) | フレーム進行と共通リセット |
| [src/x68k_state.goose](src/x68k_state.goose) | 通常保存・snapshot・rewindの共通保存 |
| [src/x68k_session.goose](src/x68k_session.goose) / [src/x68k_input.goose](src/x68k_input.goose) | フロントエンド共通の実行制御と入力 |
| [src/mcp_server.goose](src/mcp_server.goose) | JSON-RPCの解析・公開ツール・応答 |
| [src/x68k_config.c](src/x68k_config.c) | GUI用INI。機械の保存状態とは独立 |
| `src/x68k_bridge.c` / `src/sound/` | Win32・ファイル・音声デバイスと合成 |

元の開発ツリーではrelease/debugのCPU・機器・保存・寿命管理・設定のテストと、超連射68K・Doomの起動および保存復帰を確認しています。設定については、ARCLとの分離、CLIの優先、初回空起動、書き込み失敗時の既存INI維持も検証しています。

**この公開用構成には `test_*.goose`、対応するテスト用 `.build`、`tools/architecture/`、開発用 `ARCHITECTURE_*.md` は含まれていません。** 記載した検証は元の開発ツリーで実施した結果で、このフォルダだけで同じ自動テストを再実行できるという意味ではありません。

## 困ったとき・既知の制限

- BIOSが見つからない場合は、カレントディレクトリと `keropi` の位置、ファイル名・サイズを確認してください。`--system-dir` の絶対パス指定でも切り分けできます。別プロジェクトやexeの隣のROMへ自動でフォールバックしません。
- 意図しないディスクでGUIが起動する場合は、`--no-disk` で起動するか、終了後にINIを退避してください。ARCLではINIは読みません。
- 音声デバイスが使用できない場合は警告して無音で実行します。
- 現在のファイルダイアログ・パス処理にはWin32の文字コード・`MAX_PATH`の制約があります。パスに問題が出る場合は、短い英数字のフォルダで確認してください。
- 単一の登録中機械を前提としています。複数インスタンスのコア共有、セーブ状態の永続化、マウス、すべてのVRAMモード・ソフトの完全互換は未対応または未保証です。

不具合報告には、ビルド種別、Windows環境、起動引数、イメージ形式、再現操作、ログや画面を添えてください。BIOSやゲーム本体を添付する必要はありません。

## 由来・権利情報

移植元と音源コードの由来は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、同梱のFMGEN説明・条件の原文は [src/sound/fmgen-readme.txt](src/sound/fmgen-readme.txt) を参照してください。Gooseコンパイラ自体のライセンスと、エミュレータに含まれる移植元・第三者コードの条件は区別してください。

BIOS・CG-ROM・OS・ゲーム・ディスクイメージの権利は各権利者に帰属します。ソースコードの配布物にはこれらの実データや個人のSRAM・設定を含めません。
