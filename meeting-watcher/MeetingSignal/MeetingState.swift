/// 判定ポリシーが生成する高レベルの会議状態です。
public enum MeetingState: Equatable, Sendable {
    case inMeeting
    case notInMeeting
    case unknown
}
