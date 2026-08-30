// FineTuneTests/AudioEngineTapInitialStateTests.swift
//
// Verifies AudioEngine derives TapInitialState from persisted settings and
// hands it to activate(initial:) before any post-activation mutation.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

// MARK: - Recording Mock

/// Records every method invocation against `ProcessTapControlling` in order.
/// Tests assert on `events` to verify the engine's apply-initial-state contract.
@MainActor
final class RecordingProcessTapController: ProcessTapControlling {
    enum Event: Equatable {
        case activate(TapInitialStateSnapshot)
        case updateEQSettings(EQSettings)
        case updateAutoEQProfile(profileID: String?)
        case setAutoEQPreampEnabled(Bool)
        case updateLoudnessCompensation(volume: Float, enabled: Bool)
        case updateLoudnessEqualization(LoudnessEqualizerSettings)
        case invalidate
        case invalidateForHandoff
    }

    /// Plain snapshot of `TapInitialState` so test asserts don't depend on
    /// the source-type's identity (defensive against future mutations).
    struct TapInitialStateSnapshot: Equatable {
        var eqSettings: EQSettings
        var autoEQProfileID: String?
        var autoEQPreampEnabled: Bool
        var loudnessVolume: Float
        var loudnessCompensationEnabled: Bool
        var loudnessEqualizerSettings: LoudnessEqualizerSettings

        @MainActor
        init(_ s: TapInitialState) {
            self.eqSettings = s.eqSettings
            self.autoEQProfileID = s.autoEQProfile?.id
            self.autoEQPreampEnabled = s.autoEQPreampEnabled
            self.loudnessVolume = s.loudnessVolume
            self.loudnessCompensationEnabled = s.loudnessCompensationEnabled
            self.loudnessEqualizerSettings = s.loudnessEqualizerSettings
        }
    }

    let app: AudioApp
    private(set) var events: [Event] = []

    // Mutable surface — recorded as plain property writes (not events).
    var volume: Float = 1.0
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted: Bool = false
    var audioLevel: Float = 0.0
    private(set) var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String? = nil
    private(set) var attachedAppAUChain: AUEffectChain?
    private(set) var attachedAppAUEntries: [AUEffectChainEntry] = []

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func activate(initial: TapInitialState) throws {
        events.append(.activate(TapInitialStateSnapshot(initial)))
    }

    func invalidate() {
        events.append(.invalidate)
    }

    func invalidateForHandoff() {
        events.append(.invalidateForHandoff)
    }

    func updateEQSettings(_ settings: EQSettings) {
        events.append(.updateEQSettings(settings))
    }

    func updateAutoEQProfile(_ profile: AutoEQProfile?) {
        events.append(.updateAutoEQProfile(profileID: profile?.id))
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        events.append(.setAutoEQPreampEnabled(enabled))
    }

    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        events.append(.updateLoudnessCompensation(volume: volume, enabled: enabled))
    }

    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {
        events.append(.updateLoudnessEqualization(settings))
    }

    func attachPersistentAUEffectChain(_ chain: AUEffectChain?, entries: [AUEffectChainEntry]) {
        attachedAppAUChain = chain
        attachedAppAUEntries = entries
    }

    func switchDevice(
        to newDeviceUID: String,
        preferredTapSourceDeviceUID: String?,
        sourceDeviceDead: Bool,
        deviceAUTransition: DeviceAUEffectTransition?
    ) async throws {
        currentDeviceUIDs = [newDeviceUID]
    }

    func updateDevices(
        to newDeviceUIDs: [String],
        preferredTapSourceDeviceUID: String?,
        sourceDeviceDead: Bool,
        deviceAUTransition: DeviceAUEffectTransition?
    ) async throws {
        currentDeviceUIDs = newDeviceUIDs
    }

    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }

    func refreshTapSource(
        _ preferredDeviceUID: String?,
        deviceAUTransition: DeviceAUEffectTransition?
    ) async throws {}
}

// MARK: - Process monitor stub

