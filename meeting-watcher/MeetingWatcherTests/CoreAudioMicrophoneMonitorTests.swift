import CoreAudio
import Dispatch
import Foundation
import Testing
@testable import MeetingWatcher

@MainActor
@Suite("System CoreAudio backend")
struct SystemCoreAudioBackendTests {
    @Test func enumeratesWithExactAddressesAndFiltersInputStreams() throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10, 20], inputStreamCounts: [10: 1, 20: 0])
        let backend = SystemCoreAudioBackend(hal: hal)

        #expect(try backend.inputDeviceIDs() == [.init(rawValue: 10)])
        #expect(hal.calls == [
            .size(kAudioObjectSystemObject, Self.deviceListAddress),
            .data(kAudioObjectSystemObject, Self.deviceListAddress),
            .has(10, Self.inputStreamsAddress),
            .size(10, Self.inputStreamsAddress),
            .has(20, Self.inputStreamsAddress),
            .size(20, Self.inputStreamsAddress),
        ])
    }

    @Test func validatesEveryDeviceListAndInputStreamSizeBoundary() throws {
        let nonalignedInitial = FakeCoreAudioHAL()
        nonalignedInitial.setDeviceListInitialSize(3)
        expectError(.invalidPropertyData(operation: .enumerateDevices)) {
            _ = try SystemCoreAudioBackend(hal: nonalignedInitial).inputDeviceIDs()
        }

        let empty = FakeCoreAudioHAL()
        empty.setDevices([], inputStreamCounts: [:])
        #expect(try SystemCoreAudioBackend(hal: empty).inputDeviceIDs().isEmpty)
        #expect(empty.dataCallCount(selector: kAudioHardwarePropertyDevices) == 0)

        let returnedTooLarge = FakeCoreAudioHAL()
        returnedTooLarge.setDevices([10], inputStreamCounts: [10: 1])
        returnedTooLarge.setReturnedDataSize(8, for: Self.deviceListAddress)
        expectError(.invalidPropertyData(operation: .enumerateDevices)) {
            _ = try SystemCoreAudioBackend(hal: returnedTooLarge).inputDeviceIDs()
        }

        let returnedNonaligned = FakeCoreAudioHAL()
        returnedNonaligned.setDevices([10], inputStreamCounts: [10: 1])
        returnedNonaligned.setReturnedDataSize(3, for: Self.deviceListAddress)
        expectError(.invalidPropertyData(operation: .enumerateDevices)) {
            _ = try SystemCoreAudioBackend(hal: returnedNonaligned).inputDeviceIDs()
        }

        let streamNonaligned = FakeCoreAudioHAL()
        streamNonaligned.setDevices([10], inputStreamCounts: [10: 1])
        streamNonaligned.setPropertySize(3, objectID: 10, address: Self.inputStreamsAddress)
        expectError(.invalidPropertyData(operation: .inspectInputStreams)) {
            _ = try SystemCoreAudioBackend(hal: streamNonaligned).inputDeviceIDs()
        }

        let missingProperty = FakeCoreAudioHAL()
        missingProperty.setDevices([10], inputStreamCounts: [10: 1])
        missingProperty.setHasProperty(false, objectID: 10, address: Self.inputStreamsAddress)
        #expect(try SystemCoreAudioBackend(hal: missingProperty).inputDeviceIDs().isEmpty)
        #expect(missingProperty.sizeCallCount(objectID: 10, selector: kAudioDevicePropertyStreams) == 0)
    }

    @Test func readsRunningUInt32AndValidatesReturnedSize() throws {
        let hal = FakeCoreAudioHAL()
        hal.setRunning(1, deviceID: 10)
        let backend = SystemCoreAudioBackend(hal: hal)
        #expect(try backend.isRunningSomewhere(deviceID: .init(rawValue: 10)))

        hal.setReturnedDataSize(1, for: Self.runningAddress)
        expectError(.invalidPropertyData(operation: .readRunningState)) {
            _ = try backend.isRunningSomewhere(deviceID: .init(rawValue: 10))
        }
    }

    @Test func addRemoveUseExactTupleAndFailedRemovalRetries() throws {
        let hal = FakeCoreAudioHAL()
        let queue = DispatchQueue(label: "CoreAudioBackendTests.listener")
        hal.setRemoveStatuses([-91, noErr], objectID: 42, address: Self.runningAddress)
        let backend = SystemCoreAudioBackend(hal: hal, listenerQueue: queue)
        let registration = try backend.observeRunningStateChanges(deviceID: .init(rawValue: 42)) {}

        expectError(.osStatus(operation: .removeListener, status: -91)) {
            try registration.cancel()
        }
        try registration.cancel()

        let add = try #require(hal.addCalls.first)
        #expect(add.objectID == 42)
        #expect(add.address == Self.runningAddress)
        #expect(add.queue === queue)
        #expect(hal.removeCalls.count == 2)
        for remove in hal.removeCalls {
            #expect(remove.objectID == add.objectID)
            #expect(remove.address == add.address)
            #expect(remove.queue === add.queue)
            #expect(remove.listener === add.listener)
        }
    }

    @Test func HALHookAllowsBoundedReadAddAndCancelReentry() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([42], inputStreamCounts: [42: 1])
        hal.setRunning(1, deviceID: 42)
        let listenerQueue = DispatchQueue(label: "CoreAudioBackendTests.reentrant.listener")
        let backend = SystemCoreAudioBackend(hal: hal, listenerQueue: listenerQueue)
        hal.setOneShotHALHook {
            _ = try? backend.isRunningSomewhere(deviceID: .init(rawValue: 42))
            if let registration = try? backend.observeRunningStateChanges(deviceID: .init(rawValue: 42)) {} {
                try? registration.cancel()
            }
        }

        let completed = await boundedHALCompletion {
            (try? backend.inputDeviceIDs()) == [.init(rawValue: 42)]
        }
        guard completed else {
            Issue.record("Timed out waiting for bounded HAL work")
            return
        }
        let add = try #require(hal.addCalls.last)
        let remove = try #require(hal.removeCalls.last)
        #expect(remove.objectID == add.objectID)
        #expect(remove.address == add.address)
        #expect(remove.queue === add.queue)
        #expect(remove.listener === add.listener)
    }

    @Test func removeHookRecursiveCancelIsBoundedAndDoesNotDuplicateRemove() async throws {
        let hal = FakeCoreAudioHAL()
        let backend = SystemCoreAudioBackend(hal: hal)
        let registration = try backend.observeRunningStateChanges(deviceID: .init(rawValue: 42)) {}
        hal.setOneShotHALHook { try? registration.cancel() }

        let completed = await boundedHALCompletion {
            do { try registration.cancel(); return true } catch { return false }
        }
        guard completed else {
            Issue.record("Timed out waiting for bounded HAL work")
            return
        }
        #expect(hal.removeCallCount(objectID: 42, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 1)
        try registration.cancel()
        #expect(hal.removeCallCount(objectID: 42, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 1)
    }

    @Test func boundedConcurrentCancelsRetryAfterFirstRemovalFailure() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setRemoveStatuses([-91, noErr], objectID: 42, address: Self.runningAddress)
        let backend = SystemCoreAudioBackend(hal: hal)
        let registration = try backend.observeRunningStateChanges(deviceID: .init(rawValue: 42)) {}

        let completed = await boundedHALCompletion {
            let group = DispatchGroup()
            for _ in 0..<2 {
                group.enter()
                DispatchQueue.global().async {
                    try? registration.cancel()
                    group.leave()
                }
            }
            return group.wait(timeout: .now() + 0.75) == .success
        }
        guard completed else {
            Issue.record("Timed out waiting for bounded HAL work")
            return
        }
        #expect(hal.removeCallCount(objectID: 42, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 2)
        #expect(hal.activeOSRegistrationCount == 0)
    }

    @Test func dedicatedHALContextSerializesBoundedParallelReadsAndRemove() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([42], inputStreamCounts: [42: 1])
        let backend = SystemCoreAudioBackend(hal: hal)
        let registration = try backend.observeRunningStateChanges(deviceID: .init(rawValue: 42)) {}
        hal.configureConcurrencyProbe(delay: 0.005)

        let completed = await boundedHALCompletion {
            let group = DispatchGroup()
            for _ in 0..<8 {
                group.enter()
                DispatchQueue.global().async {
                    _ = try? backend.isRunningSomewhere(deviceID: .init(rawValue: 42))
                    group.leave()
                }
            }
            group.enter()
            DispatchQueue.global().async {
                try? registration.cancel()
                group.leave()
            }
            return group.wait(timeout: .now() + 0.75) == .success
        }

        guard completed else {
            Issue.record("Timed out waiting for bounded HAL work")
            return
        }
        #expect(hal.maxConcurrentHALCalls == 1)
        #expect(hal.activeOSRegistrationCount == 0)
    }

    @Test func everyHALStatusMapsToItsDomainOperation() {
        assertStatus(-10, address: Self.deviceListAddress, phase: .size, operation: .enumerateDevices)
        assertStatus(-11, address: Self.deviceListAddress, phase: .data, operation: .enumerateDevices)
        assertStatus(-12, address: Self.inputStreamsAddress, phase: .size, operation: .inspectInputStreams)
        assertStatus(-13, address: Self.runningAddress, phase: .data, operation: .readRunningState)
        assertStatus(-14, address: Self.deviceListAddress, phase: .add, operation: .observeDeviceList)
        assertStatus(-15, address: Self.runningAddress, phase: .add, operation: .observeRunningState)
    }

    private enum FailurePhase { case size, data, add }

    private func assertStatus(
        _ status: OSStatus,
        address: CoreAudioPropertyAddress,
        phase: FailurePhase,
        operation: CoreAudioOperation
    ) {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        switch phase {
        case .size: hal.setSizeStatus(status, for: address)
        case .data: hal.setDataStatus(status, for: address)
        case .add: hal.setAddStatus(status, for: address)
        }
        expectError(.osStatus(operation: operation, status: status)) {
            let backend = SystemCoreAudioBackend(hal: hal)
            switch operation {
            case .enumerateDevices, .inspectInputStreams:
                _ = try backend.inputDeviceIDs()
            case .readRunningState:
                _ = try backend.isRunningSomewhere(deviceID: .init(rawValue: 10))
            case .observeDeviceList:
                _ = try backend.observeDeviceListChanges {}
            case .observeRunningState:
                _ = try backend.observeRunningStateChanges(deviceID: .init(rawValue: 10)) {}
            case .removeListener:
                Issue.record("removeListener is covered by retry test")
            }
        }
    }

    private func expectError(_ expected: CoreAudioError, _ work: () throws -> Void) {
        do {
            try work()
            Issue.record("Expected \(expected)")
        } catch let error as CoreAudioError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static let deviceListAddress = TestAddresses.deviceList
    private static let inputStreamsAddress = TestAddresses.inputStreams
    private static let runningAddress = TestAddresses.running
}

