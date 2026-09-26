// FineTune/Audio/Engine/TapResources.swift
import AudioToolbox
import os

/// Encapsulates Core Audio tap and aggregate device resources.
/// Provides safe cleanup with correct teardown order.
///
/// **Teardown order is critical:**
/// 1. Stop device proc (AudioDeviceStop)
/// 2. Destroy IO proc ID (AudioDeviceDestroyIOProcID) — blocks until callback finishes
/// 3. Destroy aggregate device (AudioHardwareDestroyAggregateDevice)
/// 4. Destroy process tap (AudioHardwareDestroyProcessTap)
///
/// Violating this order can leak HAL resources or crash on shutdown.
nonisolated struct TapResources {
    private static let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "TapResources")
    /// Tracks fire-and-forget HAL teardown that may outlive its controller after a stale
    /// tap or ignored app is removed from `AudioEngine.taps`.
    private static let pendingDestructionGroup = DispatchGroup()

    var tapID: AudioObjectID = .unknown
    var aggregateDeviceID: AudioObjectID = .unknown
    var deviceProcID: AudioDeviceIOProcID?
    var tapDescription: CATapDescription?
    var aggregateUID: String?
    var serviceGeneration = AudioServiceGeneration.current
    private var pendingCleanup: CleanupJob?
    var cleanupOperations = CleanupOperations.live

    /// Instance-scoped dependency injection for deterministic teardown failure tests.
    struct CleanupOperations: Sendable {
        var identity: @Sendable (AudioObjectID, String?, UInt64, AudioObjectPropertySelector) -> Identity
        var stop: @Sendable (AudioObjectID, AudioDeviceIOProcID) -> OSStatus
        var join: @Sendable (AudioObjectID, AudioDeviceIOProcID) -> OSStatus
        var destroyAggregate: @Sendable (AudioObjectID) -> OSStatus
        var destroyTap: @Sendable (AudioObjectID) -> OSStatus
        static let live = CleanupOperations(
            identity: { TapResources.identity($0, uid: $1, generation: $2, selector: $3) },
            stop: { AudioDeviceStop($0, $1) }, join: { AudioDeviceDestroyIOProcID($0, $1) },
            destroyAggregate: { AudioHardwareDestroyAggregateDevice($0) },
            destroyTap: { AudioHardwareDestroyProcessTap($0) })
    }

    static func identityMatches(createdGeneration: UInt64, currentGeneration: UInt64,
                                expectedUID: String?, observedUID: String?) -> Bool {
        createdGeneration == currentGeneration && expectedUID != nil && expectedUID == observedUID
    }

    enum Identity: Equatable { case owned, gone, unknown }

    static func classifyIdentity(createdGeneration: UInt64, currentGeneration: UInt64,
                                 expectedUID: String?, observedUID: String?, status: OSStatus) -> Identity {
        if createdGeneration != currentGeneration || status == kAudioHardwareBadObjectError { return .gone }
        guard status == noErr, let observedUID, let expectedUID else { return .unknown }
        return observedUID == expectedUID ? .owned : .gone
    }

    private static func identity(_ id: AudioObjectID, uid: String?, generation: UInt64,
                                 selector: AudioObjectPropertySelector) -> Identity {
        guard id.isValid, generation == AudioServiceGeneration.current else { return .gone }
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        let observedUID = value?.takeRetainedValue() as String?
        // HAL IPC can straddle a restart: read the epoch AFTER the query.
        return classifyIdentity(createdGeneration: generation, currentGeneration: AudioServiceGeneration.current,
                                expectedUID: uid, observedUID: observedUID, status: status)
    }

    private static func owns(_ id: AudioObjectID, uid: String?, generation: UInt64,
                             selector: AudioObjectPropertySelector) -> Bool {
        identity(id, uid: uid, generation: generation, selector: selector) == .owned
    }

    var hasMatchingIdentity: Bool {
        // An unknown read is not proof that a healthy (possibly paused) graph died.
        Self.identity(tapID, uid: tapDescription?.uuid.uuidString, generation: serviceGeneration,
                      selector: kAudioTapPropertyUID) != .gone
        && Self.identity(aggregateDeviceID, uid: aggregateUID, generation: serviceGeneration,
                         selector: kAudioDevicePropertyDeviceUID) != .gone
    }

    /// The server already destroyed these objects. In particular, do not untrack a
    /// reused numeric ID which may now belong to a new generation's aggregate.
    mutating func abandonAfterServiceRestart() {
        tapID = .unknown
        aggregateDeviceID = .unknown
        deviceProcID = nil
        tapDescription = nil
        aggregateUID = nil
    }

    /// Whether these resources are currently active
    var isActive: Bool {
        tapID.isValid || aggregateDeviceID.isValid
    }

    /// Destroys all resources in the correct order to prevent leaks and crashes.
    /// Safe to call multiple times — invalid IDs are skipped.
    @discardableResult
    mutating func destroy() -> Bool {
        let job = cleanupJob(on: .global(qos: .userInitiated))
        // HAL IPC and retries run off MainActor. A timeout is NOT a successful join;
        // handoff callers must keep the old graph and decline the replacement.
        guard job.wait(timeout: .milliseconds(100)) else { return false }
        abandonAfterServiceRestart()
        pendingCleanup = nil
        return true
    }

    private mutating func cleanupJob(on queue: DispatchQueue) -> CleanupJob {
        if let pendingCleanup { return pendingCleanup }
        let job = CleanupJob(resources: self)
        pendingCleanup = job
        Self.pendingDestructionGroup.enter()
        job.start(on: queue)
        return job
    }

    /// One serial job owns the teardown phases. In particular, an unknown UID read
    /// cannot skip IOProc join and then destroy the aggregate on a later successful
    /// read. Pending IDs remain in the job until cleanup or a proven epoch change.
    /// Synchronous HAL calls (including join) are not cancellable; this preserves the
    /// existing handoff contract rather than falsely reporting a timed-out join done.
    private final class CleanupJob: @unchecked Sendable {
        private var tapID: AudioObjectID
        private var aggregateID: AudioObjectID
        private var procID: AudioDeviceIOProcID?
        private let generation: UInt64
        private let aggregateUID: String?
        private let tapUID: String?
        private let completionGroup = DispatchGroup()
        private let operations: CleanupOperations

        init(resources: TapResources) {
            tapID = resources.tapID
            aggregateID = resources.aggregateDeviceID
            procID = resources.deviceProcID
            generation = resources.serviceGeneration
            aggregateUID = resources.aggregateUID
            tapUID = resources.tapDescription?.uuid.uuidString
            operations = resources.cleanupOperations
            completionGroup.enter()
        }

        func wait(timeout: DispatchTimeInterval) -> Bool {
            completionGroup.wait(timeout: .now() + timeout) == .success
        }

        func notify(on queue: DispatchQueue, completion: @escaping @Sendable () -> Void) {
            completionGroup.notify(queue: queue, execute: completion)
        }

        func start(on queue: DispatchQueue) { queue.async { self.attempt(on: queue, number: 0) } }

        private func attempt(on queue: DispatchQueue, number: Int) {
            if step() {
                completionGroup.leave()
                TapResources.pendingDestructionGroup.leave()
                return
            }
            if number == 0 || number.isMultiple(of: 20) {
                logger.error("HAL teardown pending for aggregate \(self.aggregateID); retaining resources and refusing premature handoff")
            }
            // Retain the job rather than occupying a worker or losing the IDs. A later
            // epoch change ends stale cleanup without touching the new HAL namespace.
            queue.asyncAfter(deadline: .now() + min(0.05 * Double(number + 1), 5)) {
                self.attempt(on: queue, number: number + 1)
            }
        }

        private func step() -> Bool {
            guard generation == AudioServiceGeneration.current else { return true }
            if aggregateID.isValid {
                switch operations.identity(aggregateID, aggregateUID, generation, kAudioDevicePropertyDeviceUID) {
                case .unknown: return false
                case .gone:
                    // Never untrack a number now owned by another aggregate.
                    aggregateID = .unknown
                    procID = nil
                case .owned:
                    if let procID {
                        _ = operations.stop(aggregateID, procID)
                        // Stop may block across a restart. Revalidate before joining.
                        guard operations.identity(aggregateID, aggregateUID, generation,
                                                  kAudioDevicePropertyDeviceUID) == .owned else { return false }
                        guard operations.join(aggregateID, procID) == noErr else { return false }
                        self.procID = nil
                    }
                    guard operations.identity(aggregateID, aggregateUID, generation,
                                              kAudioDevicePropertyDeviceUID) == .owned else { return false }
                    guard operations.destroyAggregate(aggregateID) == noErr else { return false }
                    if generation == AudioServiceGeneration.current { CrashGuard.untrackDevice(aggregateID) }
                    aggregateID = .unknown
                }
            }
            guard generation == AudioServiceGeneration.current else { return true }
            if tapID.isValid {
                switch operations.identity(tapID, tapUID, generation, kAudioTapPropertyUID) {
                case .unknown: return false
                case .gone: tapID = .unknown
                case .owned:
                    guard operations.destroyTap(tapID) == noErr else { return false }
                    tapID = .unknown
                }
            }
            return true
        }
    }

    /// Destroys resources asynchronously on a background queue.
    /// Clears instance state immediately so new resources can be created without waiting.
    ///
    /// Use this when destruction might block (e.g., AudioDeviceDestroyIOProcID
    /// blocks until the current IO cycle completes).
    ///
    /// - Parameters:
    ///   - queue: Queue to perform destruction on (default: global utility)
    ///   - completion: Optional callback invoked after all resources are destroyed
    mutating func destroyAsync(on queue: DispatchQueue = .global(qos: .utility), completion: (@Sendable () -> Void)? = nil) {
        let job = cleanupJob(on: queue)
        abandonAfterServiceRestart()
        pendingCleanup = nil
        if let completion { job.notify(on: queue, completion: completion) }
    }

    /// Submits both resource teardowns synchronously, then completes only after both have
    /// finished. This is intentionally different from awaiting one `destroyAsync` before
    /// submitting the next: process-exit code drains `pendingDestructionGroup`, which must
    /// never observe a transient zero between a secondary and primary teardown belonging
    /// to the same controller invalidation.
    static func destroyPairAsync(
        _ first: inout TapResources,
        _ second: inout TapResources,
        on queue: DispatchQueue = .global(qos: .utility),
        completion: @escaping @Sendable () -> Void
    ) {
        let pairGroup = DispatchGroup()
        pairGroup.enter()
        first.destroyAsync(on: queue) {
            pairGroup.leave()
        }
        pairGroup.enter()
        second.destroyAsync(on: queue) {
            pairGroup.leave()
        }
        pairGroup.notify(queue: queue, execute: completion)
    }

    /// Blocks until every previously submitted asynchronous HAL teardown has completed.
    /// Call only after all main-actor producers have stopped scheduling new destruction.
    @discardableResult
    static func waitForPendingDestruction(timeout: DispatchTimeInterval = .seconds(2)) -> Bool {
        pendingDestructionGroup.wait(timeout: .now() + timeout) == .success
    }
}
