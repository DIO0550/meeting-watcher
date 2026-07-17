import Foundation

/// Evaluates a complete raw signal snapshot into a meeting state.
@MainActor
public protocol MeetingDetectionPolicy {
    func evaluate(snapshot: SignalSnapshot) -> MeetingState
}