@MainActor
@Suite("CoreAudio monitor async integration")
struct CoreAudioMicrophoneMonitorTests {
    private let observedAt = Date(timeIntervalSince1970: 1_717_171_717)

    @Test func workerAggregatesOffMainAndEmptySuccessfulTopologyIsInactive() async {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10, 20], inputStreamCounts: [10: 1, 20: 1])
        hal.setRunning(0, deviceID: 10)
        hal.setRunning(1, deviceID: 20)
        let harness = makeHarness(hal: hal)

        harness.monitor.start()
        #expect(harness.states.values.isEmpty)
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .active)

        let emptyHAL = FakeCoreAudioHAL()
        emptyHAL.setDevices([], inputStreamCounts: [:])
        let emptyHarness = makeHarness(hal: emptyHAL)
        emptyHarness.monitor.start()
        guard await boundedDrain(emptyHarness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(emptyHarness.states.last?.status == .inactive)
    }

    @Test func productionBlockBridgeCoalescesBurstRefreshesAndResetsForLaterEvents() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRunning(0, deviceID: 10)
        let harness = makeHarness(hal: hal)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .inactive)

        hal.setRunning(1, deviceID: 10)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        #expect(harness.callbacks.pendingCount == 1)
        harness.callbacks.drain()
        #expect(harness.executor.pendingCount == 1)
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .active)
        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == 1)

        hal.setRunning(0, deviceID: 10)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .inactive)
        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == 1)
    }

    @Test func cancelledProductionBlockIsSynchronousNoOp() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        let harness = makeHarness(hal: hal)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        let stateCount = harness.states.values.count

        harness.monitor.stop()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        let stoppedCount = harness.states.values.count
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)

        #expect(stoppedCount == stateCount + 1)
        #expect(harness.callbacks.pendingCount == 0)
        #expect(harness.states.values.count == stoppedCount)
    }

    @Test func fireThenStopRestartInvalidatesOldSessionBeforeCallbackTaskDrains() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRunning(0, deviceID: 10)
        let harness = makeHarness(hal: hal)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }

        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        #expect(harness.callbacks.pendingCount == 1)
        harness.monitor.stop()
        hal.setRunning(1, deviceID: 10)
        harness.monitor.start()
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }

        #expect(harness.states.last?.status == .active)
        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == 2)
    }

    @Test func stopInvalidatesAQueuedStartByGeneration() async {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRunning(1, deviceID: 10)
        let harness = makeHarness(hal: hal)

        harness.monitor.start()
        harness.monitor.stop()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }

        #expect(harness.states.values.map(\.status) == [.unknown])
        #expect(hal.addCalls.isEmpty)
        #expect(hal.removeCalls.isEmpty)
    }

    @Test func blockedStartThenStopCannotAddAfterFinalShutdown() async {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        let harness = makeHarness(hal: hal)
        let blocker = BlockingHALHook()
        hal.setOneShotHALHook { blocker.block() }

        harness.monitor.start()
        let drainTask = Task { await boundedDrain(harness.executor) }
        let entered = await boundedHALCompletion {
            blocker.entered.wait(timeout: .now() + 0.75) == .success
        }
        guard entered else {
            blocker.release.signal()
            Issue.record("Timed out waiting for blocked HAL hook entry")
            return
        }
        harness.monitor.stop()
        blocker.release.signal()
        guard await drainTask.value else {
            Issue.record("Timed out draining blocked start/stop lifecycle")
            return
        }

        #expect(hal.activeOSRegistrationCount == 0)
        #expect(hal.addCallCount(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices) == 1)
        #expect(hal.removeCallCount(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices) == 1)
        #expect(harness.states.last?.metadata.reason == "CoreAudio microphone monitoring stopped")
    }

    @Test func pendingTopologyIntentRetriesAutonomouslyAfterCleanupRecovery() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10, 20], inputStreamCounts: [10: 1, 20: 1])
        hal.setRunning(1, deviceID: 10)
        hal.setRunning(0, deviceID: 20)
        hal.setRemoveStatuses([-70, -71, -72, noErr], objectID: 10, address: TestAddresses.running)
        let harness = makeHarness(hal: hal)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .active)

        hal.setDevices([20], inputStreamCounts: [20: 1])
        try hal.fireListener(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .unknown)
        #expect(hal.removeCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 1)

        hal.setDevices([10, 20], inputStreamCounts: [10: 1, 20: 1])
        try hal.fireListener(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .unknown)
        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == 2)
        #expect(hal.addCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 1)
        #expect(harness.refreshRetryScheduler.pendingCount == 1)
        #expect(harness.refreshRetryScheduler.observedDelays.count == 1)

        harness.refreshRetryScheduler.runNext()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .unknown)
        #expect(harness.refreshRetryScheduler.pendingCount == 1)
        #expect(harness.refreshRetryScheduler.observedDelays.count == 2)
        #expect(harness.refreshRetryScheduler.observedDelays[1] > harness.refreshRetryScheduler.observedDelays[0])

        harness.refreshRetryScheduler.runNext()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }

        #expect(hal.removeCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 4)
        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == 3)
        #expect(hal.addCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 2)
        #expect(hal.dataCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 2)
        #expect(harness.states.last?.status == .active)
        #expect(!harness.states.values.dropFirst().contains { $0.status == .inactive })
        #expect(harness.refreshRetryScheduler.pendingCount == 0)

        hal.setDataStatus(-73, objectID: 10, address: TestAddresses.running)
        try hal.fireListener(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.refreshRetryScheduler.pendingCount == 1)
        let topologyReadsBeforeStop = hal.dataCallCount(selector: kAudioHardwarePropertyDevices)
        harness.monitor.stop()
        harness.refreshRetryScheduler.runNext()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == topologyReadsBeforeStop)
        #expect(hal.activeOSRegistrationCount == 0)
    }

    @Test func topologyFailurePathsRecoverFromTheOnlyPendingTimer() async {
        for failure in InitialTopologyFailure.allCases {
            let hal = FakeCoreAudioHAL()
            hal.setDevices([10], inputStreamCounts: [10: 1])
            hal.setRunning(1, deviceID: 10)
            switch failure {
            case .enumeration:
                hal.setDataStatus(-101, for: TestAddresses.deviceList)
            case .systemListenerAdd:
                hal.setAddStatus(-102, for: TestAddresses.deviceList)
            case .deviceListenerAdd:
                hal.setAddStatus(-103, objectID: 10, address: TestAddresses.running)
            case .topologyRunningRead:
                hal.setDataStatus(-104, objectID: 10, address: TestAddresses.running)
            }
            let harness = makeHarness(hal: hal)

            harness.monitor.start()
            guard await boundedDrain(harness.executor) else {
                Issue.record("Timed out draining CoreAudio asynchronous work")
                return
            }
            #expect(harness.states.last?.status == .unknown, "failure: \(failure)")
            #expect(harness.refreshRetryScheduler.pendingCount == 1, "failure: \(failure)")

            switch failure {
            case .enumeration:
                hal.setDataStatus(noErr, for: TestAddresses.deviceList)
            case .systemListenerAdd:
                hal.setAddStatus(noErr, for: TestAddresses.deviceList)
            case .deviceListenerAdd:
                hal.setAddStatus(noErr, objectID: 10, address: TestAddresses.running)
            case .topologyRunningRead:
                hal.setDataStatus(noErr, objectID: 10, address: TestAddresses.running)
            }
            harness.refreshRetryScheduler.runNext()
            guard await boundedDrain(harness.executor) else {
                Issue.record("Timed out draining CoreAudio asynchronous work")
                return
            }

            #expect(harness.states.last?.status == .active, "failure: \(failure)")
            #expect(harness.refreshRetryScheduler.pendingCount == 0, "failure: \(failure)")
            harness.monitor.stop()
            guard await boundedDrain(harness.executor) else {
                Issue.record("Timed out draining CoreAudio asynchronous work")
                return
            }
        }
    }

    @Test func oldSessionTimerCannotMutateAReconciledRestart() async {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRunning(1, deviceID: 10)
        hal.setDataStatus(-111, for: TestAddresses.deviceList)
        let harness = makeHarness(hal: hal)

        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .unknown)
        #expect(harness.refreshRetryScheduler.pendingCount == 1)

        harness.monitor.stop()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        hal.setDataStatus(noErr, for: TestAddresses.deviceList)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .active)
        // Physical cancellation is unnecessary: the old closure remains but its identity is stale.
        #expect(harness.refreshRetryScheduler.pendingCount == 1)

        let callsBeforeOldTimer = hal.calls
        let addCountBeforeOldTimer = hal.addCalls.count
        let removeCountBeforeOldTimer = hal.removeCalls.count
        let statesBeforeOldTimer = harness.states.values
        harness.refreshRetryScheduler.runNext()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }

        #expect(hal.calls == callsBeforeOldTimer)
        #expect(hal.addCalls.count == addCountBeforeOldTimer)
        #expect(hal.removeCalls.count == removeCountBeforeOldTimer)
        #expect(harness.states.values == statesBeforeOldTimer)
        #expect(harness.refreshRetryScheduler.pendingCount == 0)
    }

    @Test func startStopsAtPendingCleanupFailureWithoutRefreshing() async {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRemoveStatuses([-80, -81], objectID: kAudioObjectSystemObject, address: TestAddresses.deviceList)
        hal.setRemoveStatuses([-82, -83], objectID: 10, address: TestAddresses.running)
        let harness = makeHarness(hal: hal)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == 1)

        harness.monitor.stop()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.metadata.reason?.contains("-80") == true)
        #expect(harness.states.last?.metadata.reason?.contains("-82") == true)
        #expect(hal.removeCallCount(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices) == 1)
        #expect(hal.removeCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 1)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }

        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == 1)
        #expect(harness.states.last?.status == .unknown)
        #expect(harness.states.last?.metadata.reason?.contains("-81") == true)
        #expect(harness.states.last?.metadata.reason?.contains("-83") == true)
        #expect(hal.removeCallCount(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices) == 2)
        #expect(hal.removeCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 2)
    }

    @Test func deinitRetriesRemovalAndResidualProductionBlockCannotPublish() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRemoveStatuses(Array(repeating: -90, count: 8), objectID: kAudioObjectSystemObject, address: TestAddresses.deviceList)
        hal.setRemoveStatuses(Array(repeating: -91, count: 8), objectID: 10, address: TestAddresses.running)
        let executor = SerialCoreAudioAsyncExecutor(manualExecution: true)
        let callbacks = QueuedCoreAudioCallbackScheduler()
        let cleanupScheduler = ManualCoreAudioCleanupRetryScheduler()
        let refreshRetryScheduler = ManualCoreAudioRefreshRetryScheduler()
        var cleanupCoordinator: CoreAudioCleanupCoordinator? = CoreAudioCleanupCoordinator(scheduler: cleanupScheduler)
        weak var weakCleanupCoordinator = cleanupCoordinator
        let states = StateRecorder()
        var monitor: CoreAudioMicrophoneMonitor? = makeMonitor(
            hal: hal,
            executor: executor,
            callbacks: callbacks,
            cleanupCoordinator: cleanupCoordinator!,
            refreshRetryScheduler: refreshRetryScheduler,
            states: states
        )
        monitor?.start()
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        let stateCount = states.values.count

        monitor = nil
        cleanupCoordinator = nil
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        callbacks.drain()
        #expect(states.values.count == stateCount)
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(hal.removeCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) >= 3)
        #expect(weakCleanupCoordinator?.retainedCount == 2)
        #expect(hal.activeOSRegistrationCount == 2)
        #expect(cleanupScheduler.pendingCount == 1)
        #expect(weakCleanupCoordinator != nil)

        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        callbacks.drain()
        #expect(states.values.count == stateCount)

        cleanupScheduler.runNext()
        #expect(weakCleanupCoordinator?.retainedCount == 2)
        #expect(hal.activeOSRegistrationCount == 2)
        #expect(cleanupScheduler.pendingCount == 1)
        #expect(weakCleanupCoordinator != nil)

        hal.setRemoveStatuses([noErr], objectID: kAudioObjectSystemObject, address: TestAddresses.deviceList)
        hal.setRemoveStatuses([noErr], objectID: 10, address: TestAddresses.running)
        cleanupScheduler.runNext()
        #expect(hal.activeOSRegistrationCount == 0)
        #expect(cleanupScheduler.pendingCount == 0)
        #expect(weakCleanupCoordinator == nil)
        #expect(cleanupScheduler.observedDelays.count == 2)
        #expect(cleanupScheduler.observedDelays.allSatisfy { $0 > 0 })
        #expect(cleanupScheduler.observedDelays[1] >= cleanupScheduler.observedDelays[0])
    }

    @Test func manualExecutorDeinitializesWhenMonitorQueuesUndrainedShutdown() async {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        let callbacks = QueuedCoreAudioCallbackScheduler()
        let cleanupScheduler = ManualCoreAudioCleanupRetryScheduler()
        let cleanupCoordinator = CoreAudioCleanupCoordinator(scheduler: cleanupScheduler)
        let refreshRetryScheduler = ManualCoreAudioRefreshRetryScheduler()
        let states = StateRecorder()
        var executor: SerialCoreAudioAsyncExecutor? = SerialCoreAudioAsyncExecutor(manualExecution: true)
        weak var weakExecutor = executor
        var monitor: CoreAudioMicrophoneMonitor? = makeMonitor(
            hal: hal,
            executor: executor!,
            callbacks: callbacks,
            cleanupCoordinator: cleanupCoordinator,
            refreshRetryScheduler: refreshRetryScheduler,
            states: states
        )

        monitor?.start()
        guard await boundedDrain(executor!) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        monitor?.stop()
        guard await boundedDrain(executor!) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(executor?.pendingCount == 0)

        // deinit enqueues one new manual shutdown closure. It must not retain the executor back.
        monitor = nil
        #expect(executor?.pendingCount == 1)
        executor = nil
        #expect(weakExecutor == nil)
    }

    @Test func productionQueuedShutdownOutlivesExecutorAndRemovesListeners() async {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        let callbacks = QueuedCoreAudioCallbackScheduler()
        let cleanupScheduler = ManualCoreAudioCleanupRetryScheduler()
        let cleanupCoordinator = CoreAudioCleanupCoordinator(scheduler: cleanupScheduler)
        let refreshRetryScheduler = ManualCoreAudioRefreshRetryScheduler()
        let states = StateRecorder()
        var executor: SerialCoreAudioAsyncExecutor? = SerialCoreAudioAsyncExecutor()
        weak var weakExecutor = executor
        var monitor: CoreAudioMicrophoneMonitor? = makeMonitor(
            hal: hal,
            executor: executor!,
            callbacks: callbacks,
            cleanupCoordinator: cleanupCoordinator,
            refreshRetryScheduler: refreshRetryScheduler,
            states: states
        )

        monitor?.start()
        guard await boundedDrain(executor!) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        guard hal.activeOSRegistrationCount > 0 else {
            Issue.record("Expected active CoreAudio registrations before queued shutdown")
            return
        }

        let blocker = BlockingHALHook()
        executor?.execute { blocker.block() }
        let entered = await boundedHALCompletion {
            blocker.entered.wait(timeout: .now() + 0.75) == .success
        }
        guard entered else {
            blocker.release.signal()
            Issue.record("Timed out waiting for production executor blocker")
            return
        }

        // shutdown is enqueued behind the blocker and owns worker -> context, never executor.
        monitor = nil
        executor = nil
        #expect(weakExecutor == nil)
        blocker.release.signal()

        let cleaned = await boundedHALCompletion(timeout: 2) {
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                if hal.activeOSRegistrationCount == 0 { return true }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return false
        }
        guard cleaned else {
            Issue.record("Timed out waiting for queued production shutdown cleanup")
            return
        }
        #expect(hal.activeOSRegistrationCount == 0)
    }

    @Test func missingDeviceListenerKeepsAggregateUnknownUntilTopologyRecovery() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10, 20], inputStreamCounts: [10: 1, 20: 1])
        hal.setRunning(0, deviceID: 10)
        hal.setRunning(1, deviceID: 20)
        hal.setAddStatus(-71, objectID: 20, address: TestAddresses.running)
        let harness = makeHarness(hal: hal)

        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .unknown)
        #expect(hal.addCallCount(objectID: 20, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 1)

        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .unknown)
        #expect(hal.addCallCount(objectID: 20, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 2)

        hal.setAddStatus(noErr, objectID: 20, address: TestAddresses.running)
        try hal.fireListener(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(hal.addCallCount(objectID: 20, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 3)
        #expect(harness.states.last?.status == .active)
    }

    @Test func deviceOnlyReadFailureRecoversFromTimerWithoutAnotherExternalEvent() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10, 20], inputStreamCounts: [10: 1, 20: 1])
        hal.setRunning(0, deviceID: 10)
        hal.setRunning(1, deviceID: 20)
        let harness = makeHarness(hal: hal)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .active)
        let topologyReads = hal.dataCallCount(selector: kAudioHardwarePropertyDevices)

        hal.setDataStatus(-72, objectID: 20, address: TestAddresses.running)
        try hal.fireListener(objectID: 20, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .unknown)
        #expect(harness.refreshRetryScheduler.pendingCount == 1)

        // A successful read for another device must not clear device 20's pending intent.
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .unknown)
        #expect(harness.refreshRetryScheduler.pendingCount == 1)

        hal.setDataStatus(noErr, objectID: 20, address: TestAddresses.running)
        harness.refreshRetryScheduler.runNext()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .active)
        #expect(harness.states.last?.metadata.source == "CoreAudio.DeviceIsRunningSomewhere")
        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == topologyReads)
        #expect(harness.refreshRetryScheduler.pendingCount == 0)
    }

    @Test func partialHALFailureIsUnknownAndSemanticDedupIgnoresObservedAtOnly() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setDataStatus(-50, for: TestAddresses.running)
        let clock = TestClock(date: observedAt)
        let harness = makeHarness(hal: hal, clock: clock)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.last?.status == .unknown)

        clock.date = observedAt.addingTimeInterval(60)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.states.values.count == 1)
        #expect(harness.states.last?.metadata.observedAt == observedAt)
    }

    @Test func meetingWatcherPublicSnapshotDocumentsAsyncLifecycleAndTopology() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRunning(1, deviceID: 10)
        let executor = SerialCoreAudioAsyncExecutor(manualExecution: true)
        let callbacks = QueuedCoreAudioCallbackScheduler()
        let backend = SystemCoreAudioBackend(hal: hal, callbackScheduler: callbacks)
        let watcher = MeetingWatcher(
            coreAudioBackend: backend,
            now: { observedAt },
            coreAudioExecutor: executor
        )
        let states = StateRecorder()
        let unsubscribe = watcher.subscribe { kind, state in
            if kind == .microphone { states.append(state) }
        }

        watcher.start()
        #expect(watcher.snapshot()[.microphone]?.status == .unknown)
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(watcher.snapshot()[.microphone]?.status == .active)

        hal.setDevices([], inputStreamCounts: [:])
        try hal.fireListener(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices)
        callbacks.drain()
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(watcher.snapshot()[.microphone]?.status == .inactive)

        watcher.stop()
        #expect(watcher.snapshot()[.microphone]?.status == .unknown)
        let count = states.values.count
        watcher.stop()
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(states.values.count == count)
        unsubscribe()
    }

    @Test func meetingWatcherStartFailureRecoversAndDoubleStartDoesNotDuplicateListeners() async {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRunning(1, deviceID: 10)
        hal.setAddStatus(-14, for: TestAddresses.deviceList)
        let executor = SerialCoreAudioAsyncExecutor(manualExecution: true)
        let callbacks = QueuedCoreAudioCallbackScheduler()
        let refreshRetryScheduler = ManualCoreAudioRefreshRetryScheduler()
        let watcher = MeetingWatcher(
            coreAudioBackend: SystemCoreAudioBackend(hal: hal, callbackScheduler: callbacks),
            now: { observedAt },
            coreAudioExecutor: executor,
            coreAudioRefreshRetryScheduler: refreshRetryScheduler
        )

        watcher.start()
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(watcher.snapshot()[.microphone]?.status == .unknown)

        hal.setAddStatus(noErr, for: TestAddresses.deviceList)
        watcher.start()
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        watcher.start()
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }

        #expect(watcher.snapshot()[.microphone]?.status == .active)
        #expect(hal.addCallCount(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices) == 2)
        #expect(hal.addCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 1)
    }

    @Test func eventAfterWorkerReadBeforeApplyProducesTrailingRefresh() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRunning(0, deviceID: 10)
        let harness = makeHarness(hal: hal, queueResults: true)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()
        #expect(harness.states.last?.status == .inactive)

        hal.setRunning(1, deviceID: 10)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.results.pendingCount == 1)

        hal.setRunning(0, deviceID: 10)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        harness.callbacks.drain()
        harness.results.drain()
        #expect(harness.executor.pendingCount == 1)
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()

        #expect(harness.states.values.map(\.status) == [.inactive, .active, .inactive])
        #expect(hal.dataCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 3)
    }

    @Test func deviceRequestReadsOnlyChangedDeviceAndTopologySupersedesDirtyDevices() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10, 20], inputStreamCounts: [10: 1, 20: 1])
        let harness = makeHarness(hal: hal, queueResults: true)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()
        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == 1)

        hal.setRunning(1, deviceID: 10)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }

        try hal.fireListener(objectID: 20, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        try hal.fireListener(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices)
        harness.callbacks.drain()
        harness.results.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()

        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == 2)
        #expect(hal.dataCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 3)
        #expect(hal.dataCallCount(objectID: 20, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 2)
        #expect(CoreAudioRefreshRequest.devices([.init(rawValue: 10)]).merging(
            .devices([.init(rawValue: 20)])
        ) == .devices([.init(rawValue: 10), .init(rawValue: 20)]))
        #expect(CoreAudioRefreshRequest.devices([.init(rawValue: 10)]).merging(.topology) == .topology)
    }

    @Test func mergedDeviceRefreshReconcilesSuccessAndRetriesOnlyFailedDevice() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10, 20], inputStreamCounts: [10: 1, 20: 1])
        hal.setRunning(1, deviceID: 10)
        hal.setRunning(0, deviceID: 20)
        let harness = makeHarness(hal: hal, queueResults: true)

        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.results.pendingCount == 1)

        // Listeners already exist while the staged start result keeps lifecycleInFlight occupied.
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        try hal.fireListener(objectID: 20, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        #expect(harness.callbacks.pendingCount == 2)
        harness.callbacks.drain()
        hal.setDataStatus(-121, objectID: 20, address: TestAddresses.running)
        harness.results.drain()
        #expect(harness.executor.pendingCount == 1)

        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()
        #expect(harness.states.last?.status == .unknown)
        #expect(harness.refreshRetryScheduler.pendingCount == 1)
        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == 1)
        #expect(hal.dataCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 2)
        #expect(hal.dataCallCount(objectID: 20, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 2)

        hal.setDataStatus(noErr, objectID: 20, address: TestAddresses.running)
        harness.refreshRetryScheduler.runNext()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()

        #expect(harness.states.last?.status == .active)
        #expect(harness.refreshRetryScheduler.pendingCount == 0)
        #expect(hal.dataCallCount(selector: kAudioHardwarePropertyDevices) == 1)
        #expect(hal.dataCallCount(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 2)
        #expect(hal.dataCallCount(objectID: 20, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 3)
    }

    @Test func stagedStartResultThenFinalStopLeavesNoListener() async {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        let harness = makeHarness(hal: hal, queueResults: true)

        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.results.pendingCount == 1)
        harness.monitor.stop()
        #expect(harness.states.last?.metadata.reason == "CoreAudio microphone monitoring stopped")

        harness.results.drain()
        #expect(harness.executor.pendingCount == 1)
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()
        #expect(hal.activeOSRegistrationCount == 0)
        #expect(harness.states.last?.status == .unknown)
        #expect(harness.states.last?.metadata.reason == "CoreAudio microphone monitoring stopped")
        #expect(harness.states.last?.metadata.source == "CoreAudio.DeviceIsRunningSomewhere")
    }

    @Test func stagedRefreshResultThenFinalStopCannotRepublish() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRunning(1, deviceID: 10)
        let harness = makeHarness(hal: hal, queueResults: true)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()
        #expect(harness.states.last?.status == .active)

        hal.setRunning(0, deviceID: 10)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        harness.callbacks.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(harness.results.pendingCount == 1)
        harness.monitor.stop()
        harness.results.drain()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()

        #expect(hal.activeOSRegistrationCount == 0)
        #expect(harness.states.last?.status == .unknown)
        #expect(harness.states.last?.metadata.reason == "CoreAudio microphone monitoring stopped")
    }

    @Test func startStopStartStopCollapsesToFinalStop() async {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        let harness = makeHarness(hal: hal, queueResults: true)
        harness.monitor.start()
        harness.monitor.stop()
        harness.monitor.start()
        harness.monitor.stop()
        #expect(harness.executor.pendingCount == 1)

        guard await boundedDrain(harness.executor) else {

            Issue.record("Timed out draining CoreAudio asynchronous work")

            return

        }
        harness.results.drain()
        #expect(harness.executor.pendingCount == 1)
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()
        #expect(hal.activeOSRegistrationCount == 0)
        #expect(harness.states.last?.status == .unknown)
        #expect(harness.states.last?.metadata.reason == "CoreAudio microphone monitoring stopped")
    }

    @Test func currentStopErrorsPublishButSupersededStopErrorsDoNot() async {
        let currentHAL = FakeCoreAudioHAL()
        currentHAL.setDevices([10], inputStreamCounts: [10: 1])
        let current = makeHarness(hal: currentHAL, queueResults: true)
        current.monitor.start()
        guard await boundedDrain(current.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        current.results.drain()
        currentHAL.setRemoveStatuses([-80], objectID: kAudioObjectSystemObject, address: TestAddresses.deviceList)
        currentHAL.setRemoveStatuses([-82], objectID: 10, address: TestAddresses.running)
        current.monitor.stop()
        guard await boundedDrain(current.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        current.results.drain()
        #expect(current.states.last?.metadata.reason?.contains("-80") == true)
        #expect(current.states.last?.metadata.reason?.contains("-82") == true)
        #expect(current.states.last?.metadata.source == "CoreAudio.DeviceIsRunningSomewhere")

        let supersededHAL = FakeCoreAudioHAL()
        supersededHAL.setDevices([10], inputStreamCounts: [10: 1])
        let superseded = makeHarness(hal: supersededHAL, queueResults: true)
        superseded.monitor.start()
        guard await boundedDrain(superseded.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        superseded.results.drain()
        supersededHAL.setRemoveStatuses([-90], objectID: kAudioObjectSystemObject, address: TestAddresses.deviceList)
        supersededHAL.setRemoveStatuses([-92], objectID: 10, address: TestAddresses.running)
        superseded.monitor.stop()
        guard await boundedDrain(superseded.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        superseded.monitor.start()
        superseded.monitor.stop()
        superseded.results.drain()
        guard await boundedDrain(superseded.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        superseded.results.drain()

        #expect(supersededHAL.activeOSRegistrationCount == 0)
        #expect(superseded.states.last?.metadata.reason == "CoreAudio microphone monitoring stopped")
        #expect(superseded.states.values.allSatisfy { $0.metadata.reason?.contains("-90") != true })
        #expect(superseded.states.values.allSatisfy { $0.metadata.reason?.contains("-92") != true })
    }

    @Test func rapidLifecycleUsesOneExecutorTaskAndReconcilesOldGate() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        let harness = makeHarness(hal: hal, queueResults: true)
        harness.monitor.start()
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()
        #expect(hal.activeOSRegistrationCount == 2)

        for _ in 0..<50 {
            harness.monitor.stop()
            harness.monitor.start()
        }
        #expect(harness.executor.pendingCount == 1)
        #expect(harness.executor.maximumPendingCount == 1)
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()
        #expect(harness.executor.pendingCount == 1)
        guard await boundedDrain(harness.executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        harness.results.drain()

        #expect(harness.executor.maximumPendingCount == 1)
        #expect(hal.addCallCount(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices) == 2)
        #expect(hal.removeCallCount(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices) == 1)
        #expect(hal.activeOSRegistrationCount == 2)

        try hal.fireListener(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices, occurrence: 0)
        #expect(harness.callbacks.pendingCount == 0)
        try hal.fireListener(objectID: kAudioObjectSystemObject, selector: kAudioHardwarePropertyDevices, occurrence: 1)
        #expect(harness.callbacks.pendingCount == 1)
    }

    @Test func externalMicrophoneOverrideInvalidatesMonitorSemanticDedupOnlyWhenChanged() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRunning(1, deviceID: 10)
        let executor = SerialCoreAudioAsyncExecutor(manualExecution: true)
        let callbacks = QueuedCoreAudioCallbackScheduler()
        let clock = TestClock(date: observedAt)
        let watcher = MeetingWatcher(
            coreAudioBackend: SystemCoreAudioBackend(hal: hal, callbackScheduler: callbacks),
            now: { clock.date },
            coreAudioExecutor: executor
        )
        var notifications: [RawSignalState] = []
        _ = watcher.subscribe { kind, state in
            if kind == .microphone { notifications.append(state) }
        }
        watcher.start()
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        let monitoredActive = try #require(watcher.snapshot()[.microphone])
        #expect(monitoredActive.status == .active)
        #expect(notifications.count == 1)

        watcher.updateSignal(.microphone, to: monitoredActive)
        clock.date = observedAt.addingTimeInterval(10)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        callbacks.drain()
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(watcher.snapshot()[.microphone] == monitoredActive)
        #expect(notifications.count == 1)

        watcher.updateSignal(.microphone, to: RawSignalState(status: .inactive))
        #expect(watcher.snapshot()[.microphone]?.status == .inactive)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        callbacks.drain()
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(watcher.snapshot()[.microphone]?.status == .active)
        #expect(notifications.count == 3)
    }

    @Test func productionSerialExecutorAndTaskCallbackSchedulerSmoke() async throws {
        let hal = FakeCoreAudioHAL()
        hal.setDevices([10], inputStreamCounts: [10: 1])
        hal.setRunning(1, deviceID: 10)
        let executor = SerialCoreAudioAsyncExecutor()
        let callbacks = TaskCoreAudioCallbackScheduler()
        for _ in 0..<3 {
            var sentinel: CallbackLifetimeSentinel? = CallbackLifetimeSentinel()
            weak var weakSentinel = sentinel
            callbacks.schedule { [sentinel] in _ = sentinel }
            sentinel = nil
            guard await boundedDrain(callbacks) else {
                Issue.record("Timed out draining CoreAudio asynchronous work")
                return
            }
            await Task.yield()
            #expect(callbacks.retainedTaskCount == 0)
            #expect(weakSentinel == nil)
        }
        let cleanupScheduler = ManualCoreAudioCleanupRetryScheduler()
        let cleanup = CoreAudioCleanupCoordinator(scheduler: cleanupScheduler)
        let states = StateRecorder()
        let monitor = CoreAudioMicrophoneMonitor(
            backend: SystemCoreAudioBackend(hal: hal, callbackScheduler: callbacks),
            executor: executor,
            cleanupCoordinator: cleanup,
            now: { observedAt },
            stateHandler: { states.append($0) }
        )

        monitor.start()
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(states.last?.status == .active)
        #expect(hal.allHALCallsWereOffMain)
        hal.setRunning(0, deviceID: 10)
        try hal.fireListener(objectID: 10, selector: kAudioDevicePropertyDeviceIsRunningSomewhere)
        guard await boundedDrain(callbacks) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(callbacks.retainedTaskCount == 0)
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(states.last?.status == .inactive)
        monitor.stop()
        guard await boundedDrain(executor) else {
            Issue.record("Timed out draining CoreAudio asynchronous work")
            return
        }
        #expect(hal.activeOSRegistrationCount == 0)
        #expect(hal.allHALCallsWereOffMain)
    }

    private enum InitialTopologyFailure: CaseIterable {
        case enumeration
        case systemListenerAdd
        case deviceListenerAdd
        case topologyRunningRead
    }

    private func makeHarness(
        hal: FakeCoreAudioHAL,
        clock: TestClock? = nil,
        queueResults: Bool = false
    ) -> MonitorHarness {
        let executor = SerialCoreAudioAsyncExecutor(manualExecution: true)
        let callbacks = QueuedCoreAudioCallbackScheduler()
        let results = QueuedCoreAudioResultScheduler()
        let cleanupScheduler = ManualCoreAudioCleanupRetryScheduler()
        let refreshRetryScheduler = ManualCoreAudioRefreshRetryScheduler()
        let cleanupCoordinator = CoreAudioCleanupCoordinator(scheduler: cleanupScheduler)
        let states = StateRecorder()
        let resultScheduler: CoreAudioMicrophoneMonitor.ResultScheduler
        if queueResults {
            resultScheduler = { results.schedule($0) }
        } else {
            resultScheduler = { $0() }
        }
        let monitor = makeMonitor(
            hal: hal,
            executor: executor,
            callbacks: callbacks,
            cleanupCoordinator: cleanupCoordinator,
            refreshRetryScheduler: refreshRetryScheduler,
            resultScheduler: resultScheduler,
            states: states,
            clock: clock
        )
        return MonitorHarness(
            monitor: monitor,
            executor: executor,
            callbacks: callbacks,
            results: results,
            cleanupScheduler: cleanupScheduler,
            refreshRetryScheduler: refreshRetryScheduler,
            cleanupCoordinator: cleanupCoordinator,
            states: states
        )
    }

    private func makeMonitor(
        hal: FakeCoreAudioHAL,
        executor: SerialCoreAudioAsyncExecutor,
        callbacks: any CoreAudioCallbackScheduling,
        cleanupCoordinator: CoreAudioCleanupCoordinator,
        refreshRetryScheduler: any CoreAudioRefreshRetryScheduling,
        resultScheduler: @escaping CoreAudioMicrophoneMonitor.ResultScheduler = { $0() },
        states: StateRecorder,
        clock: TestClock? = nil
    ) -> CoreAudioMicrophoneMonitor {
        let date = observedAt
        let backend = SystemCoreAudioBackend(hal: hal, callbackScheduler: callbacks)
        return CoreAudioMicrophoneMonitor(
            backend: backend,
            executor: executor,
            cleanupCoordinator: cleanupCoordinator,
            refreshRetryScheduler: refreshRetryScheduler,
            resultScheduler: resultScheduler,
            now: { clock?.date ?? date },
            stateHandler: { states.append($0) }
        )
    }
}

@MainActor
private struct MonitorHarness {
    let monitor: CoreAudioMicrophoneMonitor
    let executor: SerialCoreAudioAsyncExecutor
    let callbacks: QueuedCoreAudioCallbackScheduler
    let results: QueuedCoreAudioResultScheduler
    let cleanupScheduler: ManualCoreAudioCleanupRetryScheduler
    let refreshRetryScheduler: ManualCoreAudioRefreshRetryScheduler
    let cleanupCoordinator: CoreAudioCleanupCoordinator
    let states: StateRecorder
}

nonisolated private enum TestAddresses {
    static let deviceList = CoreAudioPropertyAddress(
        selector: kAudioHardwarePropertyDevices,
        scope: kAudioObjectPropertyScopeGlobal,
        element: kAudioObjectPropertyElementMain
    )
    static let inputStreams = CoreAudioPropertyAddress(
        selector: kAudioDevicePropertyStreams,
        scope: kAudioDevicePropertyScopeInput,
        element: kAudioObjectPropertyElementMain
    )
    static let running = CoreAudioPropertyAddress(
        selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        scope: kAudioObjectPropertyScopeGlobal,
        element: kAudioObjectPropertyElementMain
    )
}

@MainActor
private final class QueuedCoreAudioResultScheduler {
    private var workItems: [@MainActor @Sendable () -> Void] = []
    var pendingCount: Int { workItems.count }

    func schedule(_ work: @escaping @MainActor @Sendable () -> Void) {
        workItems.append(work)
    }

    func drain() {
        while !workItems.isEmpty { workItems.removeFirst()() }
    }
}

nonisolated private final class ManualCoreAudioCleanupRetryScheduler: CoreAudioCleanupRetryScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var workItems: [@Sendable () -> Void] = []
    private(set) var observedDelays: [TimeInterval] = []

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return workItems.count
    }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        lock.lock()
        observedDelays.append(delay)
        workItems.append(work)
        lock.unlock()
    }

    func runNext() {
        lock.lock()
        let work = workItems.isEmpty ? nil : workItems.removeFirst()
        lock.unlock()
        work?()
    }
}

