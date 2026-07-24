import Foundation
import Testing
import MeetingWatcher

@MainActor
@Suite("SignalSnapshot")
struct SignalSnapshotTests {
    @Test func storesEverySignalKindIncludingExplicitUnknown() {
        let snapshot: SignalSnapshot = [
            .microphone: RawSignalState(status: .active),
            .camera: RawSignalState(status: .inactive),
            .processWindow: RawSignalState(status: .unknown)
        ]

        #expect(snapshot.count == SignalKind.allCases.count)
        #expect(snapshot[.microphone]?.status == .active)
        #expect(snapshot[.camera]?.status == .inactive)
        #expect(snapshot[.processWindow]?.status == .unknown)
    }

    @Test func storesAllUnknownSignals() {
        let snapshot = SignalKind.allCases.reduce(into: SignalSnapshot()) { snapshot, kind in
            snapshot[kind] = RawSignalState(status: .unknown)
        }

        #expect(Set(snapshot.keys) == Set(SignalKind.allCases))
        for kind in SignalKind.allCases {
            #expect(snapshot[kind] == RawSignalState(status: .unknown))
        }
    }

    @Test func preservesMetadata() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let confidence = try #require(RawSignalState.Confidence(0.85))
        let state = RawSignalState(
            status: .active,
            metadata: .init(
                reason: "permission-granted",
                observedAt: observedAt,
                confidence: confidence,
                source: "audio"
            )
        )
        let snapshot: SignalSnapshot = [.microphone: state]

        #expect(snapshot[.microphone] == state)
        #expect(snapshot[.microphone]?.metadata.reason == "permission-granted")
        #expect(snapshot[.microphone]?.metadata.observedAt == observedAt)
        #expect(snapshot[.microphone]?.metadata.confidence == confidence)
        #expect(snapshot[.microphone]?.metadata.source == "audio")
    }

    @Test func acceptsDictionaryLiteralAndSubscript() {
        var snapshot: SignalSnapshot = [
            .camera: RawSignalState(status: .inactive)
        ]

        snapshot[.camera] = RawSignalState(status: .active)

        #expect(snapshot[.camera]?.status == .active)
    }

    @Test func isSendable() {
        acceptsSendable(SignalSnapshot.self)
    }

    @Test func canonicalAliasAcceptsExistingSnapshotAliases() {
        let watcherSnapshot: MeetingWatcher.Snapshot = MeetingWatcher().snapshot()
        let canonical: SignalSnapshot = watcherSnapshot
        let sourceSnapshot: SignalSource.Snapshot = canonical

        #expect(sourceSnapshot == canonical)
    }

    @Test func productionSnapshotContainsEverySignalKindAsUnknown() {
        let snapshot = MeetingWatcher().snapshot()

        #expect(Set(snapshot.keys) == Set(SignalKind.allCases))
        for kind in SignalKind.allCases {
            #expect(snapshot[kind] == RawSignalState(status: .unknown))
        }
    }

    private func acceptsSendable<T: Sendable>(_: T.Type) {}
}
