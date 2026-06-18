# pi_slideshow

Raspberry Pi で画像フォルダをフルスクリーンスライドショー表示するためのシンプルなスクリプトです。  
起動時にフォルダを選び、一定間隔で画像をランダム表示します。

## 特徴

- フォルダ選択ダイアログで表示対象を指定
- 画像を自動リサイズして全画面表示
- ランダム再生
- 画面のスリープ/消灯を抑止
- 画像が追加・削除されてもループ再読込で追従
- 起動場所に応じてビューアを自動切替（TTY: `fbi` / GUI: `mpv`）
- 画像表示に連続失敗した場合はプロセスを残さず安全終了
- GUIモード実行中に画像が追加・削除された場合、一覧を自動更新

## ファイル構成

- `slideshow.sh` : スライドショー本体
- `slideshow.desktop` : デスクトップランチャー定義
- `install.sh` : スクリプト配置と `.desktop` 更新を自動化

## 動作要件

- Raspberry Pi OS (Debian 系 Linux)
- X セッション (GUI)
- Linux 仮想コンソール (`/dev/tty1` など) で実行できること
- 以下コマンドが利用可能であること
  - `fbi`
  - `mpv` (GUI モードで推奨)
  - `zenity`
  - `xset`
  - `setterm`

インストール例:

```bash
sudo apt update
sudo apt install -y fbi mpv zenity x11-xserver-utils util-linux
```

`slideshow.sh` は TTY を利用するため、`pi` ユーザーが `tty` グループに所属していない場合は先に追加してください。

```bash
sudo usermod -aG tty pi
```

反映には再ログイン（または再起動）が必要です。

## 使い方

通常は `install.sh` の実行だけでセットアップできます。

### 1. インストールを実行
```bash
./install.sh
```

これで次が自動実行されます。

- `slideshow.sh` を既定の配置先 `~/.local/share/pi_slideshow` へコピー
- `.desktop` の `Exec` を実際の配置先に書き換え
- アプリメニュー用 `.desktop` を `~/.local/share/applications/pi-slideshow.desktop` へ配置

### 2. アプリメニューから起動

インストール後はアプリメニューの「スライドショー」から起動できます。
初回起動時にフォルダ選択ダイアログが開きます。
GUI 起動時は `mpv` を使用します。`mpv` が未インストールの場合は安全終了します。TTY 起動時は `fbi` を使用します。

GUI モードの `mpv` は Wayland 環境向けに、`--gpu-context=wayland` と `--hwdec=no` を指定して起動します。
実行中に画像フォルダへ追加・削除があった場合は変更を検知して `mpv` を再起動し、新しい一覧を反映します。
スライドショーはプレイリストを繰り返し再生し、`q` で終了できます。
メモリ使用量を抑えるため、`mpv` はキャッシュ無効化とデマルチプレクサバッファ上限（`8MiB` / `4MiB`）を指定しています。

### 3. （必要なら）自動起動を有効化

```bash
mkdir -p ~/.config/autostart
cp ~/.local/share/applications/pi-slideshow.desktop ~/.config/autostart/
```

## mpv の操作方法（GUIモード）

GUIモードでは `mpv` のキーボード操作が使えます。主なキーは以下です。

- `q` : 終了
- `Space` : 一時停止 / 再開
- `Right` : 次の画像へ
- `Left` : 前の画像へ
- `f` : フルスクリーン切替
- `m` : ミュート切替（動画再生時）

補足:

- 本スクリプトは画像スライドショー用途のため、再生中は `--image-display-duration` で自動送りしています。
- `q` で `mpv` を閉じると、スクリプト全体も終了します。

## カスタマイズ

`slideshow.sh` 内の以下を変更すると挙動を調整できます。

- `DURATION=10` : 1枚あたりの表示秒数
- `TTY_DEV="/dev/tty1"` : 表示先 TTY

## トラブルシュート

- ダイアログが表示されない
  - `zenity` がインストールされているか確認
- 画像が表示されない
  - 選択フォルダに画像ファイルがあるか確認
  - `fbi` の実行権限や表示先 TTY を確認
  - このスクリプトは Linux 仮想コンソール (`/dev/ttyN`) での実行が必要です
  - `tty` コマンドが `/dev/tty1` などを返す端末で実行してください（`/dev/pts/*` は不可）
  - `Ctrl + Alt + F1` で `tty1` を確認（環境により `F2` など別TTYの場合あり）
  - `fbi` が短時間終了を連続するとスクリプトは安全終了します
- 画面が消灯する
  - `xset` が利用可能なディスプレイ `:0` で動作しているか確認
- アプリメニューに表示されない
  - `./install.sh` を再実行
  - 反映コマンドを手動実行

```bash
update-desktop-database ~/.local/share/applications
xdg-desktop-menu forceupdate
```

  - それでも表示されない場合はログアウト/ログイン（必要なら再起動）

## ログ

実行ログは以下に保存されます。

- `~/.local/state/pi_slideshow/slideshow.log`

確認例:

```bash
tail -f ~/.local/state/pi_slideshow/slideshow.log
```

## 補足

このスクリプトはシンプルさを重視した構成です。必要に応じて、対象拡張子の絞り込みやログ出力などを追加してください。
