/// マイクまたはカメラが active のときに会議中と判定する既定ポリシーです。
@MainActor
public struct DefaultMeetingDetectionPolicy: MeetingDetectionPolicy, Sendable {
    public init() {}

    public func evaluate(snapshot: SignalSnapshot) -> MeetingState {
        let microphoneIsActive = snapshot[.microphone]?.status == .active
        let cameraIsActive = snapshot[.camera]?.status == .active

        return microphoneIsActive || cameraIsActive
            ? .inMeeting
            : .notInMeeting
    }
}
