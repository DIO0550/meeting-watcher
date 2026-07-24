import Testing
import MeetingWatcher
import MeetingSignal

@MainActor
@Suite("DefaultMeetingDetectionPolicy")
struct DefaultMeetingDetectionPolicyTests {
    @Test func returnsNotInMeetingWhenBothSignalsAreInactive() {
        let snapshot = makeSnapshot(
            microphone: RawSignalState(status: .inactive),
            camera: RawSignalState(status: .inactive)
        )

        #expect(DefaultMeetingDetectionPolicy().evaluate(snapshot: snapshot) == .notInMeeting)
    }

    @Test func returnsInMeetingWhenOnlyMicrophoneIsActive() {
        let snapshot = makeSnapshot(
            microphone: RawSignalState(status: .active),
            camera: RawSignalState(status: .inactive)
        )

        #expect(DefaultMeetingDetectionPolicy().evaluate(snapshot: snapshot) == .inMeeting)
    }

    @Test func returnsInMeetingWhenOnlyCameraIsActive() {
        let snapshot = makeSnapshot(
            microphone: RawSignalState(status: .inactive),
            camera: RawSignalState(status: .active)
        )

        #expect(DefaultMeetingDetectionPolicy().evaluate(snapshot: snapshot) == .inMeeting)
    }

    @Test func returnsInMeetingWhenBothSignalsAreActive() {
        let snapshot = makeSnapshot(
            microphone: RawSignalState(status: .active),
            camera: RawSignalState(status: .active)
        )

        #expect(DefaultMeetingDetectionPolicy().evaluate(snapshot: snapshot) == .inMeeting)
    }

    @Test func treatsUnknownSignalsAsNotActive() {
        let snapshot = makeSnapshot(
            microphone: RawSignalState(status: .unknown),
            camera: RawSignalState(status: .unknown)
        )

        #expect(DefaultMeetingDetectionPolicy().evaluate(snapshot: snapshot) == .notInMeeting)
    }

    @Test func returnsInMeetingWhenMicrophoneIsActiveAndCameraIsUnknown() {
        let snapshot = makeSnapshot(
            microphone: RawSignalState(status: .active),
            camera: RawSignalState(status: .unknown)
        )

        #expect(DefaultMeetingDetectionPolicy().evaluate(snapshot: snapshot) == .inMeeting)
    }

    @Test func treatsMissingMicrophoneAndCameraKeysAsNotActive() {
        #expect(DefaultMeetingDetectionPolicy().evaluate(snapshot: [:]) == .notInMeeting)
    }

    @Test func returnsInMeetingWhenMicrophoneIsActiveAndCameraKeyIsMissing() {
        let snapshot = makeSnapshot(microphone: RawSignalState(status: .active))

        #expect(DefaultMeetingDetectionPolicy().evaluate(snapshot: snapshot) == .inMeeting)
    }

    @Test func returnsInMeetingWhenCameraIsActiveAndMicrophoneKeyIsMissing() {
        let snapshot = makeSnapshot(camera: RawSignalState(status: .active))

        #expect(DefaultMeetingDetectionPolicy().evaluate(snapshot: snapshot) == .inMeeting)
    }

    @Test func ignoresActiveProcessWindow() {
        let snapshot = makeSnapshot(
            microphone: RawSignalState(status: .inactive),
            camera: RawSignalState(status: .inactive),
            processWindow: RawSignalState(status: .active)
        )

        #expect(DefaultMeetingDetectionPolicy().evaluate(snapshot: snapshot) == .notInMeeting)
    }

    @Test func ignoresMetadataAndConfidence() throws {
        let confidence = try #require(RawSignalState.Confidence(0.99))
        let snapshot = makeSnapshot(
            microphone: RawSignalState(
                status: .inactive,
                metadata: .init(
                    reason: "voice-detected",
                    confidence: confidence,
                    source: "microphone"
                )
            ),
            camera: RawSignalState(
                status: .inactive,
                metadata: .init(reason: "camera-on", source: "camera")
            )
        )

        #expect(DefaultMeetingDetectionPolicy().evaluate(snapshot: snapshot) == .notInMeeting)
    }

    @Test func conformsToMeetingDetectionPolicyAndEvaluatesSynchronously() {
        let policy: any MeetingDetectionPolicy = DefaultMeetingDetectionPolicy()
        let snapshot = makeSnapshot(
            microphone: RawSignalState(status: .active),
            camera: RawSignalState(status: .inactive)
        )

        let result = policy.evaluate(snapshot: snapshot)

        #expect(result == .inMeeting)
    }

    private func makeSnapshot(
        microphone: RawSignalState? = nil,
        camera: RawSignalState? = nil,
        processWindow: RawSignalState? = nil
    ) -> SignalSnapshot {
        var snapshot: SignalSnapshot = [:]
        snapshot[.microphone] = microphone
        snapshot[.camera] = camera
        snapshot[.processWindow] = processWindow
        return snapshot
    }
}