nonisolated private final class ManualCoreAudioRefreshRetryScheduler: CoreAudioRefreshRetryScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var workItems: [@MainActor @Sendable () -> Void] = []
    private var delays: [TimeInterval] = []

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return workItems.count
    }

    var observedDelays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }

    func schedule(
        after delay: TimeInterval,
        _ work: @escaping @MainActor @Sendable () -> Void
    ) {
        lock.lock()
        delays.append(delay)
        workItems.append(work)
        lock.unlock()
    }

    @MainActor
    func runNext() {
        lock.lock()
        let work = workItems.isEmpty ? nil : workItems.removeFirst()
        lock.unlock()
        work?()
    }
}

nonisolated private final class QueuedCoreAudioCallbackScheduler: CoreAudioCallbackScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var workItems: [@MainActor @Sendable () -> Void] = []

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return workItems.count
    }

    func schedule(_ work: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        workItems.append(work)
        lock.unlock()
    }

    @MainActor
    func drain() {
        while true {
            lock.lock()
            let work = workItems.isEmpty ? nil : workItems.removeFirst()
            lock.unlock()
            guard let work else { return }
            work()
        }
    }
}

nonisolated private final class CallbackLifetimeSentinel: @unchecked Sendable {}

nonisolated private final class BoundedCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Bool, Never>

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        continuation.resume(returning: result)
    }
}

