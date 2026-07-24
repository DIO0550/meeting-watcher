import Foundation
import Testing
import MeetingWatcher

@MainActor
@Suite("MeetingWatcher")
struct MeetingWatcherTests {
    @Test func publicInitializerCreatesUnknownSnapshotForAllSignalKinds() {
        let watcher = MeetingWatcher()

        let snapshot = watcher.snapshot()

        #expect(Set(snapshot.keys) == Set(SignalKind.allCases))
        for kind in SignalKind.allCases {
            #expect(snapshot[kind] == RawSignalState(status: .unknown))
        }
    }

    @Test func snapshotReturnsCurrentRawSignalStatesWithMetadata() throws {
        let watcher = MeetingWatcher()
        let observedAt = Date(timeIntervalSince1970: 1_717_171_717)
        let confidence = try #require(RawSignalState.Confidence(0.85))
        let state = RawSignalState(
            status: .active,
            metadata: .init(
                reason: "voice detected",
                observedAt: observedAt,
                confidence: confidence,
                source: "unit-test"
            )
        )

        watcher.updateSignal(.microphone, to: state)
        let snapshot = watcher.snapshot()

        #expect(snapshot[.microphone] == state)
        #expect(snapshot[.microphone]?.metadata.reason == "voice detected")
        #expect(snapshot[.microphone]?.metadata.observedAt == observedAt)
        #expect(snapshot[.microphone]?.metadata.confidence == confidence)
        #expect(snapshot[.microphone]?.metadata.source == "unit-test")
        #expect(snapshot[.camera] == RawSignalState(status: .unknown))
        #expect(snapshot[.processWindow] == RawSignalState(status: .unknown))
    }

    @Test func subscribeDoesNotNotifyImmediately() {
        let watcher = MeetingWatcher()
        let calls = SignalCallRecorder()

        watcher.subscribe { kind, state in
            calls.append(kind, state)
        }

        #expect(calls.calls.isEmpty)
    }

    @Test func listenerIsCalledWhenSignalStateChanges() throws {
        let watcher = MeetingWatcher()
        let calls = SignalCallRecorder()
        let observedAt = Date(timeIntervalSince1970: 1_717_171_717)
        let confidence = try #require(RawSignalState.Confidence(0.85))
        let state = RawSignalState(
            status: .active,
            metadata: .init(
                reason: "voice detected",
                observedAt: observedAt,
                confidence: confidence,
                source: "unit-test"
            )
        )

        watcher.subscribe { kind, state in
            calls.append(kind, state)
        }
        watcher.updateSignal(.microphone, to: state)

        #expect(calls.calls.count == 1)
        #expect(calls.calls.first?.0 == .microphone)
        #expect(calls.calls.first?.1 == state)
    }

    @Test func sameStateDoesNotNotifyAgain() throws {
        let watcher = MeetingWatcher()
        let calls = SignalCallRecorder()
        let observedAt = Date(timeIntervalSince1970: 1_717_171_717)
        let confidence = try #require(RawSignalState.Confidence(0.85))
        let state = RawSignalState(
            status: .active,
            metadata: .init(
                reason: "camera active",
                observedAt: observedAt,
                confidence: confidence,
                source: "unit-test"
            )
        )

        watcher.subscribe { kind, state in
            calls.append(kind, state)
        }
        watcher.updateSignal(.camera, to: state)
        watcher.updateSignal(.camera, to: state)

        #expect(calls.calls.count == 1)
    }

    @Test func unsubscribeStopsFutureNotifications() {
        let watcher = MeetingWatcher()
        let calls = SignalCallRecorder()

        let unsubscribe = watcher.subscribe { kind, state in
            calls.append(kind, state)
        }
        unsubscribe()
        watcher.updateSignal(.microphone, to: RawSignalState(status: .active))

        #expect(calls.calls.isEmpty)
    }

    @Test func unsubscribeIsIdempotent() {
        let watcher = MeetingWatcher()
        let calls = SignalCallRecorder()

        let unsubscribe = watcher.subscribe { kind, state in
            calls.append(kind, state)
        }
        unsubscribe()
        unsubscribe()
        watcher.updateSignal(.microphone, to: RawSignalState(status: .active))

        #expect(calls.calls.isEmpty)
    }

    @Test func multipleListenersAreIndependent() {
        let watcher = MeetingWatcher()
        let firstCalls = SignalCallRecorder()
        let secondCalls = SignalCallRecorder()

        let unsubscribeFirst = watcher.subscribe { kind, state in
            firstCalls.append(kind, state)
        }
        watcher.subscribe { kind, state in
            secondCalls.append(kind, state)
        }
        unsubscribeFirst()
        watcher.updateSignal(.camera, to: RawSignalState(status: .active))

        #expect(firstCalls.calls.isEmpty)
        #expect(secondCalls.calls.count == 1)
        #expect(secondCalls.calls.first?.0 == .camera)
    }

