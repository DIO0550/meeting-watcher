/// 会議ウォーカーの生シグナルを読み取り、購読するための公開境界です。
///
/// この型は監視コアの `MeetingWatcher` モジュールに属し、通知層の
/// `MeetingSignal` には依存しません。
@MainActor
public protocol SignalSource {
    /// 実運用のスナップショットには、すべての `SignalKind` が含まれます。
    /// 収集されていないシグナルはキーの欠落ではなく、
    /// `RawSignalState(status: .unknown)` で表します。
    typealias Snapshot = SignalSnapshot
    typealias Listener = @MainActor @Sendable (SignalKind, RawSignalState) throws -> Void
    typealias Unsubscribe = @MainActor @Sendable () -> Void

    func snapshot() -> Snapshot

    @discardableResult
    func subscribe(_ listener: @escaping Listener) -> Unsubscribe
}
