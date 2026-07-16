/// Public read/subscribe boundary for raw meeting watcher signals.
///
/// Watcher-side app targets must not depend on `MeetingSignal` directly; this
/// protocol remains in `MeetingSignal` for the current minimal-change phase.
@MainActor
public protocol SignalSource {
    typealias Snapshot = [SignalKind: RawSignalState]
    typealias Listener = @MainActor @Sendable (SignalKind, RawSignalState) throws -> Void
    typealias Unsubscribe = @MainActor @Sendable () -> Void

    func snapshot() -> Snapshot

    @discardableResult
    func subscribe(_ listener: @escaping Listener) -> Unsubscribe
}
