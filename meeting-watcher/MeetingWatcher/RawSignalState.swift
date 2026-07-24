import Foundation

public struct RawSignalState: Equatable, Sendable {
    public enum Status: String, CaseIterable, Equatable, Sendable {
        public static let allCases: [Status] = [.active, .inactive, .unknown]

        case active = "active"
        case inactive = "inactive"
        case unknown = "unknown"
    }

    public struct Metadata: Equatable, Sendable {
        public let reason: String?
        public let observedAt: Date?
        public let confidence: Confidence?
        public let source: String?

        public init(
            reason: String? = nil,
            observedAt: Date? = nil,
            confidence: Confidence? = nil,
            source: String? = nil
        ) {
            self.reason = reason
            self.observedAt = observedAt
            self.confidence = confidence
            self.source = source
        }
    }

    public struct Confidence: Equatable, Sendable {
        public let value: Double

        public init?(_ value: Double) {
            guard value.isFinite, (0.0...1.0).contains(value) else {
                return nil
            }

            self.value = value
        }
    }

    public let status: Status
    public let metadata: Metadata

    public init(status: Status, metadata: Metadata = Metadata()) {
        self.status = status
        self.metadata = metadata
    }
}
