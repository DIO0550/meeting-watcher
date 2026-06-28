import Testing
import MeetingSignal

struct SignalKindTests {
    @Test func exposesExpectedSignalKinds() {
        let kinds: [SignalKind] = [.microphone, .camera, .processWindow]

        #expect(kinds.contains(.microphone))
        #expect(kinds.contains(.camera))
        #expect(kinds.contains(.processWindow))
    }

    @Test func rawValuesMatchStableIdentifiers() {
        #expect(SignalKind.microphone.rawValue == "microphone")
        #expect(SignalKind.camera.rawValue == "camera")
        #expect(SignalKind.processWindow.rawValue == "processWindow")
    }

    @Test func allCasesExposeKnownKindsInStableOrder() {
        #expect(SignalKind.allCases == [.microphone, .camera, .processWindow])
    }

    @Test func rawValuesRoundTripToSameKind() {
        for kind in SignalKind.allCases {
            #expect(SignalKind(rawValue: kind.rawValue) == kind)
        }
    }

    @Test func rawValueInitializerRejectsUnknownIdentifier() {
        #expect(SignalKind(rawValue: "unknown") == nil)
    }
}
