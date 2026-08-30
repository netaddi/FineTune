// FineTune/Audio/Engine/AudioEngine.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

@Observable
@MainActor
final class AudioEngine {
    let processMonitor: any AudioProcessMonitoring
    let deviceMonitor: any AudioDeviceProviding
    let bluetoothDeviceMonitor: BluetoothDeviceMonitor
    let deviceVolumeMonitor: any DeviceVolumeProviding
    let volumeState: VolumeState
    let settingsManager: SettingsManager
    let autoEQProfileManager: AutoEQProfileManager
    let permission: AudioRecordingPermission
    let appListCoordinator: AppListCoordinator

    #if !APP_STORE
    let ddcController: DDCController
    #endif

    private var taps: [pid_t: any ProcessTapControlling] = [:]

    // MARK: - Observable AU State (authoritative for SwiftUI)
    //
    // AudioEngine owns AU chain state for the UI. SettingsManager persists to disk.
    // Mutations update both: this dict (observation) + settings (persistence) + tap (RT).

    /// Per-app AU state. Keyed by persistence identifier.
    private(set) var appAU: [String: AUChainState] = [:]
    /// Per-device AU state. Keyed by device UID.
    private(set) var deviceAU: [String: AUChainState] = [:]
    /// Favorited AU plugin IDs.
    private(set) var favoriteAUPluginIDs: Set<String> = []
    /// Plugin IDs that were active during a crash.
    private(set) var auCrashHistory: Set<String> = []
    /// Long-lived logical channels keyed by bundle/name persistence identifier. These own
    /// per-app Audio Unit instances independently from temporary PID-based process taps.
    private var persistentAppStrips: [String: PersistentMixerStrip] = [:]

    /// Factory for creating tap controllers. Overridable for testing.
    private let tapFactory: @MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling

    /// Closure to check if a device is alive. Overridable for testing.
    private let isAliveCheck: (AudioDeviceID) -> Bool

    /// One-shot HAL listeners for devices that were present but not alive during priority resolution.
    /// Keyed by AudioDeviceID. Each entry holds the device UID, listener block, and a timeout task.
    private var aliveWatchers: [AudioDeviceID: (uid: String, block: AudioObjectPropertyListenerBlock, timeout: Task<Void, Never>)] = [:]

    /// Number of pending alive watchers (exposed for testing).
    var pendingAliveWatcherCount: Int { aliveWatchers.count }

    private var appliedPIDs: Set<pid_t> = []
    private var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    private var followsDefault: Set<pid_t> = []  // Apps that follow system default
    /// The last output default confirmed by FineTune (user change or programmatic switch).
    /// Used to restore after macOS auto-switches to a lower-priority device.
    private var lastConfirmedDefaultUID: String?
    /// Timestamp of the last auto-switch override. Used to distinguish rapid BT auto-switches
    /// (< 1s apart) from deliberate user changes (> 1s after last override).
    private var lastAutoSwitchOverrideTime: Date?
    private var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    private var staleCleanupTask: Task<Void, Never>?  // Debounced cleanup scheduling
    private var healthMonitorTask: Task<Void, Never>?  // Periodic tap health monitor
    private var tapRecoveryCooldownUntil: [pid_t: Date] = [:]  // Prevents tap recreation thrashing
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioEngine")

    // MARK: - Priority State Machine

    /// Tracks whether we're waiting for macOS to potentially auto-switch after a device connect.
    private enum PriorityState {
        case stable
        case pendingAutoSwitch(connectedDeviceUID: String, timeoutTask: Task<Void, Never>)
    }

    private var outputPriorityState: PriorityState = .stable
    private var inputPriorityState: PriorityState = .stable

    /// Grace period for auto-switch detection (wired devices)
    private let autoSwitchGracePeriod: TimeInterval = 2.0

    /// Extended grace period for Bluetooth devices (firmware handshake takes longer)
    private let btAutoSwitchGracePeriod: TimeInterval = 5.0

    // MARK: - Echo Suppression

