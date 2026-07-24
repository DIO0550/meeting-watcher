import Foundation

/// 監視対象の観測結果を公開するインメモリの生シグナルソースです。
@MainActor
public final class MeetingWatcher: SignalSource {
    public typealias Snapshot = SignalSnapshot
    public typealias Listener = @MainActor @Sendable (SignalKind, RawSignalState) throws -> Void
    public typealias Unsubscribe = @MainActor @Sendable () -> Void

    private var states: Snapshot
    private var listeners: [UUID: Listener]
    private let coreAudioBackend: (any CoreAudioBackend)?
    private let coreMediaIOBackend: (any CoreMediaIOBackend)?
    private let now: CoreAudioMicrophoneMonitor.Clock
    private let coreAudioExecutor: SerialCoreAudioAsyncExecutor
    private let coreMediaIOExecutor: SerialCoreMediaIOAsyncExecutor
    private let coreAudioRefreshRetryScheduler: any CoreAudioRefreshRetryScheduling
    private let coreMediaIORefreshRetryScheduler: any CoreMediaIORefreshRetryScheduling
    private var microphoneMonitor: CoreAudioMicrophoneMonitor?
    private var cameraMonitor: CoreMediaIOCameraMonitor?

    public init() {
        states = Self.makeInitialSnapshot()
        listeners = [:]
        coreAudioBackend = SystemCoreAudioBackend()
        coreMediaIOBackend = SystemCoreMediaIOBackend()
        now = { Date() }
        coreAudioExecutor = SerialCoreAudioAsyncExecutor()
        coreMediaIOExecutor = SerialCoreMediaIOAsyncExecutor()
        coreAudioRefreshRetryScheduler = DispatchCoreAudioRefreshRetryScheduler()
        coreMediaIORefreshRetryScheduler = DispatchCoreMediaIORefreshRetryScheduler()
    }

    init(
        coreAudioBackend: (any CoreAudioBackend)? = nil,
        coreMediaIOBackend: (any CoreMediaIOBackend)? = nil,
        now: @escaping CoreAudioMicrophoneMonitor.Clock = { Date() },
        coreAudioExecutor: SerialCoreAudioAsyncExecutor = SerialCoreAudioAsyncExecutor(),
        coreMediaIOExecutor: SerialCoreMediaIOAsyncExecutor = SerialCoreMediaIOAsyncExecutor(),
        coreAudioRefreshRetryScheduler: any CoreAudioRefreshRetryScheduling = DispatchCoreAudioRefreshRetryScheduler(),
        coreMediaIORefreshRetryScheduler: any CoreMediaIORefreshRetryScheduling = DispatchCoreMediaIORefreshRetryScheduler()
    ) {
        states = Self.makeInitialSnapshot()
        listeners = [:]
        self.coreAudioBackend = coreAudioBackend
        self.coreMediaIOBackend = coreMediaIOBackend
        self.now = now
        self.coreAudioExecutor = coreAudioExecutor
        self.coreMediaIOExecutor = coreMediaIOExecutor
        self.coreAudioRefreshRetryScheduler = coreAudioRefreshRetryScheduler
        self.coreMediaIORefreshRetryScheduler = coreMediaIORefreshRetryScheduler
    }

    public func snapshot() -> Snapshot {
        states
    }

    @discardableResult
    public func subscribe(_ listener: @escaping Listener) -> Unsubscribe {
        let id = UUID()
        listeners[id] = listener

        return { [weak self] in
            self?.listeners.removeValue(forKey: id)
        }
    }

    /// CoreAudioのマイクとCoreMediaIOのカメラ利用状態監視を開始します。
    ///
    /// HAL処理は専用executorで非同期に行うため、返却直後のsnapshotは更新前の場合があります。
    /// 既に開始済みの場合はlistenerを重複登録せず、現在状態を再取得します。cleanup・列挙・
    /// listener登録・状態readに失敗した場合はunknownを公開し、単一のbackoff timerで未解決の
    /// device refreshまたは完全なtopology reconciliationを外部イベントなしで自動再試行します。
    public func start() {
        if microphoneMonitor == nil, let coreAudioBackend {
            microphoneMonitor = CoreAudioMicrophoneMonitor(
                backend: coreAudioBackend,
                executor: coreAudioExecutor,
                refreshRetryScheduler: coreAudioRefreshRetryScheduler,
                now: now
            ) { [weak self] state in
                self?.applySignal(.microphone, to: state)
            }
        }
        microphoneMonitor?.start()
        if cameraMonitor == nil, let coreMediaIOBackend {
            cameraMonitor = CoreMediaIOCameraMonitor(
                backend: coreMediaIOBackend,
                executor: coreMediaIOExecutor,
                refreshRetryScheduler: coreMediaIORefreshRetryScheduler,
                now: now
            ) { [weak self] state in
                self?.applySignal(.camera, to: state)
            }
        }
        cameraMonitor?.start()
    }

    /// callbackによる状態反映を同期的に無効化し、開始済みならunknownへ戻します。
    ///
    /// CoreAudio / CoreMediaIOのlistener解除は各専用executorで非同期に行います。通常のstop中に解除が
    /// 失敗した場合は、同じ停止世代がcurrentのときだけOSStatusをunknownとして公開し、後続の
    /// stop・start・refreshで再試行します。monitor deinit時の有限shutdown retry後にも残る登録だけを、
    /// process-lifetime cleanup coordinatorへ移譲して解除成功まで再試行します。
    public func stop() {
        microphoneMonitor?.stop()
        cameraMonitor?.stop()
    }

    /// 指定シグナルを更新し、値が変化した場合だけ購読者へ同期通知します。
    ///
    /// microphone / cameraへの書き込みは一時的なoverrideで、次のframework observationが
    /// authoritativeな状態として上書きします。同値入力ではmonitorのsemantic dedup cacheを
    /// 無効化しません。通常利用では `start()` / `stop()` がこの更新を管理します。
    public func updateSignal(_ kind: SignalKind, to state: RawSignalState) {
        guard states[kind] != state else { return }
        if kind == .microphone {
            microphoneMonitor?.invalidatePublishedSemanticState()
        } else if kind == .camera {
            cameraMonitor?.invalidatePublishedSemanticState()
        }
        applySignal(kind, to: state)
    }

    private func applySignal(_ kind: SignalKind, to state: RawSignalState) {
        guard states[kind] != state else { return }
        states[kind] = state
        notifyListeners(kind: kind, state: state)
    }

    private static func makeInitialSnapshot() -> Snapshot {
        SignalKind.allCases.reduce(into: Snapshot()) { snapshot, kind in
            snapshot[kind] = RawSignalState(status: .unknown)
        }
    }

    private func notifyListeners(kind: SignalKind, state: RawSignalState) {
        let listenersToNotify = Array(listeners.values)

        for listener in listenersToNotify {
            do {
                try listener(kind, state)
            } catch {
                continue
            }
        }
    }
}
