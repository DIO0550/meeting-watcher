import Foundation

/// A complete point-in-time view of all raw meeting signals.
///
/// Production snapshots contain every `SignalKind`. A signal that has not
/// been collected is represented by `RawSignalState(status: .unknown)`,
/// rather than by omitting its key.
public typealias SignalSnapshot = [SignalKind: RawSignalState]
