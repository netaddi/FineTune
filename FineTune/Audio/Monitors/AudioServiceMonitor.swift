import AudioToolbox
import os
import Synchronization

/// Control-plane epoch. Never read this lock from an audio callback.
nonisolated enum AudioServiceGeneration {
    private static let value = OSAllocatedUnfairLock(initialState: UInt64(0))
    static var current: UInt64 { value.withLock { $0 } }
    @discardableResult static func advance() -> UInt64 {
        value.withLock { $0 &+= 1; return $0 }
    }
}

/// Permanently retires a producer without calling into a dead HAL server. An entrant
/// registers before rechecking the gate; once closed, late callbacks cannot touch AUs.
nonisolated final class AudioCallbackLifetime: Sendable {
    private let retired = Atomic<Bool>(false)
    private let readers = Atomic<Int>(0)

    func enter() -> Bool {
        readers.wrappingAdd(1, ordering: .sequentiallyConsistent)
        if retired.load(ordering: .sequentiallyConsistent) {
            leave()
            return false
        }
        return true
    }
    func leave() { readers.wrappingSubtract(1, ordering: .sequentiallyConsistent) }
    func retire() { retired.store(true, ordering: .sequentiallyConsistent) }
    var isDrained: Bool { readers.load(ordering: .sequentiallyConsistent) == 0 }
}

nonisolated private final class AudioServiceListenerToken: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: UInt64(0))
    func set(_ token: UInt64) { value.withLock { $0 = token } }
    func claim(_ token: UInt64) -> UInt64? {
        value.withLock {
            guard $0 == token else { return nil }
            $0 = 0
            // Registration invalidation and epoch advance are one control-plane
            // transaction. This queue is NOT an audio callback thread.
            return AudioServiceGeneration.advance()
        }
    }
}

@MainActor
final class AudioServiceMonitor {
    var onRestart: (() -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?
    private var registration: UInt64 = 0
    private var wantsMonitoring = false
    private var retryTask: Task<Void, Never>?
    private var lastDeliveredEpoch: UInt64 = 0
    private nonisolated let callbackRegistration = AudioServiceListenerToken()
    private let queue = DispatchQueue(label: "FineTune.audio-service-restart")
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyServiceRestarted,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AudioServiceMonitor")

    func start() {
        wantsMonitoring = true
        registerIfNeeded()
    }

    private func registerIfNeeded() {
        guard wantsMonitoring else { return }
        guard listener == nil else { return }
        registration &+= 1
        let token = registration
        callbackRegistration.set(token)
        let callbackRegistration = callbackRegistration
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let epoch = callbackRegistration.claim(token) else { return }
            CrashGuard.forgetDevicesAfterServiceRestart()
            Task { @MainActor [weak self] in
                guard let self, self.wantsMonitoring, epoch > self.lastDeliveredEpoch else { return }
                self.lastDeliveredEpoch = epoch
                self.logger.error("Core Audio service restarted; retiring the previous capture generation")
                self.onRestart?()
                // Apple's restart contract also invalidates property listeners.
                self.stop()
                self.start()
            }
        }
        if AudioObjectAddPropertyListenerBlock(.system, &address, queue, block) == noErr {
            listener = block
        } else {
            logger.error("Could not register Core Audio restart listener")
            scheduleRegistrationRetry()
        }
    }

    private func scheduleRegistrationRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            // Keep a slow safety net after the initial fast retries. A failed listener
            // registration must not permanently disable recovery until app relaunch.
            for delay in [1, 2, 4, 8, 15] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, self.wantsMonitoring else { return }
                self.registerIfNeeded()
                if self.listener != nil { self.retryTask = nil; return }
            }
            guard let self, self.wantsMonitoring else { return }
            self.retryTask = nil
            self.scheduleRegistrationRetry()
        }
    }

    func stop() {
        wantsMonitoring = false
        retryTask?.cancel()
        retryTask = nil
        registration &+= 1
        callbackRegistration.set(registration)
        if let listener {
            AudioObjectRemovePropertyListenerBlock(.system, &address, queue, listener)
        }
        listener = nil
    }
}
