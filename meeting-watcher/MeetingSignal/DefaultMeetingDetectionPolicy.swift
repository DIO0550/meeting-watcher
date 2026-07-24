import MeetingWatcher

/// マイクまたはカメラが `.active` のときに会議中と判定する既定ポリシーです。
///
/// 両方が `.active` でなければ、`.unknown` やキー欠落を含めて
/// `.notInMeeting` を返します。`processWindow`、metadata、confidence は
/// 判定に使用しません。
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