    private let outputEchoTracker = EchoTracker(label: "Output")
    private let inputEchoTracker = EchoTracker(label: "Input")

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
        deviceVolumeMonitor.outputVolumeBackend(for: deviceID)
    }

    var inputDevices: [AudioDevice] {
        deviceMonitor.inputDevices
    }

    /// Output devices sorted by user-defined priority order.
    /// Devices in the priority list appear in that order; new/unknown devices are appended alphabetically.
    var prioritySortedOutputDevices: [AudioDevice] {
        let devices = outputDevices
        let priorityOrder = settingsManager.devicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        // Collect devices in priority order (skip stale UIDs)
        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        // Append new devices alphabetically
        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    /// Input devices sorted by user-defined priority order.
    var prioritySortedInputDevices: [AudioDevice] {
        let devices = inputDevices
        let priorityOrder = settingsManager.inputDevicePriorityOrder
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })

        var sorted: [AudioDevice] = []
        var seen = Set<String>()
        for uid in priorityOrder {
            if let device = devicesByUID[uid] {
                sorted.append(device)
                seen.insert(uid)
            }
        }

        let remaining = devices
            .filter { !seen.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sorted.append(contentsOf: remaining)

        return sorted
    }

    /// Registers any output devices not yet in the priority list.
    /// Call this when devices change (not from computed properties).
    func registerNewDevicesInPriority() {
        for device in outputDevices {
            settingsManager.ensureDeviceInPriority(device.uid)
        }
        for device in inputDevices {
            settingsManager.ensureInputDeviceInPriority(device.uid)
        }
    }

    /// Returns the highest-priority device that is both connected and alive.
    /// `isDeviceAlive()` is checked internally — callers never need to check separately.
    static func resolveHighestPriority(
        priorityOrder: [String],
        connectedDevices: [AudioDevice],
        excluding: String? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil
    ) -> AudioDevice? {
        let aliveCheck = isAlive ?? { $0.isDeviceAlive() }
        let connected = Dictionary(
            connectedDevices.map { ($0.uid, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for uid in priorityOrder {
            guard uid != excluding,
                  let device = connected[uid],
                  aliveCheck(device.id) else { continue }
            return device
        }
        // Fallback: any alive connected device not excluded
        return connectedDevices.first {
            $0.uid != excluding && aliveCheck($0.id)
        }
    }


    init(
        permission: AudioRecordingPermission,
        settingsManager: SettingsManager,
        autoEQProfileManager: AutoEQProfileManager,
        deviceProvider: (any AudioDeviceProviding)? = nil,
        processMonitor: (any AudioProcessMonitoring)? = nil,
        deviceVolumeMonitor: (any DeviceVolumeProviding)? = nil,
        tapFactory: (@MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling)? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil,
        startMonitorsAutomatically: Bool = true
    ) {
        self.permission = permission
        let manager = settingsManager
        self.settingsManager = manager
        self.appListCoordinator = AppListCoordinator(settingsManager: manager)
        self.autoEQProfileManager = autoEQProfileManager
        self.volumeState = VolumeState(settingsManager: manager)
        self.isAliveCheck = isAlive ?? { $0.isDeviceAlive() }

        // If a custom deviceProvider is given, use it directly.
        // Otherwise create a real AudioDeviceMonitor (needed by DeviceVolumeMonitor and default tap factory).
        let realDeviceMonitor: AudioDeviceMonitor?
        if let provider = deviceProvider {
            realDeviceMonitor = provider as? AudioDeviceMonitor
            self.deviceMonitor = provider
        } else {
            let monitor = AudioDeviceMonitor()
            realDeviceMonitor = monitor
            self.deviceMonitor = monitor
        }
        self.processMonitor = processMonitor ?? AudioProcessMonitor()
        self.bluetoothDeviceMonitor = BluetoothDeviceMonitor()

        #if !APP_STORE
        let ddc = DDCController(settingsManager: manager)
        self.ddcController = ddc
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager, ddcController: ddc)
        }
        #else
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager)
        }
        #endif

        // Tap factory: use provided factory or default to ProcessTapController
        if let factory = tapFactory {
            self.tapFactory = factory
        } else {
            self.tapFactory = { app, deviceUIDs, preferredSource in
                if deviceUIDs.count == 1 {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUID: deviceUIDs[0],
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                } else {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUIDs: deviceUIDs,
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                }
            }
        }

        outputEchoTracker.onTimeout = { [weak self] _ in
            self?.restoreConfirmedDefault()
        }
        inputEchoTracker.onTimeout = { [weak self] _ in
            guard let self, self.settingsManager.appSettings.lockInputDevice else { return }
            self.restoreLockedInputDevice()
        }

        // Wire callbacks — needed for both test and production mode
        wireCallbacks()

        if startMonitorsAutomatically {
            Task { @MainActor in
                if self.permission.status == .authorized {
                    self.processMonitor.start()
                }
                self.deviceMonitor.start()
                self.bluetoothDeviceMonitor.start()

                #if !APP_STORE
                ddc.onProbeCompleted = { [weak self] in
                    self?.deviceVolumeMonitor.refreshAfterDDCProbe()
                    self?.refreshAllTapOutputStates()
                }
                ddc.start()
                #endif

                // Start device volume monitor AFTER deviceMonitor.start() populates devices
                self.deviceVolumeMonitor.start()

                self.applyPersistedSettings()
                self.registerNewDevicesInPriority()
                // Seed the confirmed default from whatever macOS has at startup
                self.lastConfirmedDefaultUID = self.deviceVolumeMonitor.defaultDeviceUID
                if manager.appSettings.lockInputDevice {
                    self.restoreLockedInputDevice()
                }
            }
        }

        // Start process monitor when permission is granted
        if startMonitorsAutomatically && permission.status != .authorized {
            observePermissionGranted()
        }
    }

    private func observePermissionGranted() {
        withObservationTracking {
            _ = self.permission.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.permission.status == .authorized {
                    self.processMonitor.start()
                    self.applyPersistedSettings()
                    self.startHealthMonitor()
                    self.logger.info("Audio capture authorized — process monitor started")
                } else {
                    self.observePermissionGranted()
                }
            }
        }
    }

    /// Wire all event callbacks from monitors to AudioEngine handlers.
    private func wireCallbacks() {
        // Sync device volume changes to taps for VU meter accuracy
        deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            let loudnessEnabled = self.settingsManager.appSettings.loudnessCompensationEnabled
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.currentDeviceVolume = newVolume
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                    tap.updateLoudnessCompensation(
                        volume: self.effectiveLoudnessVolume(for: tap),
                        enabled: loudnessEnabled
                    )
                }
            }
        }

        deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, isMuted in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.isDeviceMuted = isMuted
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                }
            }
        }

        processMonitor.onAppsChanged = { [weak self] apps in
            self?.applyPersistedSettings()
            self?.scheduleStaleCleanup()
        }

        // Priority order closures — only for concrete AudioDeviceMonitor
        if let realMonitor = deviceMonitor as? AudioDeviceMonitor {
            realMonitor.outputPriorityOrder = { [weak self] in
                self?.settingsManager.devicePriorityOrder ?? []
            }
            realMonitor.inputPriorityOrder = { [weak self] in
                self?.settingsManager.inputDevicePriorityOrder ?? []
            }
            realMonitor.onBTDeviceSampleRateChanged = { [weak self] uid, newRate in
                Task { @MainActor [weak self] in
                    await self?.handleBTDeviceSampleRateChanged(uid: uid, newRate: newRate)
                }
            }
        }

        deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.refresh()
        }

        deviceMonitor.onDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceConnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.notifyDeviceAppearedInCoreAudio()
        }

        deviceMonitor.onInputDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device disconnected: \(deviceName) (\(deviceUID))")
            self?.handleInputDeviceDisconnected(deviceUID)
        }

        deviceMonitor.onInputDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device connected: \(deviceName) (\(deviceUID))")
            self?.settingsManager.ensureInputDeviceInPriority(deviceUID)
            self?.handleInputDeviceConnected(deviceUID, name: deviceName)
        }

        deviceVolumeMonitor.onDefaultDeviceChanged = { [weak self] newDefaultUID in
            self?.handleDefaultDeviceChanged(newDefaultUID)
        }

        deviceVolumeMonitor.onDefaultInputDeviceChanged = { [weak self] newDefaultInputUID in
            Task { @MainActor [weak self] in
                self?.handleDefaultInputDeviceChanged(newDefaultInputUID)
            }
        }
    }

    var apps: [AudioApp] {
        processMonitor.activeApps
    }

    // MARK: - Displayable Apps (Active + Pinned Inactive)

    /// Combined list of active apps and pinned inactive apps for UI display.
    /// Pinned apps appear first in deterministic mixer-slot order, then unpinned active apps.
    var displayableApps: [DisplayableApp] {
        let activeApps = apps
            .filter { !appListCoordinator.isIgnored(identifier: $0.persistenceIdentifier) }
        let activeIdentifiers = Set(activeApps.map { $0.persistenceIdentifier })

        // Get pinned apps that are not currently active
        let pinnedInactiveInfos = appListCoordinator.pinnedAppInfo()
            .filter { !activeIdentifiers.contains($0.persistenceIdentifier) }

        let activeByIdentifier = Dictionary(
            activeApps.map { ($0.persistenceIdentifier, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let pinned = appListCoordinator.pinnedAppInfo().compactMap { info -> DisplayableApp? in
            if let active = activeByIdentifier[info.persistenceIdentifier] {
                return .active(active)
            }
            return pinnedInactiveInfos.contains(where: {
                $0.persistenceIdentifier == info.persistenceIdentifier
            }) ? .pinnedInactive(info) : nil
        }

        // Unpinned active apps (sorted alphabetically)
        let unpinnedActive = activeApps
            .filter { !appListCoordinator.isPinned(identifier: $0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        return pinned + unpinnedActive
    }

    // MARK: - Pinning

    /// Pin an active app so it remains visible when inactive.
    func pinApp(_ app: AudioApp) {
        appListCoordinator.pinApp(app)
        preparePersistentMixerStrip(
            identifier: app.persistenceIdentifier,
            displayName: app.name
        )
    }

    /// Unpin an app by its persistence identifier.
    func unpinApp(_ identifier: String) {
        appListCoordinator.unpinApp(identifier)
        refreshPersistentMixerStripSlots()
    }

    /// Check if an app is pinned.
    func isPinned(_ app: AudioApp) -> Bool {
        appListCoordinator.isPinned(app)
    }

    /// Check if an identifier is pinned (for inactive apps).
    func isPinned(identifier: String) -> Bool {
        appListCoordinator.isPinned(identifier: identifier)
    }

    func mixerStripSlot(for identifier: String) -> Int? {
        settingsManager.getMixerStripSlot(for: identifier)
    }

    var mixerStripSlotCount: Int {
        settingsManager.mixerStripSlots.count
    }

    /// Updates the desired deterministic startup order. Existing instances deliberately
    /// remain alive; the new Console track creation order takes effect on next launch.
    func setMixerStripSlot(_ slot: Int, for identifier: String) {
        settingsManager.setMixerStripSlot(slot, for: identifier)
        refreshPersistentMixerStripSlots()
    }

    private func refreshPersistentMixerStripSlots() {
        for (identifier, strip) in persistentAppStrips {
            strip.updateMetadata(
                displayName: strip.displayName,
                slot: settingsManager.getMixerStripSlot(for: identifier)
            )
        }
    }

    // MARK: - Ignored Apps

    /// Hide an active app so FineTune ignores it entirely. Persists the ignore,
    /// then tears down the live tap so audio returns to natural volume.
    func ignoreApp(_ app: AudioApp) {
        ignoreApp(
            identifier: app.persistenceIdentifier,
            displayName: app.name,
            bundleID: app.bundleID
        )
    }

    /// Identifier-based path shared by active and pinned-inactive rows. Every PID that
    /// belongs to the logical app is retired before the persistent Console strip is released.
    func ignoreApp(identifier: String, displayName: String, bundleID: String?) {
        for entry in getAUEffectChain(forIdentifier: identifier) {
            AUPluginWindowManager.shared.closeWindow(for: entry.id)
        }
        settingsManager.ignoreApp(
            identifier,
            info: IgnoredAppInfo(
                persistenceIdentifier: identifier,
                displayName: displayName,
                bundleID: bundleID
            )
        )
        volumeState.removeStates(for: identifier)

        let matchingPIDs = taps.compactMap { pid, tap in
            tap.app.persistenceIdentifier == identifier ? pid : nil
        }
        for pid in matchingPIDs {
            pendingCleanup.removeValue(forKey: pid)?.cancel()
            taps.removeValue(forKey: pid)?.invalidate()
            appDeviceRouting.removeValue(forKey: pid)
            followsDefault.remove(pid)
            appliedPIDs.remove(pid)
        }
        persistentAppStrips.removeValue(forKey: identifier)
        appAU.removeValue(forKey: identifier)
        refreshPersistentMixerStripSlots()
    }

    /// Unhide an app by its persistence identifier.
    /// Immediately creates a tap if the app is currently running.
    func unignoreApp(_ identifier: String) {
        appListCoordinator.clearIgnore(identifier)
        applyPersistedSettings()
    }

    /// Check if an identifier is hidden.
    func isIgnored(identifier: String) -> Bool {
        appListCoordinator.isIgnored(identifier: identifier)
    }

    // MARK: - Inactive App Settings (by persistence identifier)

    func getVolumeForInactive(identifier: String) -> Float {
        appListCoordinator.getVolumeForInactive(identifier: identifier)
    }

    func setVolumeForInactive(identifier: String, to volume: Float) {
        appListCoordinator.setVolumeForInactive(identifier: identifier, to: volume)
    }

    func getBoostForInactive(identifier: String) -> BoostLevel {
        appListCoordinator.getBoostForInactive(identifier: identifier)
    }

    func setBoostForInactive(identifier: String, to boost: BoostLevel) {
        appListCoordinator.setBoostForInactive(identifier: identifier, to: boost)
    }

    func getMuteForInactive(identifier: String) -> Bool {
        appListCoordinator.getMuteForInactive(identifier: identifier)
    }

    func setMuteForInactive(identifier: String, to muted: Bool) {
        appListCoordinator.setMuteForInactive(identifier: identifier, to: muted)
    }

    func getEQSettingsForInactive(identifier: String) -> EQSettings {
        appListCoordinator.getEQSettingsForInactive(identifier: identifier)
    }

    func setEQSettingsForInactive(_ settings: EQSettings, identifier: String) {
        appListCoordinator.setEQSettingsForInactive(settings, identifier: identifier)
    }

    func getDeviceRoutingForInactive(identifier: String) -> String? {
        appListCoordinator.getDeviceRoutingForInactive(identifier: identifier)
    }

    /// The device that a pinned inactive app will use as its aggregate clock on its
    /// next multi-output activation. Its old single-route preference is intentionally
    /// ignored in multi mode so the inactive UI previews the same priority plan that
    /// `applyPersistedSettings()` will commit.
    func getPrimaryDeviceUIDForInactive(identifier: String) -> String? {
        guard getDeviceSelectionModeForInactive(identifier: identifier) == .multi else {
            return getDeviceRoutingForInactive(identifier: identifier)
        }
        let availableSelections = getSelectedDeviceUIDsForInactive(identifier: identifier)
            .filter { deviceMonitor.device(for: $0) != nil }
        return orderedSelectedDeviceUIDs(Set(availableSelections)).first
    }

    func setDeviceRoutingForInactive(identifier: String, deviceUID: String?) {
        appListCoordinator.setDeviceRoutingForInactive(identifier: identifier, deviceUID: deviceUID)
    }

    func isFollowingDefaultForInactive(identifier: String) -> Bool {
        appListCoordinator.isFollowingDefaultForInactive(identifier: identifier)
    }

    func getDeviceSelectionModeForInactive(identifier: String) -> DeviceSelectionMode {
        appListCoordinator.getDeviceSelectionModeForInactive(identifier: identifier)
    }

    func setDeviceSelectionModeForInactive(identifier: String, to mode: DeviceSelectionMode) {
        appListCoordinator.setDeviceSelectionModeForInactive(identifier: identifier, to: mode)
    }

    func getSelectedDeviceUIDsForInactive(identifier: String) -> Set<String> {
        appListCoordinator.getSelectedDeviceUIDsForInactive(identifier: identifier)
    }

    func setSelectedDeviceUIDsForInactive(identifier: String, to uids: Set<String>) {
        appListCoordinator.setSelectedDeviceUIDsForInactive(identifier: identifier, to: uids)
    }

    /// Audio levels for all active apps (for VU meter visualization)
    /// Returns a dictionary mapping PID to peak audio level (0-1)
    var audioLevels: [pid_t: Float] {
        var levels: [pid_t: Float] = [:]
        for (pid, tap) in taps {
            levels[pid] = tap.audioLevel
        }
        return levels
    }

    /// Get audio level for a specific app
    func getAudioLevel(for app: AudioApp) -> Float {
        taps[app.id]?.audioLevel ?? 0.0
    }

    func start() {
        // Monitors have internal guards against double-starting
        if permission.status == .authorized {
            processMonitor.start()
        }
        deviceMonitor.start()
        applyPersistedSettings()
        if permission.status == .authorized {
            startHealthMonitor()
        }

        // Restore locked input device if feature is enabled
        if settingsManager.appSettings.lockInputDevice {
            restoreLockedInputDevice()
        }

        logger.info("AudioEngine started")
    }

    func stop() {
        stopHealthMonitor()
        processMonitor.stop()
        deviceMonitor.stop()
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        logger.info("AudioEngine stopped")
    }

    /// Explicit shutdown for app termination. Ensures all listeners are cleaned up.
    /// Call from applicationWillTerminate or equivalent lifecycle hook.
    /// Note: For menu bar apps, process exit cleans up resources anyway, so this is optional.
    func shutdown() {
        stop()
        deviceVolumeMonitor.stop()
        logger.info("AudioEngine shutdown complete")
    }

    /// Synchronously releases HAL resources immediately before the process exits, while
    /// deliberately retaining the controller/AU object graph. Third-party Audio Units may
    /// have unsafe C++ finalizers at normal `exit(3)` time; `FineTuneApp` flushes settings,
    /// calls this method, and then uses `_exit(2)` so those foreign finalizers never run.
    /// Keeping the taps alive until `_exit` also keeps every AU render refcon and scratch
    /// buffer valid after the IOProcs have been joined.
    func prepareForProcessExit() {
        stopHealthMonitor()
        processMonitor.stop()
        deviceMonitor.stop()
        for tap in taps.values {
            tap.invalidateForHandoff()
        }
        // `invalidate()` intentionally moves slow HAL destruction off the main actor.
        // Controllers already removed for ignored/stale apps are no longer in `taps`, so
        // drain their tracked work before `_exit` can terminate those queue blocks.
        TapResources.waitForPendingDestruction()
        deviceVolumeMonitor.stop()
        #if !APP_STORE
        ddcController.stop()
        #endif
        logger.info("AudioEngine prepared for process exit")
    }

    // MARK: - Settings Reset

    /// Resets all persisted settings and synchronizes in-memory engine state.
    /// Active taps are kept alive but reverted to defaults (unity volume, unmuted, disabled flat EQ).
    func handleSettingsReset() {
        // Close plugin views while their hosts are still valid. Window close callbacks save
        // live state first; resetAllSettings below then deliberately clears that state.
        AUPluginWindowManager.shared.closeAllWindows()

        // 1. Clear persisted state
        settingsManager.resetAllSettings()

        // 2. Clear in-memory routing and tracking state
        appliedPIDs.removeAll()
        appDeviceRouting.removeAll()
        followsDefault.removeAll()

        // 3. Clear cached per-app audio state
        volumeState.resetAll()

        // 4. Refresh output state caches so software-backed devices reset to defaults.
        deviceVolumeMonitor.refreshOutputDeviceStates()

        // 5. Push defaults to all active taps
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
            tap.updateEQSettings(.disabledFlat)
            tap.updateAutoEQProfile(nil)
            tap.attachPersistentAUEffectChain(nil, entries: [])
            tap.updateDeviceAUEffectChain([])
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: false)
        }

        // 5b. Clear observable AU state
        appAU.removeAll()
        persistentAppStrips.removeAll()
        deviceAU.removeAll()
        favoriteAUPluginIDs.removeAll()
        auCrashHistory.removeAll()

        // 6. Re-apply from clean settings (re-establishes routing to system default)
        applyPersistedSettings()

        logger.info("Settings reset: engine state synchronized")
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        volumeState.setVolume(for: app.id, to: volume, identifier: app.persistenceIdentifier)
        if let deviceUID = appDeviceRouting[app.id] {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
            if settingsManager.appSettings.loudnessCompensationEnabled {
                tap.updateLoudnessCompensation(
                    volume: effectiveLoudnessVolume(for: tap),
                    enabled: true
                )
            }
        }
    }

    func getVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    // MARK: - Boost

    func setBoost(for app: AudioApp, to boost: BoostLevel) {
        volumeState.setBoost(for: app.id, to: boost, identifier: app.persistenceIdentifier)
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }

    func getBoost(for app: AudioApp) -> BoostLevel {
        volumeState.getBoost(for: app.id)
    }

    /// Effective gain for ProcessTapController: app volume × boost, plus optional
    /// single-device software output gain for software-backed devices.
    /// Single-device-routed apps on `.software`-backed devices always receive the
    /// device's software gain; multi-destination routing keeps `appGain` alone
    /// because per-device software gain has no unambiguous meaning across fan-out.
    private func effectiveVolume(for pid: pid_t, deviceUIDs: [String]? = nil) -> Float {
        let appGain = volumeState.getVolume(for: pid) * volumeState.getBoost(for: pid).rawValue

        guard let resolvedUIDs = deviceUIDs, resolvedUIDs.count == 1,
              let primaryUID = resolvedUIDs.first,
              let device = deviceMonitor.device(for: primaryUID),
              outputVolumeBackend(for: device.id) == .software else {
            return appGain
        }

        return appGain * deviceVolumeMonitor.outputProcessingGain(for: device.id)
    }

    /// Estimated listening level for loudness compensation: device volume × per-app slider.
    /// Does not include boost (intentional amplification beyond reference).
    /// The compensator's phon estimation clamps to [0,1] so values > 1 are treated as reference.
    private func effectiveLoudnessVolume(for tap: any ProcessTapControlling) -> Float {
        tap.currentDeviceVolume * volumeState.getVolume(for: tap.app.id)
    }

    private func applyTapOutputState(to tap: any ProcessTapControlling, for pid: pid_t, deviceUIDs: [String]? = nil) {
        let resolvedUIDs = deviceUIDs ?? tap.currentDeviceUIDs
        tap.volume = effectiveVolume(for: pid, deviceUIDs: resolvedUIDs)
        tap.isMuted = volumeState.getMute(for: pid)

        if let primaryUID = resolvedUIDs.first,
           let device = deviceMonitor.device(for: primaryUID) {
            tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
        } else {
            tap.currentDeviceVolume = 1.0
            tap.isDeviceMuted = false
        }
    }

    private func refreshAllTapOutputStates() {
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }

    func toggleMute(for app: AudioApp) {
        let current = volumeState.getMute(for: app.id)
        setMute(for: app, to: !current)
    }

    func currentVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    func isMuted(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    func isAudibleNow(bundleID: String) -> Bool {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            return false
        }
        return app.processObjectIDs.contains { $0.readProcessIsRunning() }
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        volumeState.setMute(for: app.id, to: muted, identifier: app.persistenceIdentifier)
        taps[app.id]?.isMuted = muted
    }

    func getMute(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    /// Update EQ settings for an app
    func setEQSettings(_ settings: EQSettings, for app: AudioApp) {
        guard let tap = taps[app.id] else { return }
        tap.updateEQSettings(settings)
        settingsManager.setEQSettings(settings, for: app.persistenceIdentifier)
    }

    /// Get EQ settings for an app
    func getEQSettings(for app: AudioApp) -> EQSettings {
        return settingsManager.getEQSettings(for: app.persistenceIdentifier)
    }

    // MARK: - AU Plugin Favorites & Crash History

    func toggleAUPluginFavorite(_ pluginID: String) {
        if favoriteAUPluginIDs.contains(pluginID) {
            favoriteAUPluginIDs.remove(pluginID)
        } else {
            favoriteAUPluginIDs.insert(pluginID)
        }
        settingsManager.toggleAUPluginFavorite(pluginID)
    }

    func loadAUMetadataFromSettings() {
        favoriteAUPluginIDs = settingsManager.favoriteAUPlugins
        auCrashHistory = settingsManager.auPluginCrashHistory
        preparePersistentMixerStrips()
    }

    private func preferredPersistentAUSampleRate() -> Double {
        // This runs during FineTuneApp.init, before the asynchronous device monitors have
        // populated their caches. Query HAL directly so a 44.1 kHz system does not require
        // an immediate uninitialize/reinitialize cycle after Console 1 is created.
        if let defaultDeviceID = try? AudioDeviceID.readDefaultOutputDevice(),
           defaultDeviceID.isValid,
           let sampleRate = try? defaultDeviceID.readNominalSampleRate(),
           sampleRate.isFinite, sampleRate > 0 {
            return sampleRate
        }
        return 48_000
    }

    /// Instantiates pinned chains in slot order before any process tap is needed. Console 1
    /// allocates the lowest available track to non-integrated hosts, so deterministic startup
    /// creation plus persistent ownership gives each pinned app a stable track identity.
    private func preparePersistentMixerStrips() {
        for info in settingsManager.getPinnedAppInfo() {
            preparePersistentMixerStrip(
                identifier: info.persistenceIdentifier,
                displayName: info.displayName
            )
        }
    }

    @discardableResult
    private func preparePersistentMixerStrip(
        identifier: String,
        displayName: String
    ) -> PersistentMixerStrip? {
        let entries = settingsManager.getAUEffectChain(for: identifier)
        guard !entries.isEmpty else { return nil }

        let slot = settingsManager.getMixerStripSlot(for: identifier)
        let bypassed = settingsManager.getAppAUBypassed(for: identifier)
        if let existing = persistentAppStrips[identifier] {
            existing.updateMetadata(displayName: displayName, slot: slot)
            existing.setBypassed(bypassed)
            return existing
        }

        let strip = PersistentMixerStrip(
            persistenceIdentifier: identifier,
            displayName: displayName,
            slot: slot,
            entries: entries,
            sampleRate: preferredPersistentAUSampleRate(),
            isBypassed: bypassed
        )
        persistentAppStrips[identifier] = strip
        if strip.entries != entries {
            settingsManager.setAUEffectChain(strip.entries, for: identifier)
        }
        appAU[identifier] = AUChainState(
            entries: strip.entries,
            isBypassed: bypassed,
            failedEntryIDs: strip.failedEntryIDs
        )
        return strip
    }

    private func attachPersistentMixerStrip(
        to tap: any ProcessTapControlling,
        for app: AudioApp
    ) {
        let strip = persistentAppStrips[app.persistenceIdentifier]
            ?? preparePersistentMixerStrip(
                identifier: app.persistenceIdentifier,
                displayName: app.name
            )
        tap.attachPersistentAUEffectChain(strip?.chain, entries: strip?.entries ?? [])
        if strip?.isBypassed == true {
            tap.setAUChainBypassed(true)
        }
    }

    private func loadPersistedAUBypassState(for app: AudioApp, deviceUID: String) {
        let id = app.persistenceIdentifier
        if settingsManager.getAppAUBypassed(for: id) {
            persistentAppStrips[id]?.setBypassed(true)
            taps[app.id]?.setAUChainBypassed(true)
            appAU[id, default: AUChainState()].isBypassed = true
        }
        if settingsManager.getDeviceAUBypassed(for: deviceUID) {
            taps[app.id]?.setDeviceAUChainBypassed(true)
            deviceAU[deviceUID, default: AUChainState()].isBypassed = true
        }
    }

    // MARK: - Per-App AU Effect Chains

    func addAUEffect(for app: AudioApp, plugin: AUPluginDescriptor) {
        addAUEffect(forIdentifier: app.persistenceIdentifier, displayName: app.name, plugin: plugin)
    }

    func addAUEffect(forIdentifier identifier: String, displayName: String, plugin: AUPluginDescriptor) {
        var state = appAU[identifier] ?? AUChainState(
            entries: settingsManager.getAUEffectChain(for: identifier),
            isBypassed: settingsManager.getAppAUBypassed(for: identifier)
        )
        if plugin.isSoftubeConsole1,
           state.entries.contains(where: { $0.pluginDescriptor.isSoftubeConsole1 }) {
            logger.warning("Ignored duplicate Console 1 for \(identifier, privacy: .public)")
            return
        }
        state.entries.append(AUEffectChainEntry(plugin: plugin))
        commitAppAU(state, identifier: identifier, displayName: displayName)
    }

    func removeAUEffect(for app: AudioApp, entryID: UUID) {
        removeAUEffect(forIdentifier: app.persistenceIdentifier, displayName: app.name, entryID: entryID)
    }

    func removeAUEffect(forIdentifier identifier: String, displayName: String, entryID: UUID) {
        AUPluginWindowManager.shared.closeWindow(for: entryID)
        var state = appAU[identifier] ?? AUChainState(entries: settingsManager.getAUEffectChain(for: identifier))
        state.entries.removeAll { $0.id == entryID }
        commitAppAU(state, identifier: identifier, displayName: displayName)
    }

    func toggleAUEffect(for app: AudioApp, entryID: UUID, enabled: Bool) {
        toggleAUEffect(
            forIdentifier: app.persistenceIdentifier,
            displayName: app.name,
            entryID: entryID,
            enabled: enabled
        )
    }

    func toggleAUEffect(
        forIdentifier identifier: String,
        displayName: String,
        entryID: UUID,
        enabled: Bool
    ) {
        var state = appAU[identifier] ?? AUChainState(entries: settingsManager.getAUEffectChain(for: identifier))
        if let idx = state.entries.firstIndex(where: { $0.id == entryID }) {
            state.entries[idx].isEnabled = enabled
            if enabled { state.entries[idx].isCrashQuarantined = nil }
        }
        commitAppAU(state, identifier: identifier, displayName: displayName)
    }

    func reorderAUEffects(for app: AudioApp, entries: [AUEffectChainEntry]) {
        var state = appAU[app.persistenceIdentifier] ?? AUChainState()
        state.entries = entries
        commitAppAU(state, identifier: app.persistenceIdentifier, displayName: app.name)
    }

    func getAUEffectChain(for app: AudioApp) -> [AUEffectChainEntry] {
        getAUEffectChain(forIdentifier: app.persistenceIdentifier)
    }

    func getAUEffectChain(forIdentifier identifier: String) -> [AUEffectChainEntry] {
        appAU[identifier]?.entries ?? settingsManager.getAUEffectChain(for: identifier)
    }

    func updateAUEffectPreset(for app: AudioApp, entryID: UUID, presetData: Data?) {
        var state = appAU[app.persistenceIdentifier] ?? AUChainState()
        if let idx = state.entries.firstIndex(where: { $0.id == entryID }) {
            state.entries[idx].presetData = presetData
            state.entries[idx].selectedFactoryPresetIndex = nil
        }
        commitAppAU(state, identifier: app.persistenceIdentifier, displayName: app.name)
    }

    func selectAUFactoryPreset(for app: AudioApp, entryID: UUID, presetIndex: Int) {
        selectAUFactoryPreset(
            forIdentifier: app.persistenceIdentifier,
            displayName: app.name,
            entryID: entryID,
            presetIndex: presetIndex
        )
    }

    func selectAUFactoryPreset(
        forIdentifier identifier: String,
        displayName: String,
        entryID: UUID,
        presetIndex: Int
    ) {
        var state = appAU[identifier] ?? AUChainState(entries: settingsManager.getAUEffectChain(for: identifier))
        if let idx = state.entries.firstIndex(where: { $0.id == entryID }) {
            state.entries[idx].selectedFactoryPresetIndex = presetIndex >= 0 ? presetIndex : nil
            state.entries[idx].presetData = nil
        }
        commitAppAU(
            state,
            identifier: identifier,
            displayName: displayName,
            explicitPresetEntryID: entryID
        )
    }

    func setAUChainBypassed(for app: AudioApp, bypassed: Bool) {
        setAUChainBypassed(forIdentifier: app.persistenceIdentifier, bypassed: bypassed)
    }

    func setAUChainBypassed(forIdentifier identifier: String, bypassed: Bool) {
        persistentAppStrips[identifier]?.setBypassed(bypassed)
        for tap in taps.values where tap.app.persistenceIdentifier == identifier {
            tap.setAUChainBypassed(bypassed)
        }
        appAU[identifier, default: AUChainState()].isBypassed = bypassed
        settingsManager.setAppAUBypassed(bypassed, for: identifier)
    }

    func isAUChainBypassed(for app: AudioApp) -> Bool {
        isAUChainBypassed(forIdentifier: app.persistenceIdentifier)
    }

    func isAUChainBypassed(forIdentifier identifier: String) -> Bool {
        appAU[identifier]?.isBypassed ?? settingsManager.getAppAUBypassed(for: identifier)
    }

    func openAUPluginUI(for app: AudioApp, entryID: UUID, forceGeneric: Bool = false) {
        openAUPluginUI(
            forIdentifier: app.persistenceIdentifier,
            displayName: app.name,
            entryID: entryID,
            forceGeneric: forceGeneric
        )
    }

    func openAUPluginUI(
        forIdentifier identifier: String,
        displayName: String,
        entryID: UUID,
        forceGeneric: Bool = false
    ) {
        let strip = persistentAppStrips[identifier]
            ?? preparePersistentMixerStrip(identifier: identifier, displayName: displayName)
        guard let host = strip?.host(for: entryID),
              let au = host.audioUnit else { return }
        AUPluginWindowManager.shared.closeWindow(for: entryID)
        AUPluginWindowManager.shared.showWindow(
            for: entryID,
            audioUnit: au,
            pluginName: host.descriptor.name,
            forceGeneric: forceGeneric,
            sourceHost: host
        ) { [weak self] in
            self?.saveAUHostState(host, identifier: identifier, entryID: entryID)
        }
    }

    private func saveAUHostState(_ host: AUEffectHost, identifier: String, entryID: UUID) {
        guard let presetData = host.savePreset() else { return }
        if var state = appAU[identifier],
           let strip = persistentAppStrips[identifier],
           let idx = state.entries.firstIndex(where: { $0.id == entryID }) {
            let updatedEntry = state.entries[idx].mergingLivePresetData(
                presetData,
                matchesLastAppliedPreset: host.liveStateMatchesLastAppliedPreset(presetData)
            )
            guard updatedEntry != state.entries[idx] else { return }
            state.entries[idx] = updatedEntry
            // Rebuild the immutable chain wrapper around the same hosts so its entry
            // metadata matches the just-saved live ClassInfo. Without this, selecting
            // Default next can look like an unchanged nil preset and preserve the live
            // custom state instead of restoring the captured baseline.
            commitAppAU(state, identifier: identifier, displayName: strip.displayName)
        }
    }

    func getAUFailedEntryIDs(for app: AudioApp) -> Set<UUID> {
        getAUFailedEntryIDs(forIdentifier: app.persistenceIdentifier)
    }

    func getAUFailedEntryIDs(forIdentifier identifier: String) -> Set<UUID> {
        persistentAppStrips[identifier]?.failedEntryIDs ?? appAU[identifier]?.failedEntryIDs ?? []
    }

    func getDeviceAUFailedEntryIDs(deviceUID: String) -> Set<UUID> {
        deviceAU[deviceUID]?.failedEntryIDs ?? []
    }

    func getAUFactoryPresets(for app: AudioApp, entryID: UUID) -> [(index: Int, name: String)] {
        getAUFactoryPresets(forIdentifier: app.persistenceIdentifier, entryID: entryID)
    }

    func getAUFactoryPresets(forIdentifier identifier: String, entryID: UUID) -> [(index: Int, name: String)] {
        persistentAppStrips[identifier]?.host(for: entryID)?.factoryPresets ?? []
    }

    private func commitAppAU(
        _ state: AUChainState,
        identifier: String,
        displayName: String,
        explicitPresetEntryID: UUID? = nil
    ) {
        settingsManager.setAUEffectChain(state.entries, for: identifier)
        // SettingsManager is the persistence boundary for invariants such as one Console 1
        // per logical app. Immediately consume its authoritative normalized chain so this
        // process cannot instantiate a transient duplicate that only disappears on restart.
        let supportedEntries = settingsManager.getAUEffectChain(for: identifier)

        if supportedEntries.isEmpty {
            appAU[identifier] = nil
            persistentAppStrips.removeValue(forKey: identifier)
            for tap in taps.values where tap.app.persistenceIdentifier == identifier {
                tap.attachPersistentAUEffectChain(nil, entries: [])
            }
            refreshPersistentMixerStripSlots()
            return
        }

        let strip: PersistentMixerStrip
        if let existing = persistentAppStrips[identifier] {
            strip = existing
        } else {
            strip = PersistentMixerStrip(
                persistenceIdentifier: identifier,
                displayName: displayName,
                slot: settingsManager.getMixerStripSlot(for: identifier),
                entries: [],
                sampleRate: preferredPersistentAUSampleRate(),
                isBypassed: state.isBypassed
            )
            persistentAppStrips[identifier] = strip
        }
        strip.updateMetadata(
            displayName: displayName,
            slot: settingsManager.getMixerStripSlot(for: identifier)
        )
        strip.setBypassed(state.isBypassed)
        // Wrapper-only edits (toggle/reorder/preset) must stay at the strip's active
        // sample rate. Reconfiguring a shared Console host to the system default while
        // its tap is rendering at another rate creates a real-time format race.
        let stripSampleRate = strip.chain?.sampleRate ?? preferredPersistentAUSampleRate()
        strip.updateEntries(
            supportedEntries,
            sampleRate: stripSampleRate,
            explicitPresetEntryID: explicitPresetEntryID
        )

        var committedState = state
        committedState.entries = strip.entries
        committedState.failedEntryIDs = strip.failedEntryIDs
        appAU[identifier] = committedState
        settingsManager.setAUEffectChain(strip.entries, for: identifier)

        for tap in taps.values where tap.app.persistenceIdentifier == identifier {
            tap.attachPersistentAUEffectChain(strip.chain, entries: strip.entries)
            tap.setAUChainBypassed(state.isBypassed)
        }
        refreshPersistentMixerStripSlots()
    }

    private func syncAppAUFailedIDs(for identifier: String) {
        let ids = persistentAppStrips[identifier]?.failedEntryIDs ?? []
        if !ids.isEmpty {
            appAU[identifier, default: AUChainState()].failedEntryIDs = ids
        }
    }

    // MARK: - Per-Device AU Effect Chains

    /// SettingsManager is the source of truth even before a device has an active tap.
    /// `deviceAU` only supplements it with runtime failure IDs.
    private func persistedDeviceAUState(for deviceUID: String) -> AUChainState {
        AUChainState(
            entries: settingsManager.getDeviceAUEffectChain(for: deviceUID),
            isBypassed: settingsManager.getDeviceAUBypassed(for: deviceUID),
            failedEntryIDs: deviceAU[deviceUID]?.failedEntryIDs ?? []
        )
    }

    func addDeviceAUEffect(deviceUID: String, plugin: AUPluginDescriptor) {
        guard !plugin.isSoftubeConsole1 else {
            logger.warning("Console 1 is supported only on persistent per-app mixer strips")
            return
        }
        var state = persistedDeviceAUState(for: deviceUID)
        state.entries.append(AUEffectChainEntry(plugin: plugin))
        commitDeviceAU(state, for: deviceUID)
    }

    func removeDeviceAUEffect(deviceUID: String, entryID: UUID) {
        AUPluginWindowManager.shared.closeWindow(for: entryID)
        var state = persistedDeviceAUState(for: deviceUID)
        state.entries.removeAll { $0.id == entryID }
        commitDeviceAU(state, for: deviceUID)
    }

    func toggleDeviceAUEffect(deviceUID: String, entryID: UUID, enabled: Bool) {
        var state = persistedDeviceAUState(for: deviceUID)
        if let idx = state.entries.firstIndex(where: { $0.id == entryID }) {
            state.entries[idx].isEnabled = enabled
            if enabled { state.entries[idx].isCrashQuarantined = nil }
        }
        commitDeviceAU(state, for: deviceUID)
    }

    func reorderDeviceAUEffects(deviceUID: String, entries: [AUEffectChainEntry]) {
        var state = persistedDeviceAUState(for: deviceUID)
        state.entries = entries
        commitDeviceAU(state, for: deviceUID)
    }

    func getDeviceAUEffectChain(deviceUID: String) -> [AUEffectChainEntry] {
        settingsManager.getDeviceAUEffectChain(for: deviceUID)
    }

    func selectDeviceAUFactoryPreset(deviceUID: String, entryID: UUID, presetIndex: Int) {
        var state = persistedDeviceAUState(for: deviceUID)
        if let idx = state.entries.firstIndex(where: { $0.id == entryID }) {
            state.entries[idx].selectedFactoryPresetIndex = presetIndex >= 0 ? presetIndex : nil
            state.entries[idx].presetData = nil
        }
        commitDeviceAU(state, for: deviceUID, explicitPresetEntryID: entryID)
    }

    func openDeviceAUPluginUI(deviceUID: String, entryID: UUID, forceGeneric: Bool = false) {
        for (_, tap) in taps where tap.currentDeviceUID == deviceUID {
            if let tap = tap as? ProcessTapController,
               let host = tap.getDeviceAUHost(for: entryID),
               let au = host.audioUnit {
                let uid = deviceUID
                AUPluginWindowManager.shared.closeWindow(for: entryID)
                AUPluginWindowManager.shared.showWindow(
                    for: entryID,
                    audioUnit: au,
                    pluginName: host.descriptor.name,
                    forceGeneric: forceGeneric,
                    sourceHost: host,
                    onLiveChange: { [weak self] in
                        self?.saveDeviceAUHostState(host, deviceUID: uid, entryID: entryID)
                    },
                    onSave: { [weak self] in
                        self?.saveDeviceAUHostState(host, deviceUID: uid, entryID: entryID)
                    }
                )
                return
            }
        }
    }

    private func saveDeviceAUHostState(_ host: AUEffectHost, deviceUID: String, entryID: UUID) {
        guard let presetData = host.savePreset() else { return }
        var state = persistedDeviceAUState(for: deviceUID)
        if let idx = state.entries.firstIndex(where: { $0.id == entryID }) {
            let updatedEntry = state.entries[idx].mergingLivePresetData(
                presetData,
                matchesLastAppliedPreset: host.liveStateMatchesLastAppliedPreset(presetData)
            )
            guard updatedEntry != state.entries[idx] else { return }
            state.entries[idx] = updatedEntry
            // Keep the live chain wrapper's preset metadata in sync for the same
            // save-then-Default transition as the persistent per-app strip.
            commitDeviceAU(state, for: deviceUID, preservingLiveStateFor: host)
            host.markLivePresetDataAsApplied(presetData)
        }
    }

    func getDeviceAUFactoryPresets(deviceUID: String, entryID: UUID) -> [(index: Int, name: String)] {
        for (_, tap) in taps where tap.currentDeviceUID == deviceUID {
            if let tap = tap as? ProcessTapController,
               let host = tap.getDeviceAUHost(for: entryID) {
                return host.factoryPresets
            }
        }
        return []
    }

    func setDeviceAUChainBypassed(deviceUID: String, bypassed: Bool) {
        for (_, tap) in taps where tap.currentDeviceUID == deviceUID {
            tap.setDeviceAUChainBypassed(bypassed)
        }
        var state = persistedDeviceAUState(for: deviceUID)
        state.isBypassed = bypassed
        deviceAU[deviceUID] = state.entries.isEmpty ? nil : state
        settingsManager.setDeviceAUBypassed(bypassed, for: deviceUID)
    }

    func isDeviceAUChainBypassed(deviceUID: String) -> Bool {
        settingsManager.getDeviceAUBypassed(for: deviceUID)
    }

    private func commitDeviceAU(
        _ state: AUChainState,
        for deviceUID: String,
        explicitPresetEntryID: UUID? = nil,
        preservingLiveStateFor liveStateHost: AUEffectHost? = nil
    ) {
        var supportedState = state
        supportedState.entries.removeAll { $0.pluginDescriptor.isSoftubeConsole1 }
        deviceAU[deviceUID] = supportedState.entries.isEmpty ? nil : supportedState
        settingsManager.setDeviceAUEffectChain(supportedState.entries, for: deviceUID)
        applyDeviceAUChainToTaps(
            deviceUID: deviceUID,
            chain: supportedState.entries,
            explicitPresetEntryID: explicitPresetEntryID,
            preservingLiveStateFor: liveStateHost
        )
        if supportedState.isBypassed {
            for (_, tap) in taps where tap.currentDeviceUID == deviceUID {
                tap.setDeviceAUChainBypassed(true)
            }
        }
        syncDeviceAUFailedIDs(for: deviceUID)
    }

    func saveAllLiveAUState() {
        // The open editor is the authoritative source for an in-flight device-AU edit.
        // Save and broadcast it before selecting an arbitrary sibling tap as fallback;
        // otherwise that sibling's older ClassInfo can overwrite the user's last change.
        AUPluginWindowManager.shared.saveAllOpenWindows()

        // Snapshot before commitAppAU updates the dictionary values.
        for (appID, strip) in Array(persistentAppStrips) {
            guard !settingsManager.isIgnored(appID) else { continue }
            let entries = strip.entriesWithLiveState()
            var state = appAU[appID] ?? AUChainState(isBypassed: strip.isBypassed)
            state.entries = entries
            commitAppAU(state, identifier: appID, displayName: strip.displayName)
        }

        var savedDeviceUIDs = Set<String>()
        for (_, tap) in taps {
            guard let tap = tap as? ProcessTapController else { continue }
            if let deviceUID = tap.currentDeviceUID,
               savedDeviceUIDs.insert(deviceUID).inserted,
               let chain = tap.deviceAUEffectChainWithLiveState() {
                var state = persistedDeviceAUState(for: deviceUID)
                state.entries = chain
                commitDeviceAU(state, for: deviceUID)
            }
        }
    }

    private func syncDeviceAUFailedIDs(for deviceUID: String) {
        for (_, tap) in taps where tap.currentDeviceUID == deviceUID {
            if let tap = tap as? ProcessTapController {
                let ids = tap.deviceAUEffectChainFailedIDs
                if !ids.isEmpty {
                    deviceAU[deviceUID, default: AUChainState()].failedEntryIDs = ids
                }
                return
            }
        }
    }

    private func applyDeviceAUChainToTaps(
        deviceUID: String,
        chain: [AUEffectChainEntry],
        explicitPresetEntryID: UUID? = nil,
        preservingLiveStateFor liveStateHost: AUEffectHost? = nil
    ) {
        for (_, tap) in taps where tap.currentDeviceUID == deviceUID {
            if let concreteTap = tap as? ProcessTapController {
                concreteTap.updateDeviceAUEffectChain(
                    chain,
                    explicitPresetEntryID: explicitPresetEntryID,
                    preservingLiveStateFor: liveStateHost
                )
            } else {
                tap.updateDeviceAUEffectChain(chain)
            }
        }
    }

    // MARK: - Per-Device AutoEQ

    func getAutoEQProfile(for deviceUID: String) -> AutoEQProfile? {
        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return nil }
        return autoEQProfileManager.profile(for: selection.profileID)
    }

    func setAutoEQProfile(for deviceUID: String, profileID: String?) {
        if let profileID {
            settingsManager.setAutoEQSelection(for: deviceUID, to: AutoEQSelection(profileID: profileID, isEnabled: true))
        } else {
            settingsManager.setAutoEQSelection(for: deviceUID, to: nil)
        }
        applyAutoEQToTaps(for: deviceUID)
    }

    func setAutoEQEnabled(for deviceUID: String, enabled: Bool) {
        guard var selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return }
        selection.isEnabled = enabled
        settingsManager.setAutoEQSelection(for: deviceUID, to: selection)
        applyAutoEQToTaps(for: deviceUID)
    }

    func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
        settingsManager.getAutoEQSelection(for: deviceUID)
    }

    var autoEQPreampEnabled: Bool {
        settingsManager.autoEQPreampEnabled
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        settingsManager.autoEQPreampEnabled = enabled
        for tap in taps.values {
            tap.setAutoEQPreampEnabled(enabled)
        }
    }

    func setLoudnessCompensationEnabled(_ enabled: Bool) {
        for tap in taps.values {
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: enabled)
        }
    }

    func setLoudnessEqualizationEnabled(_ enabled: Bool) {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = enabled
        for tap in taps.values {
            tap.updateLoudnessEqualization(settings)
        }
    }

    /// Apply AutoEQ profile to all taps currently routed to the given device.
    private func applyAutoEQToTaps(for deviceUID: String) {
        for tap in taps.values {
            guard tap.currentDeviceUID == deviceUID else { continue }
            applyAutoEQToTap(tap)
        }
    }

    /// Synchronous in-memory AutoEQ profile lookup. nil = not yet cached.
    private func autoEQProfileForActivation(deviceUID: String) -> AutoEQProfile? {
        guard let device = deviceMonitor.device(for: deviceUID), device.supportsAutoEQ else { return nil }
        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID), selection.isEnabled else { return nil }
        return autoEQProfileManager.profile(for: selection.profileID)
    }

    private func tapInitialState(forApp app: AudioApp, primaryDeviceUID: String, deviceVolume: Float) -> TapInitialState {
        var loudnessEqSettings = LoudnessEqualizerSettings()
        loudnessEqSettings.enabled = settingsManager.appSettings.loudnessEqualizationEnabled
        return TapInitialState(
            eqSettings: settingsManager.getEQSettings(for: app.persistenceIdentifier),
            autoEQProfile: autoEQProfileForActivation(deviceUID: primaryDeviceUID),
            autoEQPreampEnabled: settingsManager.autoEQPreampEnabled,
            loudnessVolume: deviceVolume * volumeState.getVolume(for: app.id),
            loudnessCompensationEnabled: settingsManager.appSettings.loudnessCompensationEnabled,
            loudnessEqualizerSettings: loudnessEqSettings
        )
    }

    /// Skips AutoEQ entirely for devices that don't support it (speakers, HDMI, etc.).
    /// If the profile isn't loaded yet, triggers an async fetch and applies when ready.
    private func applyDeviceAUChainToTap(_ tap: any ProcessTapControlling) {
        guard let deviceUID = tap.currentDeviceUID else { return }
        let chain = settingsManager.getDeviceAUEffectChain(for: deviceUID)
        tap.updateDeviceAUEffectChain(chain)
        var state = persistedDeviceAUState(for: deviceUID)
        state.entries = chain
        deviceAU[deviceUID] = chain.isEmpty ? nil : state
        if state.isBypassed {
            tap.setDeviceAUChainBypassed(true)
        }
        syncDeviceAUFailedIDs(for: deviceUID)
    }

    /// Captures the destination device's AU graph as part of one switch request.
    /// Device hosts cannot be shared by concurrent callbacks, so any open editor for the
    /// outgoing host is closed before the transition and can be reopened on the new host.
    private func deviceAUTransition(
        on tap: any ProcessTapControlling,
        to deviceUID: String
    ) -> DeviceAUEffectTransition {
        Self.closeDeviceAUEditorsBackedByTap(tap)
        return DeviceAUEffectTransition(
            entries: settingsManager.getDeviceAUEffectChain(for: deviceUID),
            isBypassed: settingsManager.getDeviceAUBypassed(for: deviceUID)
        )
    }

    /// Device chains are shared in settings, but each process tap owns separate Audio Unit
    /// instances. Only the tap whose concrete host backs an editor may close that window.
    /// Kept as one transition primitive so every device-switch path uses the same rule.
    static func closeDeviceAUEditorsBackedByTap(
        _ tap: any ProcessTapControlling,
        windowManager: AUPluginWindowManager = .shared
    ) {
        if let concreteTap = tap as? ProcessTapController {
            for entry in tap.getDeviceAUEffectChainEntries() {
                guard let outgoingHost = concreteTap.getDeviceAUHost(for: entry.id) else { continue }
                windowManager.closeWindow(
                    for: entry.id,
                    ifSourceIs: outgoingHost
                )
            }
        }
    }

    private func applyAutoEQToTap(_ tap: any ProcessTapControlling) {
        guard let deviceUID = tap.currentDeviceUID else { return }

        // Skip AutoEQ for non-headphone devices (or if device not found in monitor)
        guard let device = deviceMonitor.device(for: deviceUID) else {
            logger.debug("AutoEQ skip for \(tap.app.name): device \(deviceUID) not found in monitor")
            return
        }
        guard device.supportsAutoEQ else {
            tap.updateAutoEQProfile(nil)
            logger.debug("AutoEQ skip for \(tap.app.name): \(device.name) doesn't support AutoEQ")
            return
        }

        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID),
              selection.isEnabled else {
            tap.updateAutoEQProfile(nil)
            logger.debug("AutoEQ skip for \(tap.app.name): no selection or disabled for \(device.name)")
            return
        }

        // Try in-memory first (instant)
        if let profile = autoEQProfileManager.profile(for: selection.profileID) {
            tap.updateAutoEQProfile(profile)
            return
        }

        // Profile not loaded yet — fetch asynchronously
        tap.updateAutoEQProfile(nil)
        Task { @MainActor in
            guard let profile = await autoEQProfileManager.resolveProfile(for: selection.profileID) else { return }
            // Verify tap still exists and is still routed to the same device
            guard tap.currentDeviceUID == deviceUID else { return }
            guard let latestSelection = settingsManager.getAutoEQSelection(for: deviceUID),
                  latestSelection.profileID == selection.profileID,
                  latestSelection.isEnabled else { return }
            tap.updateAutoEQProfile(profile)
        }
    }

    /// Sets the system default output device, routes followsDefault apps, and registers
    /// an echo so the resulting CoreAudio callback is consumed rather than treated as
    /// an external change.
    /// UI code should call this instead of `deviceVolumeMonitor.setDefaultDevice` directly.
    @discardableResult
    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceVolumeMonitor.setDefaultDevice(deviceID) else { return false }
        if let uid = deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid {
            outputEchoTracker.increment(uid)
            lastConfirmedDefaultUID = uid
            routeFollowsDefaultApps(to: uid)
        }
        return true
    }

    /// Sets the output device for an app.
    /// - Parameters:
    ///   - app: The app to route
    ///   - deviceUID: The device UID to route to, or nil to follow system default
    func setDevice(for app: AudioApp, deviceUID: String?) {
        if let deviceUID = deviceUID {
            // Explicit device selection - stop following default
            followsDefault.remove(app.id)
            // Defensive: re-persist routing even if in-memory state matches,
            // to guard against settings file corruption or incomplete prior writes
            settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)

            // If transitioning from follows-default to explicit and tap has a stream-specific
            // source, refresh to mixdown so it won't go stale when the default changes later.
            if let tap = taps[app.id], tap.tapSourceDeviceUID != nil {
                Task {
                    do {
                        let transition = tap.currentDeviceUID.map {
                            self.deviceAUTransition(on: tap, to: $0)
                        }
                        try await tap.refreshTapSource(nil, deviceAUTransition: transition)
                        self.applyTapOutputState(to: tap, for: app.id)
                        self.applyDeviceAUChainToTap(tap)
                    } catch {
                        self.logger.error("Failed to refresh tap source for \(app.name): \(error)")
                    }
                }
            }

            guard appDeviceRouting[app.id] != deviceUID else { return }
            appDeviceRouting[app.id] = deviceUID
        } else {
            // "System Audio" selected - follow default
            followsDefault.insert(app.id)
            settingsManager.setFollowDefault(for: app.persistenceIdentifier)

            // Route to current default (if available)
            guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                // No default available yet - routing will happen when default becomes available
                // via handleDefaultDeviceChanged callback
                logger.warning("No default device available for \(app.name), will route when available")
                return
            }
            guard appDeviceRouting[app.id] != defaultUID else { return }
            appDeviceRouting[app.id] = defaultUID
        }

        // Switch tap if needed
        guard let targetUID = appDeviceRouting[app.id] else { return }
        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: followsDefault.contains(app.id))
        if let tap = taps[app.id] {
            Task {
                do {
                    let transition = self.deviceAUTransition(on: tap, to: targetUID)
                    try await tap.switchDevice(
                        to: targetUID,
                        preferredTapSourceDeviceUID: preferredTapSourceUID,
                        sourceDeviceDead: false,
                        deviceAUTransition: transition
                    )
                    self.applyTapOutputState(to: tap, for: app.id, deviceUIDs: [targetUID])
                    self.applyAutoEQToTap(tap)
                    self.applyDeviceAUChainToTap(tap)
                    self.logger.debug("Switched \(app.name) to device: \(targetUID)")
                } catch {
                    self.logger.error("Failed to switch device for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            ensureTapExists(for: app, deviceUID: targetUID)
        }
    }

    func getDeviceUID(for app: AudioApp) -> String? {
        appDeviceRouting[app.id]
    }

    /// Returns true if the app follows system default device
    func isFollowingDefault(for app: AudioApp) -> Bool {
        followsDefault.contains(app.id)
    }

    // MARK: - Multi-Device Selection

    /// Gets the device selection mode for an app
    func getDeviceSelectionMode(for app: AudioApp) -> DeviceSelectionMode {
        volumeState.getDeviceSelectionMode(for: app.id)
    }

    /// Sets the device selection mode for an app.
    /// Triggers tap reconfiguration when mode changes.
    func setDeviceSelectionMode(for app: AudioApp, to mode: DeviceSelectionMode) {
        let previousMode = volumeState.getDeviceSelectionMode(for: app.id)
        volumeState.setDeviceSelectionMode(for: app.id, to: mode, identifier: app.persistenceIdentifier)

        guard previousMode != mode else { return }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }

    /// Gets the selected device UIDs for multi-mode
    func getSelectedDeviceUIDs(for app: AudioApp) -> Set<String> {
        volumeState.getSelectedDeviceUIDs(for: app.id)
    }

    /// Sets the selected device UIDs for multi-mode.
    /// Triggers tap reconfiguration when in multi mode.
    func setSelectedDeviceUIDs(for app: AudioApp, to uids: Set<String>) {
        let previousUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
        volumeState.setSelectedDeviceUIDs(for: app.id, to: uids, identifier: app.persistenceIdentifier)

        guard previousUIDs != uids,
              getDeviceSelectionMode(for: app) == .multi else { return }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }

    /// Reorders every active multi-output tap after the user changes output-device
    /// priority. The first successfully committed UID remains the aggregate clock and
    /// the device-AU owner; UI routing is updated only after that commit succeeds.
    func reconcileMultiOutputPriority() {
        let multiOutputApps = apps.filter {
            getDeviceSelectionMode(for: $0) == .multi
        }
        Task {
            for app in multiOutputApps {
                await updateTapForCurrentMode(for: app)
            }
        }
    }

    /// Multi-output order matches the picker: user device priority first, then the
    /// stable name order used for newly discovered devices. The first selected device
    /// is the aggregate clock and owns the shared per-device AU chain.
    private func orderedSelectedDeviceUIDs(_ uids: Set<String>) -> [String] {
        let orderedKnown = prioritySortedOutputDevices
            .map(\.uid)
            .filter { uids.contains($0) }
        let known = Set(orderedKnown)
        return orderedKnown + uids.filter { !known.contains($0) }.sorted()
    }

    /// Updates tap configuration based on current mode and selected devices
    private func updateTapForCurrentMode(for app: AudioApp) async {
        let mode = getDeviceSelectionMode(for: app)

        let deviceUIDs: [String]
        switch mode {
        case .single:
            if isFollowingDefault(for: app), let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else if let deviceUID = appDeviceRouting[app.id] {
                deviceUIDs = [deviceUID]
            } else if let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else {
                logger.warning("No device available for \(app.name) in single mode")
                return
            }

        case .multi:
            let selectedUIDs = orderedSelectedDeviceUIDs(getSelectedDeviceUIDs(for: app))
            if selectedUIDs.isEmpty {
                return
            }
            deviceUIDs = selectedUIDs
        }

        // Update or create tap with the device set
        if let tap = taps[app.id] {
            // Tap exists - update devices
            if tap.currentDeviceUIDs != deviceUIDs {
                do {
                    let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
                    let transition = deviceAUTransition(on: tap, to: deviceUIDs[0])
                    try await tap.updateDevices(
                        to: deviceUIDs,
                        preferredTapSourceDeviceUID: preferredTapSourceUID,
                        sourceDeviceDead: false,
                        deviceAUTransition: transition
                    )
                    appDeviceRouting[app.id] = deviceUIDs[0]
                    applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)
                    applyDeviceAUChainToTap(tap)
                    logger.debug("Updated \(app.name) to \(deviceUIDs.count) device(s)")
                } catch {
                    logger.error("Failed to update devices for \(app.name): \(error.localizedDescription)")
                }
            } else {
                appDeviceRouting[app.id] = deviceUIDs[0]
            }
        } else {
            // No tap exists - create one
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
        }
    }

    /// Creates a tap with the specified device UIDs
    private func ensureTapWithDevices(for app: AudioApp, deviceUIDs: [String]) {
        guard !deviceUIDs.isEmpty else { return }
        guard taps[app.id] == nil else { return }
        guard permission.status == .authorized else { return }
        retireOtherTaps(for: app)

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, deviceUIDs, preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)

            let initial = tapInitialState(
                forApp: app,
                primaryDeviceUID: deviceUIDs[0],
                deviceVolume: tap.currentDeviceVolume
            )
            try tap.activate(initial: initial)
            taps[app.id] = tap
            appDeviceRouting[app.id] = deviceUIDs[0]

            // Catalog AutoEQ may not have been cached yet — kick off async resolve.
            if initial.autoEQProfile == nil {
                applyAutoEQToTap(tap)
            }

            attachPersistentMixerStrip(to: tap, for: app)
            applyDeviceAUChainToTap(tap)
            loadPersistedAUBypassState(for: app, deviceUID: deviceUIDs[0])

            logger.debug("Created tap for \(app.name) on \(deviceUIDs.count) device(s)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    func applyPersistedSettings() {
        guard permission.status == .authorized else { return }
        preparePersistentMixerStrips()

        // Warm the AutoEQ cache for every (app, device) selection so that subsequent
        // tap activations can apply correction synchronously inside activate(initial:)
        // instead of falling back to the async resolve path. Imported profiles are
        // already loaded by AutoEQProfileManager.init.
        let selectedProfileIDs: Set<String> = Set(apps.compactMap { app -> String? in
            let deviceUID = appDeviceRouting[app.id] ?? deviceVolumeMonitor.defaultDeviceUID
            guard let deviceUID, let selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return nil }
            return selection.isEnabled ? selection.profileID : nil
        })
        let manager = autoEQProfileManager
        Task { @MainActor in
            for id in selectedProfileIDs where manager.profile(for: id) == nil {
                _ = await manager.resolveProfile(for: id)
            }
        }

        for app in apps {
            if let existing = taps[app.id],
               existing.app.processObjectIDs != app.processObjectIDs {
                // The logical app gained/lost a CoreAudio process object. CATapDescription is
                // immutable, so hand off to a fresh tap while retaining the persistent strip.
                existing.invalidateForHandoff()
                taps.removeValue(forKey: app.id)
                appliedPIDs.remove(app.id)
            }
            guard !appliedPIDs.contains(app.id) else { continue }
            guard !settingsManager.isIgnored(app.persistenceIdentifier) else { continue }

            // Load saved device selection mode (single vs multi)
            let savedMode = volumeState.loadSavedDeviceSelectionMode(for: app.id, identifier: app.persistenceIdentifier)
            let mode = savedMode ?? .single

            // Load saved volume, mute, and boost state
            let savedVolume = volumeState.loadSavedVolume(for: app.id, identifier: app.persistenceIdentifier)
            let savedMute = volumeState.loadSavedMute(for: app.id, identifier: app.persistenceIdentifier)
            _ = volumeState.loadSavedBoost(for: app.id, identifier: app.persistenceIdentifier)

            // Handle multi-device mode
            if mode == .multi {
                if let savedUIDs = volumeState.loadSavedSelectedDeviceUIDs(for: app.id, identifier: app.persistenceIdentifier),
                   !savedUIDs.isEmpty {
                    // Filter to currently available devices, maintaining deterministic order
                    let availableUIDs = orderedSelectedDeviceUIDs(
                        Set(savedUIDs.filter { deviceMonitor.device(for: $0) != nil })
                    )
                    if !availableUIDs.isEmpty {
                        logger.debug("Restoring multi-device mode for \(app.name) with \(availableUIDs.count) device(s)")
                        ensureTapWithDevices(for: app, deviceUIDs: availableUIDs)

                        // Mark as applied if tap created successfully
                        guard taps[app.id] != nil else { continue }
                        // Set primary device routing so the UI row renders
                        appDeviceRouting[app.id] = availableUIDs[0]
                        appliedPIDs.insert(app.id)

                        // Apply volume (with boost) and mute
                        if savedVolume != nil {
                            if let tap = taps[app.id] {
                                applyTapOutputState(to: tap, for: app.id, deviceUIDs: availableUIDs)
                            }
                        }
                        if let muted = savedMute, muted {
                            taps[app.id]?.isMuted = true
                        }
                        continue  // Skip single-device path
                    }
                    // All saved devices unavailable - fall through to single-device mode
                    logger.debug("All multi-mode devices unavailable for \(app.name), falling back to single mode")
                }
            }

            // Single-device mode (or multi-mode fallback)
            let deviceUID: String
            if settingsManager.isFollowingDefault(for: app.persistenceIdentifier) {
                // App follows system default (new app or explicitly set to follow)
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device available for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) follows system default: \(deviceUID)")
            } else if let savedDeviceUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
                      deviceMonitor.device(for: savedDeviceUID) != nil {
                // Explicit device routing exists and device is available
                deviceUID = savedDeviceUID
                logger.debug("Applying saved device routing to \(app.name): \(deviceUID)")
            } else {
                // Saved device temporarily unavailable: fall back to system default for now
                // Don't persist - keep original device preference for when it reconnects
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) device temporarily unavailable, using default: \(deviceUID)")
            }
            appDeviceRouting[app.id] = deviceUID

            // If a tap already exists but is on the wrong device (e.g., app reappeared
            // after the default changed while it was absent), switch it.
            if let existingTap = taps[app.id], existingTap.currentDeviceUIDs != [deviceUID] {
                let preferredSource = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
                Task {
                    do {
                        let transition = self.deviceAUTransition(on: existingTap, to: deviceUID)
                        try await existingTap.switchDevice(
                            to: deviceUID,
                            preferredTapSourceDeviceUID: preferredSource,
                            sourceDeviceDead: false,
                            deviceAUTransition: transition
                        )
                        self.applyTapOutputState(to: existingTap, for: app.id, deviceUIDs: [deviceUID])
                        self.applyAutoEQToTap(existingTap)
                        self.applyDeviceAUChainToTap(existingTap)
                    } catch {
                        self.logger.error("Failed to re-route \(app.name) to \(deviceUID): \(error.localizedDescription)")
                    }
                }
                appliedPIDs.insert(app.id)
                continue
            }

            // Always create tap for audio apps (always-on strategy)
            ensureTapExists(for: app, deviceUID: deviceUID)

            // Only mark as applied if tap was successfully created
            // This allows retry on next applyPersistedSettings() call if tap failed
            guard taps[app.id] != nil else { continue }
            appliedPIDs.insert(app.id)

            if savedVolume != nil {
                let effective = effectiveVolume(for: app.id, deviceUIDs: [deviceUID])
                let displayPercent = Int(effective * 100)
                logger.debug("Applying saved volume \(displayPercent)% (with boost) to \(app.name)")
                taps[app.id]?.volume = effective
            }

            if let muted = savedMute, muted {
                logger.debug("Applying saved mute state to \(app.name)")
                taps[app.id]?.isMuted = true
            }
        }
    }

    private func ensureTapExists(for app: AudioApp, deviceUID: String) {
        guard taps[app.id] == nil else { return }
        guard permission.status == .authorized else { return }
        retireOtherTaps(for: app)

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, [deviceUID], preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: [deviceUID])

            let initial = tapInitialState(
                forApp: app,
                primaryDeviceUID: deviceUID,
                deviceVolume: tap.currentDeviceVolume
            )
            try tap.activate(initial: initial)
            taps[app.id] = tap

            // Catalog AutoEQ may not have been cached yet — kick off async resolve.
            // Imported profiles always hit the synchronous path above.
            if initial.autoEQProfile == nil {
                applyAutoEQToTap(tap)
            }

            // Attach the long-lived per-app strip; this does not instantiate another AU.
            attachPersistentMixerStrip(to: tap, for: app)
            syncAppAUFailedIDs(for: app.persistenceIdentifier)
            let savedDeviceAU = settingsManager.getDeviceAUEffectChain(for: deviceUID)
            if !savedDeviceAU.isEmpty {
                tap.updateDeviceAUEffectChain(savedDeviceAU)
                deviceAU[deviceUID, default: AUChainState()].entries = savedDeviceAU
                syncDeviceAUFailedIDs(for: deviceUID)
            }

            loadPersistedAUBypassState(for: app, deviceUID: deviceUID)

            logger.debug("Created tap for \(app.name)")
        } catch {
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    /// Enforces one live HAL producer for each persistent mixer strip. Teardown joins the
    /// old IOProc before the replacement is created, so no old callback can overlap the
    /// new tap through one stateful Console 1 instance.
    private func retireOtherTaps(for app: AudioApp) {
        let oldPIDs = taps.compactMap { pid, tap in
            pid != app.id && tap.app.persistenceIdentifier == app.persistenceIdentifier
                ? pid
                : nil
        }
        for pid in oldPIDs {
            pendingCleanup.removeValue(forKey: pid)?.cancel()
            if let oldTap = taps.removeValue(forKey: pid) {
                oldTap.invalidateForHandoff()
            }
            appDeviceRouting.removeValue(forKey: pid)
            followsDefault.remove(pid)
            appliedPIDs.remove(pid)
        }
    }

    /// Restores the default to `lastConfirmedDefaultUID` (what the user/FineTune intended).
    /// Falls back to highest-priority device if the confirmed device is gone.
    private func restoreConfirmedDefault() {
        if let restoreUID = lastConfirmedDefaultUID,
           let device = deviceMonitor.device(for: restoreUID),
           isAliveCheck(device.id) {
            if deviceVolumeMonitor.defaultDeviceUID != restoreUID {
                if deviceVolumeMonitor.setDefaultDevice(device.id) {
                    outputEchoTracker.increment(restoreUID)
                    logger.info("Restored default → \(device.name)")
                }
            }
            routeFollowsDefaultApps(to: restoreUID)
        } else {
            reEvaluateOutputDefault()
        }
    }

    /// Ensures system default matches highest-priority alive connected device.
    /// Routes followsDefault apps and switches their taps if default changes.
    /// Returns the resolved target UID.
    @discardableResult
    private func reEvaluateOutputDefault(excluding: String? = nil) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        if target.uid != currentDefault {
            if deviceVolumeMonitor.setDefaultDevice(target.id) {
                outputEchoTracker.increment(target.uid)
                logger.info("System default → \(target.name)")
            }
        }

        lastConfirmedDefaultUID = target.uid
        routeFollowsDefaultApps(to: target.uid)
        return target.uid
    }

    /// Ensures system default input matches highest-priority alive connected input device.
    /// Returns the resolved target UID.
    @discardableResult
    private func reEvaluateInputDefault(excluding: String? = nil) -> String? {
        guard let target = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: excluding,
            isAlive: isAliveCheck
        ) else { return nil }

        if target.uid != deviceVolumeMonitor.defaultInputDeviceUID {
            if deviceVolumeMonitor.setDefaultInputDevice(target.id) {
                inputEchoTracker.increment(target.uid)
                logger.info("Default input → \(target.name)")
            }
        }
        return target.uid
    }

    /// Routes all followsDefault apps to the given device UID and switches their taps.
    /// Early-exits if all apps are already routed to the target (avoids unnecessary tap switches).
    private func routeFollowsDefaultApps(to targetUID: String) {
        guard !followsDefault.allSatisfy({ appDeviceRouting[$0] == targetUID }) else { return }

        for pid in followsDefault {
            appDeviceRouting[pid] = targetUID
        }

        var tapsToSwitch: [(appID: pid_t, appName: String, tap: any ProcessTapControlling)] = []
        for app in apps {
            guard followsDefault.contains(app.id), let tap = taps[app.id] else { continue }
            tapsToSwitch.append((app.id, app.name, tap))
        }
        guard !tapsToSwitch.isEmpty else { return }

        Task {
            for (appID, appName, tap) in tapsToSwitch {
                do {
                    let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: true)
                    let transition = self.deviceAUTransition(on: tap, to: targetUID)
                    try await tap.switchDevice(
                        to: targetUID,
                        preferredTapSourceDeviceUID: preferredTapSourceUID,
                        sourceDeviceDead: false,
                        deviceAUTransition: transition
                    )
                    self.applyTapOutputState(to: tap, for: appID, deviceUIDs: [targetUID])
                    self.applyAutoEQToTap(tap)
                    self.applyDeviceAUChainToTap(tap)
                } catch {
                    self.logger.error("Failed to switch \(appName) to \(targetUID): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Called when device disappears - updates routing and switches taps immediately
    private func handleDeviceDisconnected(_ deviceUID: String, name deviceName: String) {
        // Clean up alive watcher — use UID lookup since device is already removed from monitor
        removeAliveWatcher(forUID: deviceUID)

        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = outputPriorityState, uid == deviceUID {
            task.cancel()
            outputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it
        let wasDefaultOutput = deviceUID == deviceVolumeMonitor.defaultDeviceUID

        // Use priority-based fallback (resolve checks isDeviceAlive internally)
        let fallbackDevice = Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        var affectedApps: [AudioApp] = []
        var singleModeTapsToSwitch: [(tap: any ProcessTapControlling, fallbackUID: String)] = []
        var multiModeTapsToUpdate: [(tap: any ProcessTapControlling, remainingUIDs: [String])] = []

        // Iterate over taps instead of apps - apps list may be empty if disconnected device
        // was the system default (CoreAudio removes app from process list when output disappears)
        for tap in taps.values {
            let app = tap.app
            let mode = getDeviceSelectionMode(for: app)

            // Check if this tap uses the disconnected device
            guard tap.currentDeviceUIDs.contains(deviceUID) else { continue }

            affectedApps.append(app)

            if mode == .multi && tap.currentDeviceUIDs.count > 1 {
                // Multi-device mode: remove disconnected device, keep others
                let remainingUIDs = tap.currentDeviceUIDs.filter { $0 != deviceUID }
                if !remainingUIDs.isEmpty {
                    multiModeTapsToUpdate.append((tap: tap, remainingUIDs: remainingUIDs))
                    // Update in-memory selection to remove disconnected device (don't persist)
                    var currentSelection = volumeState.getSelectedDeviceUIDs(for: app.id)
                    currentSelection.remove(deviceUID)
                    volumeState.setSelectedDeviceUIDs(for: app.id, to: currentSelection, identifier: nil)
                    continue
                }
                // All devices gone in multi-mode, fall through to single-device fallback
            }

            // Single-device mode (or multi-mode with no remaining devices): switch to fallback
            if let fallback = fallbackDevice {
                appDeviceRouting[app.id] = fallback.uid
                // Set to follow default in-memory (UI shows "System Audio")
                // Don't persist - original device preference stays in settings for reconnection
                followsDefault.insert(app.id)
                singleModeTapsToSwitch.append((tap: tap, fallbackUID: fallback.uid))
            } else {
                logger.error("No fallback device available for \(app.name)")
            }
        }

        // Execute device switches
        if !singleModeTapsToSwitch.isEmpty || !multiModeTapsToUpdate.isEmpty {
            Task {
                // Handle single-mode switches — source device is dead, skip crossfade
                for (tap, fallbackUID) in singleModeTapsToSwitch {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [fallbackUID], isFollowsDefault: true)
                        let transition = self.deviceAUTransition(on: tap, to: fallbackUID)
                        try await tap.switchDevice(
                            to: fallbackUID,
                            preferredTapSourceDeviceUID: preferredTapSourceUID,
                            sourceDeviceDead: true,
                            deviceAUTransition: transition
                        )
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: [fallbackUID])
                        self.applyAutoEQToTap(tap)
                        self.applyDeviceAUChainToTap(tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) to fallback: \(error.localizedDescription)")
                    }
                }

                // Handle multi-mode updates (remove disconnected device from aggregate)
                // Source device is dead, skip crossfade
                for (tap, remainingUIDs) in multiModeTapsToUpdate {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: remainingUIDs, isFollowsDefault: self.followsDefault.contains(tap.app.id))
                        let transition = self.deviceAUTransition(on: tap, to: remainingUIDs[0])
                        try await tap.updateDevices(
                            to: remainingUIDs,
                            preferredTapSourceDeviceUID: preferredTapSourceUID,
                            sourceDeviceDead: true,
                            deviceAUTransition: transition
                        )
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: remainingUIDs)
                        self.applyDeviceAUChainToTap(tap)
                        self.logger.debug("Removed \(deviceName) from \(tap.app.name) multi-device output")
                    } catch {
                        self.logger.error("Failed to update \(tap.app.name) devices: \(error.localizedDescription)")
                    }
                }
            }
        }

        if !affectedApps.isEmpty {
            let fallbackName = fallbackDevice?.name ?? "none"
            logger.info("\(deviceName) disconnected, \(affectedApps.count) app(s) affected")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showDisconnectNotification(deviceName: deviceName, fallbackName: fallbackName, affectedApps: affectedApps)
            }
        }

        // If the disconnected device was the system default, override to priority fallback
        if wasDefaultOutput {
            reEvaluateOutputDefault(excluding: deviceUID)
        }
    }

    /// Called when a device appears - switches pinned apps back to their preferred device
    private func handleDeviceConnected(_ deviceUID: String, name deviceName: String) {
        // Register newly connected device in priority list
        settingsManager.ensureDeviceInPriority(deviceUID)

        var affectedApps: [AudioApp] = []
        var tapsToSwitch: [any ProcessTapControlling] = []

        // Iterate over taps for consistency with handleDeviceDisconnected
        for tap in taps.values {
            let app = tap.app

            // Skip apps that are PERSISTED as following default - they don't have explicit device preferences
            // Note: in-memory followsDefault may include temporarily displaced apps, so check persisted state
            guard !settingsManager.isFollowingDefault(for: app.persistenceIdentifier) else { continue }

            // Check if this app was pinned to the reconnected device (from persisted settings)
            let persistedUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier)
            guard persistedUID == deviceUID else { continue }

            // App was pinned to this device - switch it back
            guard appDeviceRouting[app.id] != deviceUID else { continue }

            affectedApps.append(app)
            appDeviceRouting[app.id] = deviceUID
            // Remove from followsDefault since we're restoring explicit routing
            followsDefault.remove(app.id)
            tapsToSwitch.append(tap)
        }

        if !tapsToSwitch.isEmpty {
            Task {
                for tap in tapsToSwitch {
                    do {
                        let preferredTapSourceUID = self.preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: false)
                        let transition = self.deviceAUTransition(on: tap, to: deviceUID)
                        try await tap.switchDevice(
                            to: deviceUID,
                            preferredTapSourceDeviceUID: preferredTapSourceUID,
                            sourceDeviceDead: false,
                            deviceAUTransition: transition
                        )
                        self.applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: [deviceUID])
                        self.applyAutoEQToTap(tap)
                        self.applyDeviceAUChainToTap(tap)
                    } catch {
                        self.logger.error("Failed to switch \(tap.app.name) back to \(deviceName): \(error.localizedDescription)")
                    }
                }
            }
        }

        // Second pass: restore multi-device apps that had this device in their selection
        var multiModeTapsToUpdate: [any ProcessTapControlling] = []
        for tap in taps.values {
            let app = tap.app
            guard settingsManager.getDeviceSelectionMode(for: app.persistenceIdentifier) == .multi else { continue }
            guard let persistedUIDs = settingsManager.getSelectedDeviceUIDs(for: app.persistenceIdentifier),
                  persistedUIDs.contains(deviceUID) else { continue }
            let currentUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
            guard !currentUIDs.contains(deviceUID) else { continue }

            // Add the reconnected device back to in-memory selection
            var updatedUIDs = currentUIDs
            updatedUIDs.insert(deviceUID)
            volumeState.setSelectedDeviceUIDs(for: app.id, to: updatedUIDs, identifier: app.persistenceIdentifier)
            multiModeTapsToUpdate.append(tap)
        }

        if !multiModeTapsToUpdate.isEmpty {
            Task {
                for tap in multiModeTapsToUpdate {
                    await self.updateTapForCurrentMode(for: tap.app)
                }
            }
            logger.info("\(deviceName) reconnected, restored to \(multiModeTapsToUpdate.count) multi-device app(s)")
        }

        if !affectedApps.isEmpty {
            logger.info("\(deviceName) reconnected, switched \(affectedApps.count) app(s) back")
            if settingsManager.appSettings.showDeviceDisconnectAlerts {
                showReconnectNotification(deviceName: deviceName, affectedApps: affectedApps)
            }
        }

        // Only override the default if the newly connected device IS the highest-priority
        // device (i.e., a higher-priority device just came back). If a lower-priority device
        // connects while the user is on a higher-priority device, respect the current default —
        // the user chose it. We still enter PENDING_AUTOSWITCH to guard against macOS
        // auto-switching to the new device.
        let currentDefault = deviceVolumeMonitor.defaultDeviceUID
        let isNewDeviceHigherPriority = (deviceUID == Self.resolveHighestPriority(
            priorityOrder: settingsManager.devicePriorityOrder,
            connectedDevices: outputDevices,
            isAlive: isAliveCheck
        )?.uid)

        // If this device is present but not alive, watch for it to become alive
        if let device = deviceMonitor.device(for: deviceUID),
           !isAliveCheck(device.id) {
            installAliveWatcher(deviceID: device.id, uid: deviceUID, name: deviceName)
        }

        if isNewDeviceHigherPriority, deviceUID != currentDefault {
            // A higher-priority device reconnected — switch to it
            reEvaluateOutputDefault()
        } else if !isNewDeviceHigherPriority, currentDefault == deviceUID {
            // macOS already auto-switched to the lower-priority device — restore
            // what the user was on (not highest priority — they may have chosen a mid-priority device)
            restoreConfirmedDefault()
        }

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one.
        if case .pendingAutoSwitch(_, let oldTask) = outputPriorityState {
            oldTask.cancel()
            outputPriorityState = .stable
        }

        // Always enter PENDING_AUTOSWITCH for the newly connected device.
        // macOS may auto-switch to it multiple times during BT firmware handshake.
        // Without this grace period, auto-switches would be treated as "genuine user change".
        let transport = deviceMonitor.device(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.outputPriorityState = .stable
            self.logger.debug("Auto-switch grace period expired, no macOS switch detected")
        }

        lastAutoSwitchOverrideTime = nil
        outputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
        logger.debug("Entered PENDING_AUTOSWITCH for \(deviceName) (\(timeout)s grace)")
    }

    // MARK: - Alive Watchers

    /// Installs a one-shot HAL listener for kAudioDevicePropertyDeviceIsAlive on a device
    /// that is present but not yet alive. When the device becomes alive, re-runs
    /// handleDeviceConnected so priority is re-evaluated. Self-removes after firing or timeout.
    private func installAliveWatcher(deviceID: AudioDeviceID, uid: String, name: String) {
        guard aliveWatchers[deviceID] == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isAliveCheck(deviceID) else { return }
                self.logger.info("Device became alive: \(name) (\(uid)), re-evaluating priority")
                self.removeAliveWatcher(deviceID)
                self.handleDeviceConnected(uid, name: name)
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        guard status == noErr else {
            logger.warning("Failed to install alive watcher for \(name) (\(deviceID)): \(status)")
            return
        }

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            self.logger.debug("Alive watcher timed out for \(name) (\(uid))")
            self.removeAliveWatcher(deviceID)
        }

        aliveWatchers[deviceID] = (uid: uid, block: block, timeout: timeoutTask)
        logger.debug("Installed alive watcher for \(name) (\(uid))")
    }

    /// Removes a one-shot alive watcher by device ID, cleaning up the HAL listener and timeout.
    private func removeAliveWatcher(_ deviceID: AudioDeviceID) {
        guard let watcher = aliveWatchers.removeValue(forKey: deviceID) else { return }
        watcher.timeout.cancel()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, watcher.block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove alive watcher for device \(deviceID): \(status)")
        }
    }

    /// Removes a one-shot alive watcher by device UID. Used during disconnect when the
    /// device is already removed from the monitor's list and device(for:) returns nil.
    private func removeAliveWatcher(forUID uid: String) {
        guard let (deviceID, _) = aliveWatchers.first(where: { $0.value.uid == uid }) else { return }
        removeAliveWatcher(deviceID)
    }

    private func showReconnectNotification(deviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Reconnected"
        content.body = "\"\(deviceName)\" is back. \(affectedApps.count) app(s) switched back."
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-reconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    private func showDisconnectNotification(deviceName: String, fallbackName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Device Disconnected"
        content.body = "\"\(deviceName)\" disconnected. \(affectedApps.count) app(s) switched to \(fallbackName)"
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "device-disconnect-\(deviceName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    /// Called when system default output device changes - switches apps that follow default
    private func handleDefaultDeviceChanged(_ newDefaultUID: String) {
        // State machine: if we're waiting for macOS to auto-switch after a device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = outputPriorityState {
            // Check echoes FIRST — FineTune's own changes (UI, restoreConfirmedDefault)
            // create echoes. Consuming before Case 1 ensures FineTune UI changes aren't
            // mistaken for macOS auto-switches.
            if outputEchoTracker.consume(newDefaultUID) {
                return
            }

            if newDefaultUID == pendingUID {
                // Settling heuristic: if >1s since last override, BT auto-switches have
                // settled. This is likely the user changing via System Settings — accept it.
                // BT auto-switches happen within ms; user actions take >1s.
                if let lastOverride = lastAutoSwitchOverrideTime,
                   Date().timeIntervalSince(lastOverride) > 1.0 {
                    timeoutTask.cancel()
                    outputPriorityState = .stable
                    lastConfirmedDefaultUID = newDefaultUID
                    lastAutoSwitchOverrideTime = nil
                    routeFollowsDefaultApps(to: newDefaultUID)
                    let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? newDefaultUID
                    logger.info("Accepted user change to \(deviceName) (settled >1s)")
                    return
                }

                // Case 1: macOS auto-switched to the newly connected device — restore what
                // the user was on. Re-enter PENDING_AUTOSWITCH for further auto-switches.
                timeoutTask.cancel()
                restoreConfirmedDefault()
                lastAutoSwitchOverrideTime = Date()
                let transport = deviceMonitor.device(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.outputPriorityState = .stable
                    self.lastAutoSwitchOverrideTime = nil
                    self.logger.debug("Auto-switch grace period expired after override")
                }
                outputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }

            // Case 3: Genuine user intent (different device, not our echo) — respect it.
            timeoutTask.cancel()
            outputPriorityState = .stable
            lastAutoSwitchOverrideTime = nil
        }

        // Suppress echo from our own priority-based override (when not in pendingAutoSwitch)
        if outputEchoTracker.consume(newDefaultUID) {
            return
        }

        // If any echo counter is pending, another override is in flight — skip interim routing
        if outputEchoTracker.hasPending {
            logger.debug("Skipping followsDefault routing — echo pending")
            return
        }

        // Check if the new default device is known and alive.
        guard let newDevice = deviceMonitor.device(for: newDefaultUID) else {
            // Device not yet in monitor's list (e.g., BT device default-changed before device-list
            // notification). Defer — the upcoming handleDeviceConnected will enforce priority.
            logger.debug("Default changed to unknown device \(newDefaultUID), deferring to device list refresh")
            return
        }

        let newDeviceIsAlive = isAliveCheck(newDevice.id)

        if !newDeviceIsAlive {
            // Dead device became default (race with disconnect) — override to priority fallback
            reEvaluateOutputDefault()
        } else {
            // Genuine change to a live device — route followsDefault apps
            lastConfirmedDefaultUID = newDefaultUID
            routeFollowsDefaultApps(to: newDefaultUID)

            let affectedApps = apps.filter { followsDefault.contains($0.id) }
            if !affectedApps.isEmpty {
                let deviceName = deviceMonitor.device(for: newDefaultUID)?.name ?? "Default Output"
                logger.info("Default changed to \(deviceName), \(affectedApps.count) app(s) following")
                if settingsManager.appSettings.showDeviceDisconnectAlerts {
                    showDefaultChangedNotification(newDeviceName: deviceName, affectedApps: affectedApps)
                }
            }
        }
    }

    private func showDefaultChangedNotification(newDeviceName: String, affectedApps: [AudioApp]) {
        let content = UNMutableNotificationContent()
        content.title = "Default Audio Device Changed"
        content.body = "\(affectedApps.count) app(s) switched to \"\(newDeviceName)\""
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "default-device-changed",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    /// Returns the preferred tap source device UID for stream-specific capture.
    /// Only follows-default apps use stream-specific taps (multichannel preserved, tap always
    /// valid because the app switches device when default changes). Explicitly-routed apps
    /// always use stereo mixdown (nil) — their tap never goes stale when the default changes.
    private func preferredTapSourceDeviceUID(forOutputUIDs outputUIDs: [String], isFollowsDefault: Bool) -> String? {
        guard isFollowsDefault else { return nil }
        guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else { return nil }
        return outputUIDs.contains(defaultUID) ? defaultUID : nil
    }

    private func cleanupStaleTaps() {
        let activePIDs = Set(apps.map { $0.id })
        let stalePIDs = Set(taps.keys).subtracting(activePIDs)

        // Cancel cleanup for PIDs that reappeared — but only if bundleID matches.
        // PID reuse by a different app should not rescue the old tap.

        for pid in activePIDs {
            guard let task = pendingCleanup[pid] else { continue }

            let reappearedApp = apps.first { $0.id == pid }
            let existingTap = taps[pid]

            if let reappearedApp, let existingTap,
               reappearedApp.bundleID != existingTap.app.bundleID {
                // PID was reused by a different app — let the old tap be destroyed
                logger.debug("PID \(pid) reused by different app (\(reappearedApp.bundleID ?? "nil") vs \(existingTap.app.bundleID ?? "nil")), not cancelling cleanup")
                continue
            }

            pendingCleanup.removeValue(forKey: pid)
            task.cancel()
            // Don't remove from appliedPIDs — the tap is still alive and the aggregate
            // device is still running. The process just transiently stopped audio I/O
            // during a device change (kAudioProcessPropertyIsRunning flicker).
            // Device routing is already handled by routeFollowsDefaultApps (follows-default)
            // or stays put (explicit routing). Re-processing would cause an unnecessary
            // crossfade that interrupts audio.
            logger.debug("Cancelled pending cleanup for PID \(pid) - app reappeared")
        }

        // Schedule cleanup for newly stale PIDs (with grace period)
        for pid in stalePIDs {
            guard pendingCleanup[pid] == nil else { continue }  // Already pending

            pendingCleanup[pid] = Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }

                // Double-check still stale
                let currentPIDs = Set(self.apps.map { $0.id })
                guard !currentPIDs.contains(pid) else {
                    self.pendingCleanup.removeValue(forKey: pid)
                    return
                }

                // Now safe to cleanup
                if let tap = self.taps.removeValue(forKey: pid) {
                    tap.invalidate()
                    self.logger.debug("Cleaned up stale tap for PID \(pid)")
                }
                self.appDeviceRouting.removeValue(forKey: pid)
                self.followsDefault.remove(pid)
                self.appliedPIDs.remove(pid)  // Allow re-initialization if app resumes
                self.pendingCleanup.removeValue(forKey: pid)
            }
        }

        // Include pending PIDs in cleanup exclusion to avoid premature state cleanup
        let pidsToKeep = activePIDs.union(Set(pendingCleanup.keys))
        appliedPIDs = appliedPIDs.intersection(pidsToKeep)
        followsDefault = followsDefault.intersection(pidsToKeep)
        volumeState.cleanup(keeping: pidsToKeep)
    }

    /// Debounced stale tap cleanup — coalesces rapid app-list changes into a single cleanup pass.
    private func scheduleStaleCleanup() {
        staleCleanupTask?.cancel()
        staleCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.cleanupStaleTaps()
        }
    }

    // MARK: - Tap Health Monitor

    /// Starts a periodic health check that recreates unresponsive taps.
    /// Checks every 2 seconds; after 3 consecutive misses (~6s), the tap is presumed dead.
    private func startHealthMonitor() {
        guard healthMonitorTask == nil else { return }
        healthMonitorTask = Task { @MainActor [weak self] in
            var consecutiveMisses: [pid_t: Int] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }

                // Skip entirely when no taps exist — avoids unnecessary work at idle (#176)
                guard !self.taps.isEmpty else { continue }

                let now = Date()

                for (pid, tap) in self.taps {
                    // Skip muted apps — no callbacks while muted isn't a health signal
                    guard !tap.isMuted else { continue }

                    // Skip PIDs in recovery cooldown to prevent recreation thrashing
                    if let cooldownEnd = self.tapRecoveryCooldownUntil[pid], now < cooldownEnd {
                        continue
                    }

                    guard tap.isHealthCheckEligible(minActiveSeconds: 5.0) else { continue }

                    // Only health-check apps that are actively streaming (isRunning=true).
                    // Paused apps have no callbacks, which is normal — not a health signal.
                    let isActivelyStreaming = self.processMonitor.activeApps.contains { $0.id == pid }
                    guard isActivelyStreaming else {
                        consecutiveMisses[pid] = 0
                        continue
                    }

                    if tap.hasRecentAudioCallback(within: 3.0) {
                        consecutiveMisses[pid] = 0
                    } else {
                        let misses = (consecutiveMisses[pid] ?? 0) + 1
                        consecutiveMisses[pid] = misses

                        if misses >= 3 {
                            self.logger.warning("Tap for PID \(pid) unresponsive (\(misses) misses), recreating")
                            consecutiveMisses[pid] = 0
                            await self.recreateTap(for: pid)
                        }
                    }
                }

                // Prune entries for PIDs no longer tracked
                consecutiveMisses = consecutiveMisses.filter { self.taps[$0.key] != nil }
                self.tapRecoveryCooldownUntil = self.tapRecoveryCooldownUntil.filter { self.taps[$0.key] != nil }
            }
        }
    }

    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    /// Tears down and recreates a tap for a given PID, preserving routing and settings.
    /// Async: awaits full CoreAudio resource teardown before creating the replacement tap
    /// to prevent orphaned IO procs from accumulating (issue #176).
    private func recreateTap(for pid: pid_t) async {
        guard let oldTap = taps.removeValue(forKey: pid) else { return }
        let deviceUIDs = oldTap.currentDeviceUIDs
        await oldTap.invalidateAsync()

        // Set cooldown to prevent thrashing
        tapRecoveryCooldownUntil[pid] = Date().addingTimeInterval(20)

        // Find the current AudioApp entry for this PID
        guard let app = apps.first(where: { $0.id == pid }) else {
            logger.debug("No active app for PID \(pid), skipping tap recreation")
            appliedPIDs.remove(pid)
            return
        }

        // Allow re-initialization
        appliedPIDs.remove(pid)

        // Re-route to the same device(s), preserving multi-device routing
        if deviceUIDs.count > 1 {
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
            if taps[app.id] != nil {
                appDeviceRouting[app.id] = deviceUIDs[0]
            }
        } else if let deviceUID = deviceUIDs.first {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }

        // Mark as applied to avoid redundant re-processing in applyPersistedSettings
        if taps[pid] != nil {
            appliedPIDs.insert(pid)
        }

        // Restore mute state
        if let muted = volumeState.loadSavedMute(for: pid, identifier: app.persistenceIdentifier), muted {
            taps[pid]?.isMuted = true
        }
    }

    /// Recreates the aggregate at the device's new rate for every tap on a BT output that changed
    /// sample rate (A2DP↔SCO), so each tap's IOProc re-rates to match. Falls back to a full tap
    /// recreate if the in-controller recreation throws.
    private func handleBTDeviceSampleRateChanged(uid: String, newRate: Double) async {
        logger.info("[RATE] BT output \(uid, privacy: .public) → \(newRate, format: .fixed(precision: 0)) Hz — recreating affected taps (clean dip)")
        let affected = taps.filter { $0.value.currentDeviceUIDs.contains(uid) }
        for (pid, tap) in affected {
            do {
                logger.info("[RATE] Recreating tap for PID \(pid)")
                let transition = tap.currentDeviceUID.map {
                    deviceAUTransition(on: tap, to: $0)
                }
                try await tap.recreateForOutputRateChange(deviceAUTransition: transition)
                applyDeviceAUChainToTap(tap)
            } catch {
                logger.error("[RATE] Recreate failed for PID \(pid): \(error.localizedDescription) — falling back to full recreate")
                await recreateTap(for: pid)
            }
        }
    }

    // MARK: - Input Device Lock

    /// Handles changes to the default input device.
    /// Uses state machine to distinguish auto-switch (from device connection) vs user action.
    private func handleDefaultInputDeviceChanged(_ newDefaultInputUID: String) {
        // State machine: if we're waiting for macOS to auto-switch after input device connect,
        // check whether this change is the expected auto-switch or user intent.
        if case .pendingAutoSwitch(let pendingUID, let timeoutTask) = inputPriorityState {
            if newDefaultInputUID == pendingUID, settingsManager.appSettings.lockInputDevice {
                // Case 1: macOS auto-switched to the newly connected device — restore locked device.
                // Re-enter PENDING_AUTOSWITCH because macOS may auto-switch multiple times.
                timeoutTask.cancel()
                restoreLockedInputDevice()
                let transport = deviceMonitor.inputDevice(for: pendingUID)?.id.readTransportType()
                let timeout = (transport == .bluetooth || transport == .bluetoothLE)
                    ? btAutoSwitchGracePeriod
                    : autoSwitchGracePeriod
                let newTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, !Task.isCancelled else { return }
                    self.inputPriorityState = .stable
                    self.logger.debug("Input auto-switch grace period expired after override")
                }
                inputPriorityState = .pendingAutoSwitch(
                    connectedDeviceUID: pendingUID,
                    timeoutTask: newTimeoutTask
                )
                return
            }
            // Case 2: Our own echo from the override. Consume without disrupting state machine.
            if inputEchoTracker.consume(newDefaultInputUID) {
                return
            }
            // Case 3: Genuine user intent — respect it.
            timeoutTask.cancel()
            inputPriorityState = .stable
        }

        // Suppress echo from our own input device override (when not in pendingAutoSwitch)
        if inputEchoTracker.consume(newDefaultInputUID) {
            return
        }

        // If any input echo counter is pending, skip routing
        if inputEchoTracker.hasPending {
            logger.debug("Skipping input routing — echo pending")
            return
        }

        // If lock is disabled, let system control input freely
        guard settingsManager.appSettings.lockInputDevice else { return }

        // Restore the locked device — any change outside FineTune's UI is either
        // macOS auto-switch or System Settings, and the lock should hold either way.
        // Users change the lock via FineTune's UI (setLockedInputDevice).
        guard let lockedUID = settingsManager.lockedInputDeviceUID else { return }
        if newDefaultInputUID != lockedUID {
            restoreLockedInputDevice()
        }
    }

    /// Restores the locked input device, or falls back to built-in mic if unavailable.
    private func restoreLockedInputDevice() {
        guard let lockedUID = settingsManager.lockedInputDeviceUID,
              let lockedDevice = deviceMonitor.inputDevice(for: lockedUID) else {
            // No locked device or it's unavailable - fall back to built-in
            lockToBuiltInMicrophone()
            return
        }

        // Don't restore if already on the locked device
        guard deviceVolumeMonitor.defaultInputDeviceUID != lockedUID else { return }

        logger.info("Restoring locked input device: \(lockedDevice.name)")
        if deviceVolumeMonitor.setDefaultInputDevice(lockedDevice.id) {
            inputEchoTracker.increment(lockedDevice.uid)
        }
    }

    /// Locks the input device to the built-in microphone.
    /// This is a fallback — does NOT update preferredInputDeviceUID.
    private func lockToBuiltInMicrophone() {
        guard let builtInMic = deviceMonitor.inputDevices.first(where: {
            $0.id.readTransportType() == .builtIn
        }) else {
            logger.warning("No built-in microphone found")
            return
        }

        applyInputDeviceLock(builtInMic)
    }

    /// Applies input device lock without changing the user's preferred device.
    /// Used for fallback scenarios (disconnect, built-in mic recovery).
    private func applyInputDeviceLock(_ device: AudioDevice) {
        logger.info("Locking input device to: \(device.name)")
        settingsManager.setLockedInputDeviceUID(device.uid)
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when the user toggles lockInputDevice ON in settings.
    /// Captures the current default input device as the locked and preferred device.
    func handleInputLockEnabled() {
        guard let currentUID = deviceVolumeMonitor.defaultInputDeviceUID,
              let device = deviceMonitor.inputDevice(for: currentUID) else {
            return
        }
        logger.info("Input lock enabled, locking to current default: \(device.name)")
        settingsManager.setLockedInputDeviceUID(device.uid)
        settingsManager.setPreferredInputDeviceUID(device.uid)
    }

    /// Called when user explicitly selects an input device (via FineTune UI).
    /// Persists the choice and applies the change.
    func setLockedInputDevice(_ device: AudioDevice) {
        logger.info("User locked input device to: \(device.name)")

        // Persist the choice — both current lock and preferred (user intent)
        settingsManager.setLockedInputDeviceUID(device.uid)
        settingsManager.setPreferredInputDeviceUID(device.uid)

        // Apply the change
        if deviceVolumeMonitor.setDefaultInputDevice(device.id) {
            inputEchoTracker.increment(device.uid)
        }
    }

    /// Called when an input device connects — restores locked/preferred device and guards against auto-switch.
    private func handleInputDeviceConnected(_ deviceUID: String, name deviceName: String) {
        guard settingsManager.appSettings.lockInputDevice else { return }

        // If the reconnected device is the user's preferred device, restore the lock to it
        if let preferredUID = settingsManager.preferredInputDeviceUID,
           deviceUID == preferredUID,
           settingsManager.lockedInputDeviceUID != preferredUID,
           let device = deviceMonitor.inputDevice(for: deviceUID) {
            logger.info("Preferred input device reconnected: \(deviceName), restoring lock")
            settingsManager.setLockedInputDeviceUID(device.uid)
        }

        // Restore the user's locked device (not priority-based — lock overrides priority)
        restoreLockedInputDevice()

        // Cancel any existing PENDING_AUTOSWITCH before entering a new one
        if case .pendingAutoSwitch(_, let oldTask) = inputPriorityState {
            oldTask.cancel()
        }

        // Always enter PENDING_AUTOSWITCH — macOS may auto-switch to the newly connected
        // device multiple times during BT handshake, even if we just restored the lock.
        let transport = deviceMonitor.inputDevice(for: deviceUID)?.id.readTransportType()
        let timeout = (transport == .bluetooth || transport == .bluetoothLE)
            ? btAutoSwitchGracePeriod
            : autoSwitchGracePeriod

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.inputPriorityState = .stable
            self.logger.debug("Input auto-switch grace period expired, no macOS switch detected")
        }

        inputPriorityState = .pendingAutoSwitch(
            connectedDeviceUID: deviceUID,
            timeoutTask: timeoutTask
        )
    }

    /// Handles input device disconnect — uses priority fallback, then built-in mic.
    private func handleInputDeviceDisconnected(_ deviceUID: String) {
        // If we were waiting for macOS to auto-switch to this device, cancel — it's gone
        if case .pendingAutoSwitch(let uid, let task) = inputPriorityState, uid == deviceUID {
            task.cancel()
            inputPriorityState = .stable
        }

        // Snapshot before async callbacks can update it
        let wasDefaultInput = deviceUID == deviceVolumeMonitor.defaultInputDeviceUID

        let priorityFallback = Self.resolveHighestPriority(
            priorityOrder: settingsManager.inputDevicePriorityOrder,
            connectedDevices: inputDevices,
            excluding: deviceUID,
            isAlive: isAliveCheck
        )

        // If the disconnected device was the default input, override to priority fallback
        if wasDefaultInput {
            reEvaluateInputDefault(excluding: deviceUID)
        }

        // If the locked device disconnected, update the lock to the fallback (or built-in mic)
        guard settingsManager.appSettings.lockInputDevice,
              settingsManager.lockedInputDeviceUID == deviceUID else { return }

        if let fallbackDevice = priorityFallback {
            logger.info("Locked input device disconnected, falling back to priority: \(fallbackDevice.name)")
            if wasDefaultInput {
                // Default already switched above, just update the lock setting
                settingsManager.setLockedInputDeviceUID(fallbackDevice.uid)
            } else {
                applyInputDeviceLock(fallbackDevice)
            }
        } else {
            logger.info("Locked input device disconnected, falling back to built-in mic")
            lockToBuiltInMicrophone()
        }
    }
}

// MARK: - URLHandlerEngine Conformance

extension AudioEngine: URLHandlerEngine {}
