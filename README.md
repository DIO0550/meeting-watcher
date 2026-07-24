# meeting-watcher

macOS のマイク・カメラ利用状態を監視し、会議中かどうかを判定するための Swift アプリケーションです。

## Project structure

- `meeting-watcher.xcworkspace`: 開発時に開く Xcode workspace
- `meeting-watcher/meeting-watcher.xcodeproj`: macOS アプリ本体とテストターゲットを含む Xcode project
- `meeting-watcher/meeting-watcher`: アプリ本体の SwiftUI ソース
- `meeting-watcher/meeting-watcherTests`: ユニットテスト
- `meeting-watcher/meeting-watcherUITests`: UI テスト
- `meeting-watcher/MeetingWatcher`: 監視コアの public module (`MeetingWatcher.framework`)
- `meeting-watcher/MeetingWatcherTests`: `MeetingWatcher` の public boundary と依存方向のテスト
- `meeting-watcher/MeetingSignal`: `MeetingWatcher` に依存する通知層の public module (`MeetingSignal.framework`)
- `meeting-watcher/MeetingSignalTests`: `MeetingSignal` の public boundary テスト
- `scripts/check-meeting-watcher-dependency.sh`: `MeetingWatcher` から `MeetingSignal` への逆方向依存を検出する通常ビルドphase用スクリプト

## Build verification

前提:

- macOS
- Xcode がインストールされ、`xcodebuild` を実行できること
- Xcode の Command Line Tools が選択されていること
- `meeting-watcher` scheme が共有済みであること
  - `xcodebuild -list` で scheme が表示されない場合は、Xcode で `meeting-watcher.xcworkspace` を開き、`Product > Scheme > Manage Schemes...` から `meeting-watcher` の `Shared` を有効にする

依存方向だけを検証する:

```sh
bash scripts/check-meeting-watcher-dependency.sh
```

期待結果:

- 終了コード `0` で、エラーが表示されない

利用可能な scheme を確認する:

```sh
xcodebuild -list -workspace meeting-watcher.xcworkspace
```

期待結果:

- `meeting-watcher` scheme が表示される

アプリをビルドする:

```sh
xcodebuild \
  -workspace meeting-watcher.xcworkspace \
  -scheme meeting-watcher \
  -destination 'platform=macOS' \
  build
```

期待結果:

- `** BUILD SUCCEEDED **` が表示される
- `meeting-watcher` macOS アプリターゲットがビルドされる
- `MeetingWatcher.framework` と `MeetingSignal.framework` がビルドされる
- `MeetingSignal` から `MeetingWatcher` への片方向依存が解決される
- `MeetingWatcher` / `MeetingWatcherTests` から `MeetingSignal` への直接依存がないことを通常ビルド内で確認する

テストを実行する:

```sh
xcodebuild \
  -workspace meeting-watcher.xcworkspace \
  -scheme meeting-watcher \
  -destination 'platform=macOS' \
  test
```

期待結果:

- `** TEST SUCCEEDED **` が表示される
- `meeting-watcherTests`、`meeting-watcherUITests`、`MeetingWatcherTests`、`MeetingSignalTests` が実行される
