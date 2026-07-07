@MainActor
public protocol SignalSource {
    typealias Snapshot = [SignalKind: RawSignalState]
    typealias Listener = @MainActor @Sendable (SignalKind, RawSignalState) throws -> Void
    typealias Unsubscribe = @MainActor @Sendable () -> Void

    func snapshot() -> Snapshot

    @discardableResult
    func subscribe(_ listener: @escaping Listener) -> Unsubscribe
}