nonisolated private func boundedHALCompletion(
    timeout: TimeInterval = 1,
    _ work: @escaping @Sendable () -> Bool
) async -> Bool {
    await withCheckedContinuation { continuation in
        let gate = BoundedCompletionGate(continuation: continuation)
        DispatchQueue.global().async { gate.finish(work()) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.finish(false) }
    }
}

nonisolated private func boundedAsyncCompletion(
    timeout: TimeInterval = 2,
    _ work: @escaping @Sendable () async -> Void
) async -> Bool {
    await withCheckedContinuation { continuation in
        let gate = BoundedCompletionGate(continuation: continuation)
        Task {
            await work()
            gate.finish(true)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            gate.finish(false)
        }
    }
}

nonisolated private func boundedDrain(
    _ executor: SerialCoreAudioAsyncExecutor
) async -> Bool {
    // A timed-out operation may remain blocked; every caller guards and returns before reading
    // fixture locks, so a bridge regression becomes a bounded test failure rather than a suite hang.
    await boundedAsyncCompletion { await executor.drain() }
}

nonisolated private func boundedDrain(
    _ scheduler: TaskCoreAudioCallbackScheduler
) async -> Bool {
    await boundedAsyncCompletion { await scheduler.drain() }
}

nonisolated private final class BlockingHALHook: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func block() {
        entered.signal()
        _ = release.wait(timeout: .now() + 1)
    }
}