@MainActor
final class StubProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?
    func start() {}
    func stop() {}
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let deviceMonitor: MockAudioDeviceMonitor
    let deviceVolume: MockDeviceVolumeProviding
    let app: AudioApp
    let device: AudioDevice
    let lastTap: () -> RecordingProcessTapController?
}

@MainActor
private func makeFixture(
    supportsAutoEQ: Bool = true,
    deviceVolume: Float = 0.75
) -> Fixture {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)

    let deviceMonitor = MockAudioDeviceMonitor()
    let device = AudioDevice(
        id: AudioDeviceID(99),
        uid: "uid-test",
        name: "Test Output",
        icon: nil,
        supportsAutoEQ: supportsAutoEQ
    )
    deviceMonitor.addOutputDevice(device)

    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    mockVolume.volumes[device.id] = deviceVolume

    let app = AudioApp(
        id: 12345,
        processObjectIDs: [],
        name: "TestApp",
        icon: NSImage(),
        bundleID: "com.test.tapinitial"
    )

    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = [app]

    // Capture every tap the factory hands out so tests can read the captured
    // event log. Mutable box lets the closure write into the test scope.
    let box = TapBox()

    // ensureTapExists guards on permission.status == .authorized. The TCC SPI
    // preflight returns -1 (unknown) under xctest, so we force it to authorized
    // via the internal(set) status property exposed by @testable import.
    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(
            loadPersistedProfiles: false,
            loadCatalog: false
        ),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: mockVolume,
        tapFactory: { app, uids, _ in
            let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
            box.last = tap
            return tap
        },
        startMonitorsAutomatically: false
    )

    return Fixture(
        engine: engine,
        settings: settings,
        deviceMonitor: deviceMonitor,
        deviceVolume: mockVolume,
        app: app,
        device: device,
        lastTap: { box.last }
    )
}

@MainActor
private final class TapBox {
    var last: RecordingProcessTapController?
}

// MARK: - Suite

@Suite("AudioEngine.tapInitialState — first-sound fix (PR-1)")
@MainActor
struct AudioEngineTapInitialStateTests {

    @Test("A relaunch retires the old producer before reusing the persistent AU instances")
    func sameAppRelaunchHandsOffPersistentAUInstances() throws {
        let fix = makeFixture()
        let descriptor = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79, // 'dely'
            componentManufacturer: 0x6170706C, // 'appl'
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
        let entry = AUEffectChainEntry(plugin: descriptor)
        fix.settings.setAUEffectChain([entry], for: fix.app.persistenceIdentifier)
        fix.engine.pinApp(fix.app)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let firstTap = try #require(fix.lastTap())
        let firstChain = try #require(firstTap.attachedAppAUChain)
        let firstHost = try #require(firstChain.host(for: entry.id))
        let firstAudioUnit = try #require(firstHost.audioUnit)

        let relaunchedApp = AudioApp(
            id: fix.app.id + 1,
            processObjectIDs: [101, 102],
            name: fix.app.name,
            icon: NSImage(),
            bundleID: fix.app.bundleID
        )
        fix.engine.setDevice(for: relaunchedApp, deviceUID: fix.device.uid)
        let relaunchedTap = try #require(fix.lastTap())

        #expect(relaunchedTap !== firstTap)
        #expect(firstTap.events.last == .invalidateForHandoff)
        #expect(!firstTap.events.contains(.invalidate))
        #expect(relaunchedTap.attachedAppAUChain === firstChain)
        #expect(relaunchedTap.attachedAppAUChain?.host(for: entry.id) === firstHost)
        #expect(relaunchedTap.attachedAppAUChain?.host(for: entry.id)?.audioUnit == firstAudioUnit)
        #expect(relaunchedTap.attachedAppAUEntries.map(\.id) == [entry.id])
    }

    @Test("Process exit synchronously retires HAL resources without ordinary invalidation")
    func processExitUsesSynchronousTapTeardown() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        fix.engine.prepareForProcessExit()

