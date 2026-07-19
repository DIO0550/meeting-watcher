/// 標準の会議状態判定ポリシーです。
///
/// いずれかのシグナルが `.active` なら会議中、すべてのシグナルが
/// `.inactive` なら非会議中、未確定のシグナルが混在する場合は
/// `.unknown` と判定します。
@MainActor
public struct DefaultMeetingDetectionPolicy: MeetingDetectionPolicy, Sendable {
    public init() {}

    public func evaluate(snapshot: SignalSnapshot) -> MeetingState {
        let statuses = SignalKind.allCases.map { kind in
            snapshot[kind]?.status ?? .unknown
        }

        if statuses.contains(.active) {
            return .inMeeting
        }

        if statuses.allSatisfy({ $0 == .inactive }) {
            return .notInMeeting
        }

        return .unknown
    }
}