@MainActor
private final class StateRecorder: @unchecked Sendable {
    private(set) var values: [RawSignalState] = []
    var last: RawSignalState? { values.last }

    func append(_ state: RawSignalState) {
        values.append(state)
    }
}

@MainActor
private final class TestClock {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}

nonisolated private final class FakeCoreAudioHAL: CoreAudioHAL, @unchecked Sendable {
    nonisolated enum Call: Equatable {
        case has(AudioObjectID, CoreAudioPropertyAddress)
        case size(AudioObjectID, CoreAudioPropertyAddress)
        case data(AudioObjectID, CoreAudioPropertyAddress)
    }

    nonisolated struct ListenerCall {
        let objectID: AudioObjectID
        let address: CoreAudioPropertyAddress
        let queue: DispatchQueue
        let listener: CoreAudioPropertyListener
    }

    nonisolated private struct PropertyKey: Hashable {
        let objectID: AudioObjectID
        let address: CoreAudioPropertyAddress
    }

    private let lock = NSLock()
    private let concurrencyProbeLock = NSLock()
    private let hookLock = NSLock()
    private var oneShotHALHook: ( () -> Void)?
    private var concurrentHALCalls = 0
    private var maximumConcurrentHALCalls = 0
    private var halCallDelay: TimeInterval = 0
    private var deviceIDs: [AudioDeviceID] = []
    private var inputStreamCounts: [AudioDeviceID: Int] = [:]
    private var runningStates: [AudioDeviceID: UInt32] = [:]
    private var hasPropertyOverrides: [PropertyKey: Bool] = [:]
    private var propertySizeOverrides: [PropertyKey: UInt32] = [:]
    private var deviceListInitialSize: UInt32?
    private var returnedDataSizes: [CoreAudioPropertyAddress: UInt32] = [:]
    private var sizeStatuses: [CoreAudioPropertyAddress: OSStatus] = [:]
    private var dataStatuses: [CoreAudioPropertyAddress: OSStatus] = [:]
    private var dataStatusOverrides: [PropertyKey: OSStatus] = [:]
    private var addStatuses: [CoreAudioPropertyAddress: OSStatus] = [:]
    private var addStatusOverrides: [PropertyKey: OSStatus] = [:]
    private var removeStatuses: [PropertyKey: [OSStatus]] = [:]
    private var recordedCalls: [Call] = []
    private var recordedAddCalls: [ListenerCall] = []
    private var recordedRemoveCalls: [ListenerCall] = []
    private var recordedMainThreadFlags: [Bool] = []
    private var activeRegistrations: [ObjectIdentifier: ListenerCall] = [:]

    var calls: [Call] { withLock { recordedCalls } }
    var addCalls: [ListenerCall] { withLock { recordedAddCalls } }
    var removeCalls: [ListenerCall] { withLock { recordedRemoveCalls } }
    var activeOSRegistrationCount: Int { withLock { activeRegistrations.count } }
    var allHALCallsWereOffMain: Bool {
        withLock { !recordedMainThreadFlags.isEmpty && recordedMainThreadFlags.allSatisfy { !$0 } }
    }
    var maxConcurrentHALCalls: Int {
        concurrencyProbeLock.lock()
        defer { concurrencyProbeLock.unlock() }
        return maximumConcurrentHALCalls
    }

    func setOneShotHALHook(_ hook: @escaping @Sendable () -> Void) {
        hookLock.lock()
        oneShotHALHook = hook
        hookLock.unlock()
    }

    func configureConcurrencyProbe(delay: TimeInterval) {
        concurrencyProbeLock.lock()
        maximumConcurrentHALCalls = concurrentHALCalls
        halCallDelay = delay
        concurrencyProbeLock.unlock()
    }

    func setDevices(_ ids: [AudioDeviceID], inputStreamCounts: [AudioDeviceID: Int]) {
        withLock { deviceIDs = ids; self.inputStreamCounts = inputStreamCounts }
    }

    func setRunning(_ value: UInt32, deviceID: AudioDeviceID) {
        withLock { runningStates[deviceID] = value }
    }

    func setHasProperty(_ value: Bool, objectID: AudioObjectID, address: CoreAudioPropertyAddress) {
        withLock { hasPropertyOverrides[.init(objectID: objectID, address: address)] = value }
    }

    func setPropertySize(_ value: UInt32, objectID: AudioObjectID, address: CoreAudioPropertyAddress) {
        withLock { propertySizeOverrides[.init(objectID: objectID, address: address)] = value }
    }

    func setDeviceListInitialSize(_ value: UInt32) { withLock { deviceListInitialSize = value } }
    func setReturnedDataSize(_ value: UInt32, for address: CoreAudioPropertyAddress) { withLock { returnedDataSizes[address] = value } }
    func setSizeStatus(_ value: OSStatus, for address: CoreAudioPropertyAddress) { withLock { sizeStatuses[address] = value } }
    func setDataStatus(_ value: OSStatus, for address: CoreAudioPropertyAddress) { withLock { dataStatuses[address] = value } }
    func setDataStatus(_ value: OSStatus, objectID: AudioObjectID, address: CoreAudioPropertyAddress) {
        withLock { dataStatusOverrides[.init(objectID: objectID, address: address)] = value }
    }
    func setAddStatus(_ value: OSStatus, for address: CoreAudioPropertyAddress) { withLock { addStatuses[address] = value } }
    func setAddStatus(_ value: OSStatus, objectID: AudioObjectID, address: CoreAudioPropertyAddress) {
        withLock { addStatusOverrides[.init(objectID: objectID, address: address)] = value }
    }

    func setRemoveStatuses(
        _ values: [OSStatus],
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress
    ) {
        withLock { removeStatuses[.init(objectID: objectID, address: address)] = values }
    }

    func dataCallCount(selector: UInt32) -> Int {
        calls.filter { if case let .data(_, address) = $0 { return address.selector == selector }; return false }.count
    }

    func dataCallCount(objectID: AudioObjectID, selector: UInt32) -> Int {
        calls.filter {
            if case let .data(id, address) = $0 { return id == objectID && address.selector == selector }
            return false
        }.count
    }

    func sizeCallCount(objectID: AudioObjectID, selector: UInt32) -> Int {
        calls.filter { if case let .size(id, address) = $0 { return id == objectID && address.selector == selector }; return false }.count
    }

    func addCallCount(objectID: AudioObjectID, selector: UInt32) -> Int {
        addCalls.filter { $0.objectID == objectID && $0.address.selector == selector }.count
    }

    func removeCallCount(objectID: AudioObjectID, selector: UInt32) -> Int {
        removeCalls.filter { $0.objectID == objectID && $0.address.selector == selector }.count
    }

    @MainActor
    func fireListener(objectID: AudioObjectID, selector: UInt32, occurrence: Int = 0) throws {
        let matches = addCalls.filter { $0.objectID == objectID && $0.address.selector == selector }
        let call = try #require(matches.indices.contains(occurrence) ? matches[occurrence] : nil)
        var rawAddress = AudioObjectPropertyAddress(
            mSelector: call.address.selector,
            mScope: call.address.scope,
            mElement: call.address.element
        )
        withUnsafePointer(to: &rawAddress) { pointer in
            call.listener.block(1, pointer)
        }
    }

    func hasProperty(objectID: AudioObjectID, address: CoreAudioPropertyAddress) -> Bool {
        beginHALCall()
        defer { endHALCall() }
        return withLock {
            recordedMainThreadFlags.append(Thread.isMainThread)
            recordedCalls.append(.has(objectID, address))
            let key = PropertyKey(objectID: objectID, address: address)
            return hasPropertyOverrides[key] ?? (inputStreamCounts[objectID] != nil)
        }
    }

    func propertyDataSize(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        dataSize: inout UInt32
    ) -> OSStatus {
        beginHALCall()
        defer { endHALCall() }
        return withLock {
            recordedMainThreadFlags.append(Thread.isMainThread)
            recordedCalls.append(.size(objectID, address))
            if let status = sizeStatuses[address], status != noErr { return status }
            let key = PropertyKey(objectID: objectID, address: address)
            if let override = propertySizeOverrides[key] {
                dataSize = override
            } else if address.selector == kAudioHardwarePropertyDevices {
                dataSize = deviceListInitialSize
                    ?? UInt32(deviceIDs.count * MemoryLayout<AudioDeviceID>.size)
            } else if address.selector == kAudioDevicePropertyStreams {
                dataSize = UInt32((inputStreamCounts[objectID] ?? 0) * MemoryLayout<AudioStreamID>.size)
            }
            return noErr
        }
    }

    func propertyData(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        beginHALCall()
        defer { endHALCall() }
        return withLock {
            recordedMainThreadFlags.append(Thread.isMainThread)
            recordedCalls.append(.data(objectID, address))
            let key = PropertyKey(objectID: objectID, address: address)
            if let status = dataStatusOverrides[key] ?? dataStatuses[address], status != noErr { return status }
            if address.selector == kAudioHardwarePropertyDevices {
                let capacity = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
                for (index, deviceID) in deviceIDs.prefix(capacity).enumerated() {
                    data.storeBytes(of: deviceID, toByteOffset: index * MemoryLayout<AudioDeviceID>.size, as: AudioDeviceID.self)
                }
                dataSize = UInt32(deviceIDs.count * MemoryLayout<AudioDeviceID>.size)
            } else if address.selector == kAudioDevicePropertyDeviceIsRunningSomewhere {
                data.storeBytes(of: runningStates[objectID] ?? 0, as: UInt32.self)
                dataSize = UInt32(MemoryLayout<UInt32>.size)
            }
            if let override = returnedDataSizes[address] { dataSize = override }
            return noErr
        }
    }

    func addPropertyListener(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListener
    ) -> OSStatus {
        beginHALCall()
        defer { endHALCall() }
        return withLock {
            recordedMainThreadFlags.append(Thread.isMainThread)
            let call = ListenerCall(objectID: objectID, address: address, queue: queue, listener: listener)
            recordedAddCalls.append(call)
            let key = PropertyKey(objectID: objectID, address: address)
            let status = addStatusOverrides[key] ?? addStatuses[address] ?? noErr
            if status == noErr { activeRegistrations[ObjectIdentifier(listener)] = call }
            return status
        }
    }

    func removePropertyListener(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListener
    ) -> OSStatus {
        beginHALCall()
        defer { endHALCall() }
        return withLock {
            recordedMainThreadFlags.append(Thread.isMainThread)
            let call = ListenerCall(objectID: objectID, address: address, queue: queue, listener: listener)
            recordedRemoveCalls.append(call)
            let key = PropertyKey(objectID: objectID, address: address)
            var statuses = removeStatuses[key] ?? []
            let status = statuses.isEmpty ? noErr : statuses.removeFirst()
            removeStatuses[key] = statuses
            if status == noErr,
               let active = activeRegistrations[ObjectIdentifier(listener)],
               active.objectID == objectID, active.address == address, active.queue === queue {
                activeRegistrations[ObjectIdentifier(listener)] = nil
            }
            return status
        }
    }

    private func beginHALCall() {
        concurrencyProbeLock.lock()
        concurrentHALCalls += 1
        maximumConcurrentHALCalls = max(maximumConcurrentHALCalls, concurrentHALCalls)
        let delay = halCallDelay
        concurrencyProbeLock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        hookLock.lock()
        let hook = oneShotHALHook
        oneShotHALHook = nil
        hookLock.unlock()
        hook?()
    }

    private func endHALCall() {
        concurrencyProbeLock.lock()
        concurrentHALCalls -= 1
        concurrencyProbeLock.unlock()
    }

    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}
