import Foundation
import Testing
import MeetingSignal

struct RawSignalStateTests {
    @Test func statusAllCasesExposeKnownStatesInStableOrder() {
        #expect(RawSignalState.Status.allCases == [.active, .inactive, .unknown])
    }

    @Test func statusRawValuesAreStable() {
        #expect(RawSignalState.Status.active.rawValue == "active")
        #expect(RawSignalState.Status.inactive.rawValue == "inactive")
        #expect(RawSignalState.Status.unknown.rawValue == "unknown")
    }

    @Test func initializesWithStatusAndEmptyMetadata() {
        let state = RawSignalState(status: .unknown)

        #expect(state.status == .unknown)
        #expect(state.metadata.reason == nil)
        #expect(state.metadata.observedAt == nil)
        #expect(state.metadata.confidence == nil)
        #expect(state.metadata.source == nil)
    }

    @Test func preservesMetadataValues() throws {
        let observedAt = Date(timeIntervalSince1970: 1_234)
        let confidence = try #require(RawSignalState.Confidence(0.75))
        let metadata = RawSignalState.Metadata(
            reason: "microphone level exceeded threshold",
            observedAt: observedAt,
            confidence: confidence,
            source: "microphone"
        )

        let state = RawSignalState(status: .active, metadata: metadata)

        #expect(state.metadata.reason == "microphone level exceeded threshold")
        #expect(state.metadata.observedAt == observedAt)
        #expect(state.metadata.confidence == confidence)
        #expect(state.metadata.source == "microphone")
    }

    @Test func confidenceAcceptsBoundaryValues() throws {
        #expect(try #require(RawSignalState.Confidence(0.0)).value == 0.0)
        #expect(try #require(RawSignalState.Confidence(1.0)).value == 1.0)
    }

    @Test func confidenceRejectsOutOfRangeValues() {
        #expect(RawSignalState.Confidence(-0.1) == nil)
        #expect(RawSignalState.Confidence(1.1) == nil)
        #expect(RawSignalState.Confidence(Double.nan) == nil)
        #expect(RawSignalState.Confidence(.infinity) == nil)
        #expect(RawSignalState.Confidence(-.infinity) == nil)
    }

    @Test func rawSignalStateIsEquatable() throws {
        let confidence = try #require(RawSignalState.Confidence(0.5))
        let metadata = RawSignalState.Metadata(reason: "same", confidence: confidence)

        #expect(
            RawSignalState(status: .inactive, metadata: metadata)
                == RawSignalState(status: .inactive, metadata: metadata)
        )
    }

    @Test func rawSignalStateIsNotEqualWhenValuesDiffer() throws {
        let confidence = try #require(RawSignalState.Confidence(0.5))

        #expect(RawSignalState(status: .active) != RawSignalState(status: .inactive))
        #expect(
            RawSignalState(status: .active, metadata: .init(reason: "same"))
                != RawSignalState(status: .active, metadata: .init(reason: "different"))
        )
        #expect(
            RawSignalState(status: .active, metadata: .init(confidence: confidence))
                != RawSignalState(status: .active)
        )
    }

    @Test func rawSignalStateTypesAreSendable() {
        acceptsSendable(RawSignalState.self)
        acceptsSendable(RawSignalState.Status.self)
        acceptsSendable(RawSignalState.Metadata.self)
        acceptsSendable(RawSignalState.Confidence.self)
    }

    private func acceptsSendable<T: Sendable>(_: T.Type) {}
}
