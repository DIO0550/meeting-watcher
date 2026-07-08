import Foundation
import Testing
import MeetingSignal

@MainActor
@Suite("SignalSource")
struct SignalSourceTests {
    @Test func meetingWatcherCanBeUsedAsSignalSource() {
        let source: any SignalSource = MeetingWatcher()

        let snapshot = source.snapshot()

        #expect(Set(snapshot.keys) == Set(SignalKind.allCases))
        for kind in SignalKind.allCases {
            #expect(snapshot[kind] == RawSignalState(status: .unknown))
        }
    }

    @Test func fakeSignalSourcePublishesAndStoresControlledSignalChanges() {
        let source = FakeSignalSource()
        let consumer: any SignalSource = source
        let calls = SignalCallRecorder()
        let state = RawSignalState(status: .active)

        consumer.subscribe { kind, receivedState in
            calls.append(kind, receivedState)
        }
        source.emit(.microphone, state)

        #expect(calls.calls.count == 1)
        #expect(calls.calls.first?.0 == .microphone)
        #expect(calls.calls.first?.1 == state)
        #expect(consumer.snapshot()[.microphone] == state)
    }

    @Test func signalSourceUnsubscribeStopsFutureNotifications() {
        let source = FakeSignalSource()
        let consumer: any SignalSource = source
        let calls = SignalCallRecorder()

        let unsubscribe = consumer.subscribe { kind, state in
            calls.append(kind, state)
        }
        unsubscribe()
        source.emit(.camera, RawSignalState(status: .active))

        #expect(calls.calls.isEmpty)
    }

    @Test func fakeSignalSourceDeliversMultipleEventsInOrder() {
        let source = FakeSignalSource()
        let consumer: any SignalSource = source
        let calls = SignalCallRecorder()

        consumer.subscribe { kind, state in
            calls.append(kind, state)
        }
        source.emit(.microphone, RawSignalState(status: .active))
        source.emit(.microphone, RawSignalState(status: .inactive))

        #expect(calls.calls.count == 2)
        #expect(calls.calls.first?.0 == .microphone)
        #expect(calls.calls.first?.1 == RawSignalState(status: .active))
        #expect(calls.calls.last?.0 == .microphone)
        #expect(calls.calls.last?.1 == RawSignalState(status: .inactive))
    }

    @Test func fakeSignalSourceNotifiesMultipleSubscribers() {
        let source = FakeSignalSource()
        let consumer: any SignalSource = source
        let firstCalls = SignalCallRecorder()
        let secondCalls = SignalCallRecorder()

        consumer.subscribe { kind, state in
            firstCalls.append(kind, state)
        }
        consumer.subscribe { kind, state in
            secondCalls.append(kind, state)
        }
        source.emit(.processWindow, RawSignalState(status: .active))

        #expect(firstCalls.calls.count == 1)
        #expect(firstCalls.calls.first?.0 == .processWindow)
        #expect(secondCalls.calls.count == 1)
        #expect(secondCalls.calls.first?.0 == .processWindow)
    }

    @Test func fakeSignalSourceContinuesAfterThrowingListener() {
        let source = FakeSignalSource()
        let consumer: any SignalSource = source
        let calls = SignalCallRecorder()

        consumer.subscribe { _, _ in
            throw TestError.listenerFailed
        }
        consumer.subscribe { kind, state in
            calls.append(kind, state)
        }
        source.emit(.camera, RawSignalState(status: .active))

        #expect(calls.calls.count == 1)
        #expect(calls.calls.first?.0 == .camera)
    }

    private enum TestError: Error {
        case listenerFailed
    }

    @MainActor
    private final class FakeSignalSource: SignalSource {
        typealias Snapshot = [SignalKind: RawSignalState]
        typealias Listener = @MainActor @Sendable (SignalKind, RawSignalState) throws -> Void
        typealias Unsubscribe = @MainActor @Sendable () -> Void

        private var states: Snapshot = SignalKind.allCases.reduce(into: Snapshot()) { snapshot, kind in
            snapshot[kind] = RawSignalState(status: .unknown)
        }
        private var listeners: [UUID: Listener] = [:]

        func snapshot() -> Snapshot {
            states
        }

        @discardableResult
        func subscribe(_ listener: @escaping Listener) -> Unsubscribe {
            let id = UUID()
            listeners[id] = listener

            return { [weak self] in
                self?.listeners.removeValue(forKey: id)
            }
        }

        func emit(_ kind: SignalKind, _ state: RawSignalState) {
            states[kind] = state

            for listener in Array(listeners.values) {
                do {
                    try listener(kind, state)
                } catch {
                    continue
                }
            }
        }
    }

    @MainActor
    private final class SignalCallRecorder: @unchecked Sendable {
        private(set) var calls: [(SignalKind, RawSignalState)] = []

        func append(_ kind: SignalKind, _ state: RawSignalState) {
            calls.append((kind, state))
        }
    }
}
