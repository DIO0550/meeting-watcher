/// The high-level meeting state produced by a detection policy.
public enum MeetingState: Equatable, Sendable {
    case inMeeting
    case notInMeeting
    case unknown
}