        #expect(tap.events.contains(.invalidateForHandoff))
        #expect(!tap.events.contains(.invalidate))
    }

    @Test("Pending asynchronous HAL teardown can be drained before process exit")
    func pendingTapResourceDestructionIsDrainable() {
        let destructionQueue = DispatchQueue(label: "TapResourcesTests.suspended-destruction")
        destructionQueue.suspend()
        var resources = TapResources()
        resources.destroyAsync(on: destructionQueue)

        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            TapResources.waitForPendingDestruction()
            completed.signal()
        }
        let resultBeforeResume = completed.wait(timeout: .now() + .milliseconds(50))
        destructionQueue.resume()

        #expect(resultBeforeResume == .timedOut)
        #expect(completed.wait(timeout: .now() + .seconds(2)) == .success)
    }

    @Test("Paired async teardown registers primary before secondary completion can expose zero pending work")
    func pairedTapResourceDestructionHasNoSubmissionGap() {
        let destructionQueue = DispatchQueue(label: "TapResourcesTests.suspended-pair")
        destructionQueue.suspend()
        var secondary = TapResources()
        var primary = TapResources()
        let pairCompleted = DispatchSemaphore(value: 0)
        TapResources.destroyPairAsync(
            &secondary,
            &primary,
            on: destructionQueue
        ) {
            pairCompleted.signal()
        }

        let globalDrainCompleted = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            TapResources.waitForPendingDestruction()
            globalDrainCompleted.signal()
        }
        let resultBeforeResume = globalDrainCompleted.wait(timeout: .now() + .milliseconds(50))
        destructionQueue.resume()

        #expect(resultBeforeResume == .timedOut)
        #expect(pairCompleted.wait(timeout: .now() + .seconds(2)) == .success)
        #expect(globalDrainCompleted.wait(timeout: .now() + .seconds(2)) == .success)
    }

    @Test("Device AU edits preserve persisted chains before any tap is active")
    func inactiveDeviceAUEditUsesPersistedState() {
        let fix = makeFixture()
        let original = AUEffectChainEntry(plugin: AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6465_6C79,
            componentManufacturer: 0x6170_706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        ))
        let addedPlugin = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C70_6173,
            componentManufacturer: 0x6170_706C,
            name: "AULowpass",
            manufacturer: "Apple",
            version: 1
        )
        fix.settings.setDeviceAUEffectChain([original], for: fix.device.uid)

        fix.engine.addDeviceAUEffect(deviceUID: fix.device.uid, plugin: addedPlugin)

        let loaded = fix.settings.getDeviceAUEffectChain(for: fix.device.uid)
        #expect(loaded.count == 2)
        #expect(loaded.first?.id == original.id)
        #expect(loaded.last?.pluginDescriptor == addedPlugin)
        #expect(fix.engine.getDeviceAUEffectChain(deviceUID: fix.device.uid) == loaded)
        #expect(fix.lastTap() === nil)
    }

    @Test("Process monitor coalesces concurrent PIDs into one logical CATap input")
    func coalescesConcurrentPIDsByPersistenceIdentifier() throws {
        let first = AudioApp(
            id: 100,
            processObjectIDs: [11, 12],
            name: "Browser",
            icon: NSImage(),
            bundleID: "com.test.browser"
        )
        let second = AudioApp(
            id: 200,
            processObjectIDs: [21],
            name: "Browser",
            icon: NSImage(),
            bundleID: "com.test.browser"
        )

        let merged = AudioProcessMonitor.coalesceLogicalApps([second, first])
        let app = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(app.id == 100)
        #expect(app.processObjectIDs == [11, 12, 21])
    }

    @Test("Changing output priority reorders an existing multi-output tap")
    func priorityChangeReordersMultiOutputTap() async throws {
        let fix = makeFixture()
        let second = AudioDevice(
            id: AudioDeviceID(100),
            uid: "uid-second",
            name: "Second Output",
            icon: nil,
            supportsAutoEQ: false
        )
        fix.deviceMonitor.addOutputDevice(second)
        fix.settings.setDevicePriorityOrder([fix.device.uid, second.uid])
        fix.engine.volumeState.setDeviceSelectionMode(
            for: fix.app.id,
            to: .multi,
            identifier: fix.app.persistenceIdentifier
        )
        fix.engine.volumeState.setSelectedDeviceUIDs(
            for: fix.app.id,
            to: [fix.device.uid, second.uid],
            identifier: fix.app.persistenceIdentifier
        )

        fix.engine.reconcileMultiOutputPriority()
        for _ in 0..<20 where fix.lastTap() == nil { await Task.yield() }
        let tap = try #require(fix.lastTap())
        #expect(tap.currentDeviceUIDs == [fix.device.uid, second.uid])

        fix.settings.setDevicePriorityOrder([second.uid, fix.device.uid])
        fix.engine.reconcileMultiOutputPriority()
        for _ in 0..<20 where tap.currentDeviceUIDs.first != second.uid { await Task.yield() }

        #expect(tap.currentDeviceUIDs == [second.uid, fix.device.uid])
        #expect(fix.engine.getDeviceUID(for: fix.app) == second.uid)
    }

    @Test("Pinned inactive multi-output Primary previews its next activation order")
    func inactivePrimaryUsesMultiOutputPriority() {
        let fix = makeFixture()
        let second = AudioDevice(
            id: AudioDeviceID(100),
            uid: "uid-second",
            name: "Second Output",
            icon: nil,
            supportsAutoEQ: false
        )
        fix.deviceMonitor.addOutputDevice(second)
        let identifier = fix.app.persistenceIdentifier
        fix.engine.setDeviceRoutingForInactive(identifier: identifier, deviceUID: fix.device.uid)
        fix.engine.setDeviceSelectionModeForInactive(identifier: identifier, to: .multi)
        fix.engine.setSelectedDeviceUIDsForInactive(
            identifier: identifier,
            to: [fix.device.uid, second.uid]
        )

        fix.settings.setDevicePriorityOrder([second.uid, fix.device.uid])

        #expect(fix.engine.getPrimaryDeviceUIDForInactive(identifier: identifier) == second.uid)
        #expect(fix.engine.getDeviceRoutingForInactive(identifier: identifier) == fix.device.uid)
    }

    @Test("Ignoring a pinned inactive app cannot resurrect its live AU state")
    func inactiveIgnoreRemovesPersistentStripBeforeSave() {
        let fix = makeFixture()
        let entry = AUEffectChainEntry(
            plugin: AUPluginDescriptor(
                componentType: kAudioUnitType_Effect,
                componentSubType: 0x6465_6C79,
                componentManufacturer: 0x6170_706C,
                name: "AUDelay",
                manufacturer: "Apple",
                version: 1
            )
        )
        fix.settings.setAUEffectChain([entry], for: fix.app.persistenceIdentifier)
        fix.engine.pinApp(fix.app)

        fix.engine.ignoreApp(
            identifier: fix.app.persistenceIdentifier,
            displayName: fix.app.name,
            bundleID: fix.app.bundleID
        )
        fix.engine.saveAllLiveAUState()

        #expect(fix.settings.isIgnored(fix.app.persistenceIdentifier))
        #expect(fix.settings.getAUEffectChain(for: fix.app.persistenceIdentifier).isEmpty)
        #expect(fix.engine.getAUEffectChain(forIdentifier: fix.app.persistenceIdentifier).isEmpty)
    }

    @Test("App AU commits normalize duplicate Console 1 entries in the live strip")
    func liveAppAUCommitUsesNormalizedConsoleChain() {
        let fix = makeFixture()
        let consoleDescriptor = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x5363_5069,
            componentManufacturer: 0x5366_5462,
            name: "Console 1",
            manufacturer: "Softube",
            version: 1
        )
        var firstConsole = AUEffectChainEntry(plugin: consoleDescriptor)
        firstConsole.isEnabled = false
        firstConsole.isCrashQuarantined = true
        let generic = AUEffectChainEntry(plugin: AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6465_6C79,
            componentManufacturer: 0x6170_706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        ))
        var duplicateConsole = AUEffectChainEntry(plugin: consoleDescriptor)
        duplicateConsole.isEnabled = false
        duplicateConsole.isCrashQuarantined = true

        fix.engine.reorderAUEffects(
            for: fix.app,
            entries: [firstConsole, generic, duplicateConsole]
        )

        let expectedIDs = [firstConsole.id, generic.id]
        #expect(fix.engine.getAUEffectChain(for: fix.app).map(\.id) == expectedIDs)
        #expect(fix.settings.getAUEffectChain(for: fix.app.persistenceIdentifier).map(\.id) == expectedIDs)
    }

    @Test("Ignore clears live audio state so unignore starts from defaults")
    func ignoreClearsVolumeStateForLogicalApp() {
        let fix = makeFixture()
        let identifier = fix.app.persistenceIdentifier

        fix.engine.volumeState.setVolume(for: fix.app.id, to: 0.2, identifier: identifier)
        fix.engine.volumeState.setBoost(for: fix.app.id, to: .x4, identifier: identifier)
        fix.engine.volumeState.setMute(for: fix.app.id, to: true, identifier: identifier)
        fix.engine.volumeState.setDeviceSelectionMode(for: fix.app.id, to: .multi, identifier: identifier)
        fix.engine.volumeState.setSelectedDeviceUIDs(
            for: fix.app.id,
            to: [fix.device.uid],
            identifier: identifier
        )

        fix.engine.ignoreApp(
            identifier: identifier,
            displayName: fix.app.name,
            bundleID: fix.app.bundleID
        )
        fix.engine.unignoreApp(identifier)

        #expect(fix.engine.getVolume(for: fix.app) == fix.settings.appSettings.defaultNewAppVolume)
        #expect(fix.engine.getBoost(for: fix.app) == .x1)
        #expect(!fix.engine.getMute(for: fix.app))
        #expect(fix.engine.getDeviceSelectionMode(for: fix.app) == .single)
        #expect(fix.engine.getSelectedDeviceUIDs(for: fix.app).isEmpty)
    }

    @Test("Selecting Default discards unsaved edits from an editor that is still open")
    func unsavedLiveEditThenDefaultRestoresBaseline() throws {
        let fix = makeFixture()
        let descriptor = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C70_6173,
            componentManufacturer: 0x6170_706C,
            name: "AULowPassFilter",
            manufacturer: "Apple",
            version: 1
        )
        let entry = AUEffectChainEntry(plugin: descriptor)
        fix.settings.setAUEffectChain([entry], for: fix.app.persistenceIdentifier)
        fix.engine.pinApp(fix.app)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let chain = try #require(tap.attachedAppAUChain)
        let host = try #require(chain.host(for: entry.id))
        let au = try #require(host.audioUnit)
        var baseline: AudioUnitParameterValue = 0
        #expect(AudioUnitGetParameter(au, 0, kAudioUnitScope_Global, 0, &baseline) == noErr)
        #expect(AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, 200, 0) == noErr)

        fix.engine.selectAUFactoryPreset(
            forIdentifier: fix.app.persistenceIdentifier,
            displayName: fix.app.name,
            entryID: entry.id,
            presetIndex: -1
        )

        let rebuiltChain = try #require(tap.attachedAppAUChain)
        var restored: AudioUnitParameterValue = 0
        #expect(AudioUnitGetParameter(au, 0, kAudioUnitScope_Global, 0, &restored) == noErr)
        #expect(rebuiltChain.host(for: entry.id) === host)
        #expect(rebuiltChain.host(for: entry.id)?.audioUnit == au)
        #expect(abs(restored - baseline) < 0.001)
    }

    // MARK: Single-knob derivation

    @Test("EQ settings persisted for this app land in TapInitialState.eqSettings")
    func eqSettingsAreCarried() throws {
        let fix = makeFixture()
        let custom = EQSettings(bandGains: [3, 0, -2, 0, 0, 0, 0, 0, 0, 4], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.eqSettings == custom)
    }

    @Test("An app without EQ settings starts with the built-in EQ disabled")
    func defaultEQIsDisabled() throws {
        let fix = makeFixture()

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.eqSettings == .disabledFlat)
        #expect(!snap.eqSettings.isEnabled)
    }

    @Test("autoEQPreampEnabled mirrors settingsManager.autoEQPreampEnabled",
          arguments: [true, false])
    func autoEQPreampEnabledMirrored(value: Bool) throws {
        let fix = makeFixture()
        fix.settings.autoEQPreampEnabled = value

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQPreampEnabled == value)
    }

    @Test("loudnessCompensationEnabled mirrors appSettings.loudnessCompensationEnabled",
          arguments: [true, false])
    func loudnessCompensationFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessCompensationEnabled == value)
    }

    @Test("loudnessEqualizerSettings.enabled mirrors appSettings.loudnessEqualizationEnabled",
          arguments: [true, false])
    func loudnessEqualizerFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessEqualizationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessEqualizerSettings.enabled == value)
    }

    @Test("loudnessVolume = currentDeviceVolume × per-app volume")
    func loudnessVolumeIsProduct() throws {
        let fix = makeFixture(deviceVolume: 0.5)
        fix.engine.volumeState.setVolume(for: fix.app.id, to: 0.4, identifier: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        // applyTapOutputState() runs before tapInitialState() is built, so
        // currentDeviceVolume is 0.5 (from MockDeviceVolumeProviding.volumes).
        // loudnessVolume should be deviceVolume (0.5) × appVolume (0.4) = 0.2.
        #expect(abs(snap.loudnessVolume - 0.2) < 1e-6)
    }

    // MARK: AutoEQ profile resolution

    @Test("autoEQProfile is nil when the device does not support AutoEQ")
    func autoEQNilForUnsupportedDevice() throws {
        let fix = makeFixture(supportsAutoEQ: false)
        // Even if a selection exists, an unsupported device must skip AutoEQ.
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when no selection is persisted for the device")
    func autoEQNilWithNoSelection() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        // Don't set any selection.

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when the selection is disabled")
    func autoEQNilWhenSelectionDisabled() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: false)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when selection is enabled but profile is not in the cache")
    func autoEQNilWhenProfileNotCached() throws {
        // Default AutoEQProfileManager has no profiles cached for "missing-id".
        // The pre-activate synchronous lookup must return nil so that
        // ensureTapExists falls through to the async resolve branch.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    // MARK: Ordering / post-activation behaviour

    @Test("activate(initial:) is the first event the controller observes")
    func activateIsFirstEvent() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let firstEvent = try #require(tap.events.first)
        if case .activate = firstEvent {
            // ok
        } else {
            Issue.record("First event was \(firstEvent), expected .activate")
        }
    }

    @Test("No EQ/AutoEQ/Loudness mutation runs BEFORE activate(initial:) — the apply-initial-state contract")
    func noMutationBeforeActivate() throws {
        // The core PR-1 invariant: every processor-state knob the audio thread
        // can observe must be set via TapInitialState, not via post-construction
        // calls that race with AudioDeviceStart. We assert this by checking
        // that no .updateEQSettings / .updateAutoEQProfile / .setAutoEQPreampEnabled
        // / .updateLoudnessCompensation / .updateLoudnessEqualization is recorded
        // BEFORE the .activate event in the tap's event log.
        //
        // Exercises a realistic config (AutoEQ-capable device with an enabled
        // selection whose profile is uncached) so applyAutoEQToTap runs
        // post-activate — proving the engine's fallback path doesn't accidentally
        // fire before activate.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )
        let custom = EQSettings(bandGains: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = true
        s.loudnessEqualizationEnabled = true
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let activateIndex = try #require(tap.events.firstIndex { event in
            if case .activate = event { return true }
            return false
        })

        for event in tap.events.prefix(activateIndex) {
            switch event {
            case .updateEQSettings, .updateAutoEQProfile, .setAutoEQPreampEnabled,
                 .updateLoudnessCompensation, .updateLoudnessEqualization:
                Issue.record("Pre-activate mutation breaks the apply-initial-state contract: \(event)")
            case .activate, .invalidate, .invalidateForHandoff:
                break
            }
        }
    }

    @Test("Cache-miss AutoEQ: applyAutoEQToTap fires its sync nil-set after activate")
    func cacheMissTriggersPostActivateNilSet() throws {
        // Device supports AutoEQ + selection is enabled but profile is missing
        // from cache → ensureTapExists calls applyAutoEQToTap, which sets the
        // profile to nil synchronously before kicking off async resolution.
        // Verifies the engine's fallback path is reached when (and only when)
        // the synchronous pre-activate lookup misses.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        // The first event must still be .activate (apply-initial-state ordering)
        if case .activate = tap.events.first {
            // ok
        } else {
            Issue.record("activate(initial:) was not first event")
        }
        // A post-activate updateAutoEQProfile(nil) must be present from
        // applyAutoEQToTap's sync nil-set on cache miss.
        let postActivateAutoEQ = tap.events.dropFirst().compactMap { event -> String?? in
            if case let .updateAutoEQProfile(id) = event { return Optional(id) }
            return nil
        }
        #expect(postActivateAutoEQ.contains(where: { $0 == nil }))
    }
}

