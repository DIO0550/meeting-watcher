# meeting-watcher

macOS のマイク・カメラ利用状態を監視し、会議中かどうかを判定するための Swift アプリケーションです。

## Project structure

- `meeting-watcher.xcworkspace`: 開発時に開く Xcode workspace
- `meeting-watcher/meeting-watcher.xcodeproj`: macOS アプリ本体とテストターゲットを含む Xcode project
- `meeting-watcher/meeting-watcher`: アプリ本体の SwiftUI ソース
- `meeting-watcher/meeting-watcherTests`: ユニットテスト
- `meeting-watcher/meeting-watcherUITests`: UI テスト

## Build verification

前提:

- macOS
- Xcode がインストールされ、`xcodebuild` を実行できること
- Xcode の Command Line Tools が選択されていること

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
- `meeting-watcherTests` と `meeting-watcherUITests` が実行される
