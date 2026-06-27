import Testing
import MeetingSignal

struct MeetingSignalTests {
    @Test func publicInitializerConstructsMeetingSignal() {
        let signal = MeetingSignal()
        #expect(String(describing: type(of: signal)) == "MeetingSignal")
    }
}
