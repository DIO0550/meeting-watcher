import Testing
import MeetingSignal

struct MeetingSignalTests {
    @Test func publicInitializerConstructsMeetingSignal() {
        let signal = MeetingSignal()
        #expect(type(of: signal) == MeetingSignal.self)
    }

    @MainActor
    @Test func reexportsMeetingWatcherPublicAPI() {
        let watcher = MeetingWatcher()
        let state = RawSignalState(status: .active)
        watcher.updateSignal(.microphone, to: state)

        let source: any SignalSource = watcher
        let snapshot: SignalSnapshot = source.snapshot()

        #expect(snapshot[SignalKind.microphone] == state)
    }
}
