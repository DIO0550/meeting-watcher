import Testing
import MeetingSignal

struct MeetingSignalTests {
    @Test func publicInitializerConstructsMeetingSignal() {
        let signal = MeetingSignal()
        #expect(type(of: signal) == MeetingSignal.self)
    }
}