// MARK: - Helpers

@MainActor
private func capturedInitial(_ fix: Fixture) -> RecordingProcessTapController.TapInitialStateSnapshot? {
    guard let tap = fix.lastTap() else { return nil }
    for event in tap.events {
        if case let .activate(snapshot) = event { return snapshot }
    }
    return nil
}

// MARK: - Mock contract

@Suite("RecordingProcessTapController — protocol contract")
@MainActor
struct RecordingProcessTapControllerContractTests {
    @Test("Mock records activate, then mutation events, in invocation order")
    func recordsCallOrder() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        try tap.activate(initial: TapInitialState())
        tap.updateEQSettings(EQSettings.flat)
        tap.updateAutoEQProfile(nil)

        #expect(tap.events.count == 3)
        if case .activate = tap.events[0] {} else { Issue.record("expected .activate at 0") }
        if case .updateEQSettings = tap.events[1] {} else { Issue.record("expected .updateEQSettings at 1") }
        if case .updateAutoEQProfile = tap.events[2] {} else { Issue.record("expected .updateAutoEQProfile at 2") }
    }

    @Test("Default property values match real controller defaults")
    func defaultsMatchProductionController() {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        // ProcessTapController's nonisolated(unsafe) defaults from source.
        #expect(tap.volume == 1.0)
        #expect(tap.isMuted == false)
        #expect(tap.currentDeviceVolume == 1.0)
        #expect(tap.isDeviceMuted == false)
        #expect(tap.audioLevel == 0.0)
        #expect(tap.tapSourceDeviceUID == nil)
        #expect(tap.currentDeviceUID == "uid")
    }

    @Test("Backward-compatible activate() convenience routes through activate(initial:)")
    func convenienceActivateRoutesThroughInitial() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        // Convenience extension on the protocol: should funnel through activate(initial:)
        // with a default TapInitialState — proves no caller can sneak around the
        // initial-state contract by calling the old no-arg overload.
        try tap.activate()
        if case let .activate(snap) = tap.events.first {
            #expect(snap.autoEQProfileID == nil)
            #expect(snap.loudnessCompensationEnabled == false)
            #expect(snap.loudnessEqualizerSettings.enabled == false)
            #expect(snap.autoEQPreampEnabled == false)
            #expect(snap.eqSettings == EQSettings.disabledFlat)
            #expect(snap.loudnessVolume == 1.0)
        } else {
            Issue.record("activate() did not record an .activate event")
        }
    }
}
