/// ある時点における、すべての生の会議シグナルの完全な状態です。
///
/// 実運用のスナップショットには、すべての `SignalKind` が含まれます。
/// 収集されていないシグナルはキーを省略せず、
/// `RawSignalState(status: .unknown)` で表します。
public typealias SignalSnapshot = [SignalKind: RawSignalState]
