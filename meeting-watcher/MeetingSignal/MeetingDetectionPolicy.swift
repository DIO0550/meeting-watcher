import MeetingWatcher

/// 生のシグナルスナップショット全体を会議状態へ評価します。
@MainActor
public protocol MeetingDetectionPolicy {
    func evaluate(snapshot: SignalSnapshot) -> MeetingState
}
