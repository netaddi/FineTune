/// Abstraction over process tap controllers for testability.
///
/// **Threading:** The protocol surface is `@MainActor` — AudioEngine and tests
/// interact with controllers from main. The concrete class straddles main and the
/// CoreAudio HAL I/O thread, but the audio callback never goes through this
/// protocol; it reads `nonisolated(unsafe)` atomic fields directly on the concrete
/// type via a `void *` userdata pointer.
struct DeviceAUEffectTransition: Sendable {
    let entries: [AUEffectChainEntry]
    let isBypassed: Bool
}

@MainActor
protocol ProcessTapControlling: AnyObject, Sendable {
    var app: AudioApp { get }
    /// macOS 26 taps can retain bundle identities while the process is absent and attach
    /// to the replacement process before its first output buffer.
    var restoresProcessByBundleID: Bool { get }
    /// Immutable bundle set installed in the Core Audio tap description. Metadata learned
    /// after activation must be compared against this set before reusing a standby graph.
    var configuredRestorationBundleIDs: Set<String> { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var currentDeviceVolume: Float { get set }
    var isDeviceMuted: Bool { get set }
    var audioLevel: Float { get }
    var currentDeviceUID: String? { get }
    var currentDeviceUIDs: [String] { get }

    func activate(initial: TapInitialState) throws
    func rebind(to app: AudioApp)
    func invalidate()
    /// Blocking teardown used only when another producer will immediately inherit the
    /// same persistent stateful AU instances.
    @discardableResult func invalidateForHandoff() -> Bool
    func invalidateAsync() async
    /// Close the local callback gate and forget server-owned objects after a HAL reset.
    /// Does not join a possibly blocked HAL call on MainActor or destroy stale IDs.
    func retireAfterServiceRestart()
    var serviceRestartCallbacksDrained: Bool { get }
    /// Read-only identity check on the control plane, independent of audio activity.
    var hasValidAudioResources: Bool { get }
    var isAudioResourceTransitionInProgress: Bool { get }
    func updateEQSettings(_ settings: EQSettings)
    func updateAutoEQProfile(_ profile: AutoEQProfile?)
    func setAutoEQPreampEnabled(_ enabled: Bool)
    func updateLoudnessCompensation(volume: Float, enabled: Bool)
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings)
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool, deviceAUTransition: DeviceAUEffectTransition?) async throws
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool, deviceAUTransition: DeviceAUEffectTransition?) async throws
    func hasRecentAudioCallback(within seconds: Double) -> Bool
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool

    var tapSourceDeviceUID: String? { get }
    func refreshTapSource(_ preferredDeviceUID: String?, deviceAUTransition: DeviceAUEffectTransition?) async throws
    func recreateForOutputRateChange(deviceAUTransition: DeviceAUEffectTransition?) async throws

    // AU effect chains
    func updateAUEffectChain(_ entries: [AUEffectChainEntry])
    func attachPersistentAUEffectChain(_ chain: AUEffectChain?, entries: [AUEffectChainEntry])
    func getAUEffectChainEntries() -> [AUEffectChainEntry]
    func setAUChainBypassed(_ bypassed: Bool)
    var isAUChainBypassed: Bool { get }
    func updateDeviceAUEffectChain(_ entries: [AUEffectChainEntry])
    func getDeviceAUEffectChainEntries() -> [AUEffectChainEntry]
    func setDeviceAUChainBypassed(_ bypassed: Bool)
    var isDeviceAUChainBypassed: Bool { get }
}

extension ProcessTapControlling {
    func retireAfterServiceRestart() { invalidate() }
    var serviceRestartCallbacksDrained: Bool { true }
    var hasValidAudioResources: Bool { true }
    var isAudioResourceTransitionInProgress: Bool { false }
    var restoresProcessByBundleID: Bool { false }
    var configuredRestorationBundleIDs: Set<String> { [] }

    func rebind(to app: AudioApp) {}

    /// Convenience activation with default state. Production callers must pass an
    /// `initial:` populated from persisted settings — defaults leave the first audio
    /// callbacks running with no EQ/AutoEQ/Loudness and unity volume ramp.
    func activate() throws {
        try activate(initial: TapInitialState())
    }

    /// Convenience: defaults sourceDeviceDead to false.
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?) async throws {
        try await switchDevice(
            to: newDeviceUID,
            preferredTapSourceDeviceUID: preferredTapSourceDeviceUID,
            sourceDeviceDead: false,
            deviceAUTransition: nil
        )
    }

    /// Convenience: defaults sourceDeviceDead to false.
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?) async throws {
        try await updateDevices(
            to: newDeviceUIDs,
            preferredTapSourceDeviceUID: preferredTapSourceDeviceUID,
            sourceDeviceDead: false,
            deviceAUTransition: nil
        )
    }

    func invalidateAsync() async {
        invalidate()
    }

    @discardableResult func invalidateForHandoff() -> Bool {
        invalidate()
        return true
    }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        try await refreshTapSource(preferredDeviceUID, deviceAUTransition: nil)
    }

    func refreshTapSource(_ preferredDeviceUID: String?, deviceAUTransition: DeviceAUEffectTransition?) async throws {
        // Default no-op for mocks that don't override
    }

    func recreateForOutputRateChange() async throws {
        try await recreateForOutputRateChange(deviceAUTransition: nil)
    }

    func recreateForOutputRateChange(deviceAUTransition: DeviceAUEffectTransition?) async throws {
        // Default no-op for mocks that don't override
    }

    func updateAUEffectChain(_ entries: [AUEffectChainEntry]) {}
    func attachPersistentAUEffectChain(_ chain: AUEffectChain?, entries: [AUEffectChainEntry]) {}
    func getAUEffectChainEntries() -> [AUEffectChainEntry] { [] }
    func setAUChainBypassed(_ bypassed: Bool) {}
    var isAUChainBypassed: Bool { false }
    func updateDeviceAUEffectChain(_ entries: [AUEffectChainEntry]) {}
    func getDeviceAUEffectChainEntries() -> [AUEffectChainEntry] { [] }
    func setDeviceAUChainBypassed(_ bypassed: Bool) {}
    var isDeviceAUChainBypassed: Bool { false }
}
