import Foundation

/// In-memory raw signal source used to publish watcher observations.
@MainActor
public final class MeetingWatcher: SignalSource {
    public typealias Snapshot = SignalSnapshot
    public typealias Listener = @MainActor @Sendable (SignalKind, RawSignalState) throws -> Void
    public typealias Unsubscribe = @MainActor @Sendable () -> Void

    private var states: Snapshot
    private var listeners: [UUID: Listener]

    public init() {
        states = Self.makeInitialSnapshot()
        listeners = [:]
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

    public func updateSignal(_ kind: SignalKind, to state: RawSignalState) {
        guard states[kind] != state else {
            return
        }

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
