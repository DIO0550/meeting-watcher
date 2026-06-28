public enum SignalKind: String, CaseIterable, Equatable, Sendable {
    public static let allCases: [SignalKind] = [.microphone, .camera, .processWindow]

    case microphone = "microphone"
    case camera = "camera"
    case processWindow = "processWindow"
}