    @Test func unsubscribeDuringNotificationAppliesFromNextUpdate() {
        let watcher = MeetingWatcher()
        let removingListenerCalls = SignalCallRecorder()
        let removedListenerCalls = SignalCallRecorder()
        let unsubscribeBox = UnsubscribeBox()

        watcher.subscribe { kind, state in
            unsubscribeBox.unsubscribe?()
            removingListenerCalls.append(kind, state)
        }
        unsubscribeBox.unsubscribe = watcher.subscribe { kind, state in
            removedListenerCalls.append(kind, state)
        }

        watcher.updateSignal(.microphone, to: RawSignalState(status: .active))
        watcher.updateSignal(.microphone, to: RawSignalState(status: .inactive))

        #expect(removingListenerCalls.calls.count == 2)
        #expect(removedListenerCalls.calls.count == 1)
        #expect(removedListenerCalls.calls.first?.0 == .microphone)
        #expect(removedListenerCalls.calls.first?.1 == RawSignalState(status: .active))
    }

    @Test func subscribeDuringNotificationAppliesFromNextUpdate() {
        let watcher = MeetingWatcher()
        let originalCalls = SignalCallRecorder()
        let addedCalls = SignalCallRecorder()
        let didSubscribeAdditionalListener = BooleanBox()

        watcher.subscribe { kind, state in
            originalCalls.append(kind, state)
            if !didSubscribeAdditionalListener.value {
                didSubscribeAdditionalListener.value = true
                watcher.subscribe { addedKind, addedState in
                    addedCalls.append(addedKind, addedState)
                }
            }
        }

        watcher.updateSignal(.microphone, to: RawSignalState(status: .active))
        #expect(originalCalls.calls.count == 1)
        #expect(addedCalls.calls.isEmpty)

        watcher.updateSignal(.microphone, to: RawSignalState(status: .inactive))
        #expect(originalCalls.calls.count == 2)
        #expect(addedCalls.calls.count == 1)
        #expect(addedCalls.calls.first?.0 == .microphone)
        #expect(addedCalls.calls.first?.1 == RawSignalState(status: .inactive))
    }

    @Test func snapshotResultMutationDoesNotChangeInternalState() {
        let watcher = MeetingWatcher()
        watcher.updateSignal(.microphone, to: RawSignalState(status: .active))

        var snapshot = watcher.snapshot()
        snapshot[.microphone] = RawSignalState(status: .inactive)

        #expect(watcher.snapshot()[.microphone] == RawSignalState(status: .active))
    }

    @Test func metadataOnlyChangeNotifiesListener() throws {
        let watcher = MeetingWatcher()
        let calls = SignalCallRecorder()
        let firstObservedAt = Date(timeIntervalSince1970: 1_717_171_717)
        let secondObservedAt = Date(timeIntervalSince1970: 1_717_171_718)
        let firstConfidence = try #require(RawSignalState.Confidence(0.50))
        let secondConfidence = try #require(RawSignalState.Confidence(0.85))
        let first = RawSignalState(
            status: .active,
            metadata: .init(
                reason: "first",
                observedAt: firstObservedAt,
                confidence: firstConfidence,
                source: "detector"
            )
        )
        let second = RawSignalState(
            status: .active,
            metadata: .init(
                reason: "metadata changed",
                observedAt: secondObservedAt,
                confidence: secondConfidence,
                source: "detector"
            )
        )

        watcher.subscribe { kind, state in
            calls.append(kind, state)
        }
        watcher.updateSignal(.microphone, to: first)
        watcher.updateSignal(.microphone, to: second)

        #expect(calls.calls.count == 2)
        #expect(calls.calls.last?.0 == .microphone)
        #expect(calls.calls.last?.1 == second)
    }

    @Test func throwingListenerDoesNotStopOtherListeners() {
        let watcher = MeetingWatcher()
        let nonThrowingCalls = SignalCallRecorder()

        watcher.subscribe { _, _ in
            throw TestError.listenerFailed
        }
        watcher.subscribe { kind, state in
            nonThrowingCalls.append(kind, state)
        }
        watcher.updateSignal(.camera, to: RawSignalState(status: .active))

        #expect(nonThrowingCalls.calls.count == 1)
        #expect(nonThrowingCalls.calls.first?.0 == .camera)
    }

    @Test func watcherContinuesAfterThrowingListener() {
        let watcher = MeetingWatcher()
        let nonThrowingCalls = SignalCallRecorder()

        watcher.subscribe { _, _ in
            throw TestError.listenerFailed
        }
        watcher.subscribe { kind, state in
            nonThrowingCalls.append(kind, state)
        }
        watcher.updateSignal(.camera, to: RawSignalState(status: .active))
        watcher.updateSignal(.camera, to: RawSignalState(status: .inactive))

        #expect(nonThrowingCalls.calls.count == 2)
        #expect(nonThrowingCalls.calls.last?.0 == .camera)
        #expect(nonThrowingCalls.calls.last?.1 == RawSignalState(status: .inactive))
    }

    private enum TestError: Error {
        case listenerFailed
    }

    @MainActor
    private final class SignalCallRecorder: @unchecked Sendable {
        private(set) var calls: [(SignalKind, RawSignalState)] = []

        func append(_ kind: SignalKind, _ state: RawSignalState) {
            calls.append((kind, state))
        }
    }

    @MainActor
    private final class BooleanBox: @unchecked Sendable {
        var value = false
    }

    @MainActor
    private final class UnsubscribeBox: @unchecked Sendable {
        var unsubscribe: MeetingWatcher.Unsubscribe?
    }
}
