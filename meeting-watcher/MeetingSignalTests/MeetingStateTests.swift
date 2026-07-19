import Testing
import MeetingSignal

@Suite("MeetingState")
struct MeetingStateTests {
    @Test func exposesThreeDistinctMeetingStates() {
        #expect(MeetingState.inMeeting != .notInMeeting)
        #expect(MeetingState.notInMeeting != .unknown)
        #expect(MeetingState.unknown != .inMeeting)
    }

    @Test func isSendable() {
        acceptsSendable(MeetingState.self)
    }

    private func acceptsSendable<T: Sendable>(_: T.Type) {}
}
