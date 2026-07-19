/// 会議ウォーカーの生シグナルを読み取り、購読するための公開境界です。
///
/// ウォーカー側のアプリターゲットは `MeetingSignal` に直接依存してはいけません。
/// 現在の最小変更フェーズでは、このプロトコルを `MeetingSignal` に置きます。
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
