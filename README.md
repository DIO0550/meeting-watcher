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

## CoreAudio microphone manual verification

検証時は `MeetingWatcher.start()` を呼び出し、非同期のHAL処理完了後に届く購読イベントまたは `snapshot()[.microphone]` を確認する。`start()` の返却直後は更新前の場合がある。終了時は `stop()` を呼び出す。

- [ ] 内蔵マイクを入力に選び、録音または通話を開始すると `.active`、終了すると `.inactive` になる
- [ ] 有線マイクを接続するとデバイス追加が反映され、そのマイクの利用開始・終了で集約状態が変わる
- [ ] 有線マイクを利用中に取り外してもクラッシュせず、残りの入力デバイスから状態が再集約される
- [ ] Bluetoothマイクを接続して利用し、実際の `.active` / `.inactive` とカメラシグナルを記録する（下記の既知制約により `.active` は必須条件としない）
- [ ] Bluetoothマイクの切断・再接続やプロファイル切替時に、トポロジー変更後も監視が継続する
- [ ] 複数の入力デバイスがある場合、1台でも稼働中なら `.active`、全台停止中なら `.inactive` になる
- [ ] 監視開始後にHAL操作が成功して入力デバイスが0台の場合は `.inactive` になる。開始前・停止後・HAL/listener操作失敗時は `.unknown` になる
- [ ] 入出力兼用デバイスで出力だけを利用した場合、実際のマイク利用と判定結果を記録する
- [ ] 監視中の列挙・listener登録・状態read失敗で `.unknown` になった後、追加のデバイスイベントがなくてもbackoff retryで既知状態へ回復する
- [ ] `stop()` 中のlistener解除失敗は後続の `stop()` / `start()` で再試行される
- [ ] `stop()` 後はデバイス変更で新しいイベントが届かず、再度 `start()` すると監視が回復する

macOSでは、Bluetooth入力を実際に利用中でも `kAudioDevicePropertyDeviceIsRunningSomewhere` が `false` のままになる既知の挙動があり、本シグナルは `.inactive` を返す場合がある。これは一時的な `.unknown` ではなく偽陰性として残り得るため、カメラシグナルを補完情報として利用する。また、入出力兼用（duplex）デバイスでは出力だけの利用でも同プロパティが `true` となり、偽陽性の `.active` になる可能性がある。

## CoreMediaIO camera manual verification

検証時はシステム設定で対象アプリのカメラ権限を確認してから `MeetingWatcher.start()` を呼び、非同期のCoreMediaIO処理完了後に届く購読イベントまたは `snapshot()[.camera]` を確認する。`start()` の返却直後は更新前の場合がある。終了時は `stop()` を呼び出す。

- [ ] Zoomでカメラをオンにすると `.active`、オフにすると `.inactive` になる
- [ ] Microsoft Teamsでカメラをオン・オフし、状態が追従する
- [ ] Google Meetを利用するブラウザでカメラをオン・オフし、状態が追従する
- [ ] 会議へカメラオフで参加した場合は `.inactive` のままであることを確認し、会議参加そのものは検出できない制約として扱う
- [ ] カメラ権限を拒否・後から許可した場合にクラッシュせず、`.unknown` または列挙可能なデバイスの集約状態となることを記録する
- [ ] USBカメラの接続・取り外しがhot-plugとして反映され、利用中の取り外し後も残りのカメラから再集約される
- [ ] 複数カメラがある場合、1台でも稼働中なら `.active`、全台停止中なら `.inactive` になる
- [ ] 仮想カメラを利用し、列挙・running state・provider停止時のhot-plug挙動を記録する
- [ ] Continuity Cameraを接続・利用・切断・再接続し、無線デバイスの出現消失後も監視が継続する
- [ ] 監視開始後にCMIO操作が成功してカメラデバイスが0台の場合は `.inactive` になる。開始前・停止後・CMIO/listener操作失敗時は `.unknown` になる
- [ ] 監視中の列挙・listener登録・状態read失敗で `.unknown` になった後、追加イベントがなくてもbackoff retryで既知状態へ回復する
- [ ] `stop()` 後はデバイス変更で新しいイベントが届かず、再度 `start()` すると監視が回復する

`kCMIODevicePropertyDeviceIsRunningSomewhere` が表すのはカメラストリームの利用状態であり、会議への参加状態ではない。そのため、カメラオフ参加は未参加と区別できず `.inactive` となる。カメラ権限、仮想カメラのprovider実装、Continuity Cameraの接続状態によって、デバイスの列挙可否・出現タイミング・running stateは異なる。本シグナル単独で会議参加を断定せず、マイクやプロセス・ウィンドウのシグナルと組み合わせる。

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
