import Foundation
import Testing
import MeetingWatcher
import MeetingSignal

@MainActor
@Suite("MeetingDetectionPolicy")
struct MeetingDetectionPolicyTests {
    @Test func existentialPolicyReceivesSnapshotAndReturnsConfiguredState() {
        let fake = FakeMeetingDetectionPolicy(result: .inMeeting)
        let policy: any MeetingDetectionPolicy = fake
        let snapshot = mixedSnapshot

        let result = policy.evaluate(snapshot: snapshot)

        #expect(result == .inMeeting)
        #expect(fake.receivedSnapshots == [snapshot])
    }

    @Test func policyCanBeSwapped() {
        let snapshot = mixedSnapshot
        let first: any MeetingDetectionPolicy = FakeMeetingDetectionPolicy(result: .notInMeeting)
        let second: any MeetingDetectionPolicy = FakeMeetingDetectionPolicy(result: .unknown)

        #expect(first.evaluate(snapshot: snapshot) == .notInMeeting)
        #expect(second.evaluate(snapshot: snapshot) == .unknown)
    }

    @Test func forwardsUnknownSnapshot() {
        let fake = FakeMeetingDetectionPolicy(result: .unknown)
        let policy: any MeetingDetectionPolicy = fake
        let snapshot = unknownSnapshot

        let result = policy.evaluate(snapshot: snapshot)

        #expect(result == .unknown)
        #expect(fake.receivedSnapshots == [snapshot])
    }

    @Test func preservesMetadataInEvaluation() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let confidence = try #require(RawSignalState.Confidence(1.0))
        let state = RawSignalState(
            status: .active,
            metadata: .init(
                reason: "screen-share",
                observedAt: observedAt,
                confidence: confidence,
                source: "camera"
            )
        )
        let snapshot: SignalSnapshot = [
            .microphone: state,
            .camera: RawSignalState(status: .inactive),
            .processWindow: RawSignalState(status: .unknown)
        ]
        let fake = FakeMeetingDetectionPolicy(result: .inMeeting)
        let policy: any MeetingDetectionPolicy = fake

        _ = policy.evaluate(snapshot: snapshot)

        #expect(fake.receivedSnapshots == [snapshot])
        #expect(fake.receivedSnapshots[0][.microphone]?.metadata == state.metadata)
    }

    @Test func evaluateIsSynchronousAndNonThrowing() {
        let policy: any MeetingDetectionPolicy = FakeMeetingDetectionPolicy(result: .notInMeeting)

        let result = policy.evaluate(snapshot: mixedSnapshot)

        #expect(result == .notInMeeting)
    }

    @Test func forwardsSnapshotExactlyOnce() {
        let fake = FakeMeetingDetectionPolicy(result: .inMeeting)
        let policy: any MeetingDetectionPolicy = fake

        _ = policy.evaluate(snapshot: mixedSnapshot)

        #expect(fake.receivedSnapshots.count == 1)
        #expect(fake.receivedSnapshots[0] == mixedSnapshot)
    }

    @Test func doesNotRequireDefaultRule() {
        let policy: any MeetingDetectionPolicy = FakeMeetingDetectionPolicy(result: .notInMeeting)

        #expect(policy.evaluate(snapshot: mixedSnapshot) == .notInMeeting)
    }

    private var mixedSnapshot: SignalSnapshot {
        [
            .microphone: RawSignalState(status: .active),
            .camera: RawSignalState(status: .inactive),
            .processWindow: RawSignalState(status: .unknown)
        ]
    }

    private var unknownSnapshot: SignalSnapshot {
        SignalKind.allCases.reduce(into: SignalSnapshot()) { snapshot, kind in
            snapshot[kind] = RawSignalState(status: .unknown)
        }
    }
}

@MainActor
private final class FakeMeetingDetectionPolicy: MeetingDetectionPolicy {
    private(set) var receivedSnapshots: [SignalSnapshot] = []
    private let result: MeetingState

    init(result: MeetingState) {
        self.result = result
    }

    func evaluate(snapshot: SignalSnapshot) -> MeetingState {
        receivedSnapshots.append(snapshot)
        return result
    }
}
