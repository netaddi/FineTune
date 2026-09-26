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
    enum StubError: Error { case deviceUpdateFailed, factoryFailed }
    enum StartupEvent: Equatable {
        case attachAppAU
        case attachDeviceAU
        case activate
    }

    enum Event: Equatable {
        case activate(TapInitialStateSnapshot)
        case updateEQSettings(EQSettings)
        case updateAutoEQProfile(profileID: String?)
        case setAutoEQPreampEnabled(Bool)
        case updateLoudnessCompensation(volume: Float, enabled: Bool)
        case updateLoudnessEqualization(LoudnessEqualizerSettings)
        case rebind(pid_t, [AudioObjectID])
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

    private(set) var app: AudioApp
    let restoresProcessByBundleID: Bool
    let configuredRestorationBundleIDs: Set<String>
    private(set) var events: [Event] = []
    private(set) var startupEvents: [StartupEvent] = []
    var pauseNextDeviceUpdate = false
    var failNextDeviceUpdate = false
    var failNextDeviceSwitch = false
    private var deviceUpdateContinuation: CheckedContinuation<Void, Never>?
    var pauseNextDeviceSwitch = false
    private var deviceSwitchContinuation: CheckedContinuation<Void, Never>?
    var hasPendingDeviceUpdate: Bool { deviceUpdateContinuation != nil }
    var hasPendingDeviceSwitch: Bool { deviceSwitchContinuation != nil }
    var serviceRetirementCount = 0
    var serviceRestartCallbacksDrained = true
    var hasValidAudioResources = true
    var isAudioResourceTransitionInProgress = false
    var healthEligible = false
    var recentCallback = false
    var pauseInvalidation = false
    private var invalidationContinuation: CheckedContinuation<Void, Never>?
    var hasPendingInvalidation: Bool { invalidationContinuation != nil }
    func invalidateAsync() async {
        if pauseInvalidation {
            await withCheckedContinuation { invalidationContinuation = $0 }
        }
        invalidate()
    }
    func resumeInvalidation() {
        invalidationContinuation?.resume()
        invalidationContinuation = nil
    }
    func retireAfterServiceRestart() { serviceRetirementCount += 1 }

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
    private(set) var attachedDeviceAUEntries: [AUEffectChainEntry] = []
    private(set) var completedDeviceUpdates: [[String]] = []
    private(set) var completedDeviceSwitches: [String] = []
    private(set) var completedRouteOperations: [[String]] = []

    init(
        app: AudioApp,
        deviceUIDs: [String],
        restoresProcessByBundleID: Bool = false,
        tapSourceDeviceUID: String? = nil
    ) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
        self.restoresProcessByBundleID = restoresProcessByBundleID
        self.tapSourceDeviceUID = tapSourceDeviceUID
        self.configuredRestorationBundleIDs = restoresProcessByBundleID
            ? Set(app.restorationBundleIDs)
            : []
    }

    func activate(initial: TapInitialState) throws {
        startupEvents.append(.activate)
        events.append(.activate(TapInitialStateSnapshot(initial)))
    }

    func rebind(to app: AudioApp) {
        self.app = app
        events.append(.rebind(app.id, app.processObjectIDs))
    }

    func invalidate() {
        events.append(.invalidate)
    }

    @discardableResult func invalidateForHandoff() -> Bool {
        events.append(.invalidateForHandoff)
        return true
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
        startupEvents.append(.attachAppAU)
        attachedAppAUChain = chain
        attachedAppAUEntries = entries
    }

    func updateDeviceAUEffectChain(_ entries: [AUEffectChainEntry]) {
        startupEvents.append(.attachDeviceAU)
        attachedDeviceAUEntries = entries
    }

    func switchDevice(
        to newDeviceUID: String,
        preferredTapSourceDeviceUID: String?,
        sourceDeviceDead: Bool,
        deviceAUTransition: DeviceAUEffectTransition?
    ) async throws {
        if pauseNextDeviceSwitch {
            pauseNextDeviceSwitch = false
            await withCheckedContinuation { continuation in
                deviceSwitchContinuation = continuation
            }
        }
        if failNextDeviceSwitch {
            failNextDeviceSwitch = false
            throw StubError.deviceUpdateFailed
        }
        currentDeviceUIDs = [newDeviceUID]
        tapSourceDeviceUID = preferredTapSourceDeviceUID
        completedDeviceSwitches.append(newDeviceUID)
        completedRouteOperations.append([newDeviceUID])
    }

    func updateDevices(
        to newDeviceUIDs: [String],
        preferredTapSourceDeviceUID: String?,
        sourceDeviceDead: Bool,
        deviceAUTransition: DeviceAUEffectTransition?
    ) async throws {
        if pauseNextDeviceUpdate {
            pauseNextDeviceUpdate = false
            await withCheckedContinuation { continuation in
                deviceUpdateContinuation = continuation
            }
        }
        if failNextDeviceUpdate {
            failNextDeviceUpdate = false
            throw StubError.deviceUpdateFailed
        }
        currentDeviceUIDs = newDeviceUIDs
        tapSourceDeviceUID = preferredTapSourceDeviceUID
        completedDeviceUpdates.append(newDeviceUIDs)
        completedRouteOperations.append(newDeviceUIDs)
    }

    func resumePendingDeviceUpdate() {
        deviceUpdateContinuation?.resume()
        deviceUpdateContinuation = nil
    }

    func resumePendingDeviceSwitch() {
        deviceSwitchContinuation?.resume()
        deviceSwitchContinuation = nil
    }

    func hasRecentAudioCallback(within seconds: Double) -> Bool { recentCallback }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { healthEligible }

    func refreshTapSource(
        _ preferredDeviceUID: String?,
        deviceAUTransition: DeviceAUEffectTransition?
    ) async throws {
        tapSourceDeviceUID = preferredDeviceUID
    }
}

// MARK: - Process monitor stub

@MainActor
final class StubProcessMonitor: AudioProcessMonitoring {
    var connectedApps: [AudioApp] = []
    var activeApps: [AudioApp] = []
    var outputAppsOverride: [AudioApp]?
    var activeOutputApps: [AudioApp] { outputAppsOverride ?? activeApps }
    var resetCount = 0
    var startCount = 0
    var isMonitoringReady = true
    var onAppsChanged: (([AudioApp]) -> Void)?
    func start() { startCount += 1 }
    func stop() {}
    func resetAfterServiceRestart() { resetCount += 1 }
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let deviceMonitor: MockAudioDeviceMonitor
    let deviceVolume: MockDeviceVolumeProviding
    let processMonitor: StubProcessMonitor
    let app: AudioApp
    let device: AudioDevice
    let lastTap: () -> RecordingProcessTapController?
    let allTaps: () -> [RecordingProcessTapController]
    let failNextTapCreations: (Int) -> Void
}

@MainActor
private func makeFixture(
    supportsAutoEQ: Bool = true,
    deviceVolume: Float = 0.75,
    enableColdStartPrearming: Bool = false,
    tapFactoryFailures: Int = 0
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
    mockVolume.defaultDeviceID = device.id
    mockVolume.defaultDeviceUID = device.uid

    let app = AudioApp(
        id: 12345,
        processObjectIDs: [],
        name: "TestApp",
        icon: NSImage(),
        bundleID: "com.test.tapinitial"
    )

    let processMonitor = StubProcessMonitor()
    processMonitor.connectedApps = [app]
    processMonitor.activeApps = [app]

    // Capture every tap the factory hands out so tests can read the captured
    // event log. Mutable box lets the closure write into the test scope.
    let box = TapBox()
    box.factoryFailuresRemaining = tapFactoryFailures

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
        tapFactory: { app, uids, preferredSource in
            if box.factoryFailuresRemaining > 0 {
                box.factoryFailuresRemaining -= 1
                throw RecordingProcessTapController.StubError.factoryFailed
            }
            let tap = RecordingProcessTapController(
                app: app,
                deviceUIDs: uids,
                restoresProcessByBundleID: enableColdStartPrearming
                    && app.supportsSafeProcessRestoration,
                tapSourceDeviceUID: preferredSource
            )
            box.last = tap
            box.all.append(tap)
            return tap
        },
        enableColdStartPrearming: enableColdStartPrearming,
        startMonitorsAutomatically: false
    )

    return Fixture(
        engine: engine,
        settings: settings,
        deviceMonitor: deviceMonitor,
        deviceVolume: mockVolume,
        processMonitor: processMonitor,
        app: app,
        device: device,
        lastTap: { box.last },
        allTaps: { box.all },
        failNextTapCreations: { box.factoryFailuresRemaining = $0 }
    )
}

@MainActor
private final class TapBox {
    var last: RecordingProcessTapController?
    var all: [RecordingProcessTapController] = []
    var factoryFailuresRemaining = 0
}

// MARK: - Suite

@Suite("Core Audio service recovery", .serialized)
@MainActor
struct AudioServiceRecoveryTests {
    /// Opt-in destructive integration check: an operator restarts coreaudiod twice
    /// on a test machine after READY appears. Never sends signals by itself.
    @Test("Real HAL restart notifications rebuild graphs twice",
          .enabled(if: ProcessInfo.processInfo.environment["FINETUNE_TEST_AUDIO_SERVICE_RESTART"] == "1"))
    func realHALRestartNotifications() async throws {
        let fix = makeFixture()
        let monitor = AudioServiceMonitor()
        defer { monitor.stop(); fix.engine.stop() }
        fix.engine.applyPersistedSettings()
        var count = 0
        monitor.onRestart = {
            count += 1
            fix.engine.handleAudioServiceRestart()
            FileHandle.standardError.write(Data("INTEGRATION_RESTART_RECEIVED: \(count)\n".utf8))
        }
        monitor.start()
        FileHandle.standardError.write(Data("INTEGRATION_READY_FOR_HAL_RESTART\n".utf8))
        for _ in 0..<900 {
            if count >= 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(count >= 2)
        await settle(fix.engine)
        #expect(!fix.engine.isRecoveringAudioService)
        #expect(fix.engine.audioServiceRecoveryError == nil)
        #expect(fix.allTaps().count >= 3)
    }
    private func settle(_ engine: AudioEngine) async {
        for _ in 0..<200 {
            if !engine.isRecoveringAudioService || engine.audioServiceRecoveryError != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Recovery did not settle within the test deadline")
    }

    @Test("Same PID and object IDs still create a new graph with saved first-buffer gain and the same AU")
    func rebuildsSameIdentityWithoutReinstantiatingAU() async throws {
        let fix = makeFixture()
        defer { fix.engine.stop() }
        fix.engine.serviceRecoveryRetryDelays = [.zero]
        let entry = AUEffectChainEntry(plugin: AUPluginDescriptor(
            componentType: kAudioUnitType_Effect, componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C, name: "AUDelay", manufacturer: "Apple", version: 1))
        fix.settings.setAUEffectChain([entry], for: fix.app.persistenceIdentifier)
        fix.settings.setVolume(for: fix.app.persistenceIdentifier, to: 0.125)
        fix.engine.pinApp(fix.app)
        fix.engine.applyPersistedSettings()
        let old = try #require(fix.lastTap())
        let chain = try #require(old.attachedAppAUChain)
        let host = try #require(chain.host(for: entry.id))
        fix.engine.handleAudioServiceRestart()
        #expect(fix.engine.isRecoveringAudioService)
        #expect(old.serviceRetirementCount == 1)
        #expect(!old.events.contains(.invalidateForHandoff))
        await settle(fix.engine)
        let replacement = try #require(fix.lastTap())
        #expect(replacement !== old)
        #expect(replacement.volume == 0.125)
        #expect(replacement.attachedAppAUChain === chain)
        #expect(replacement.attachedAppAUChain?.host(for: entry.id) === host)
        #expect(replacement.startupEvents.prefix(3) == [.attachAppAU, .attachDeviceAU, .activate])
        #expect(fix.processMonitor.resetCount >= 1)
        #expect(fix.engine.audioServiceRecoveryError == nil)
    }

    @Test("A stuck old callback reports failure and never creates a second producer")
    func stuckCallbackKeepsProvisioningClosed() async throws {
        let fix = makeFixture()
        defer { fix.engine.stop() }
        fix.engine.applyPersistedSettings()
        let old = try #require(fix.lastTap())
        old.serviceRestartCallbacksDrained = false
        fix.engine.serviceRecoveryDrainPolls = 1
        fix.engine.handleAudioServiceRestart()
        await settle(fix.engine)
        #expect(fix.engine.audioServiceRecoveryError != nil)
        fix.engine.applyPersistedSettings()
        #expect(fix.allTaps().count == 1)
        old.serviceRestartCallbacksDrained = true
        fix.engine.serviceRecoveryRetryDelays = [.zero]
        fix.engine.handleAudioServiceRestart()
        await settle(fix.engine)
        #expect(fix.allTaps().count == 2)
    }

    @Test("Stop cancels recovery, including a callback drain already in progress")
    func stopDoesNotResurrectMonitors() async throws {
        let fix = makeFixture()
        fix.engine.applyPersistedSettings()
        let old = try #require(fix.lastTap())
        old.serviceRestartCallbacksDrained = false
        fix.engine.handleAudioServiceRestart()
        await Task.yield()
        fix.engine.stop()
        old.serviceRestartCallbacksDrained = true
        try? await Task.sleep(for: .milliseconds(40))
        #expect(fix.allTaps().count == 1)
        #expect(fix.processMonitor.startCount == 0)
    }

    @Test("Back-to-back restarts coalesce into the newest recovery")
    func repeatedResetOnlyRebuildsOnce() async {
        let fix = makeFixture()
        defer { fix.engine.stop() }
        fix.engine.applyPersistedSettings()
        fix.engine.serviceRecoveryRetryDelays = [.zero]
        fix.engine.handleAudioServiceRestart()
        fix.engine.handleAudioServiceRestart()
        await settle(fix.engine)
        #expect(fix.allTaps().count == 2)
    }

    @Test("Unavailable default output reports failure and can recover on retry")
    func missingDefaultIsNotSuccessfulRecovery() async {
        let fix = makeFixture()
        defer { fix.engine.stop() }
        fix.engine.applyPersistedSettings()
        fix.engine.serviceRecoveryRetryDelays = [.zero]
        fix.deviceVolume.defaultDeviceUID = nil
        fix.engine.handleAudioServiceRestart()
        await settle(fix.engine)
        #expect(fix.engine.audioServiceRecoveryError != nil)
        #expect(fix.allTaps().count == 1)
        fix.deviceVolume.defaultDeviceUID = fix.device.uid
        fix.engine.handleAudioServiceRestart()
        await settle(fix.engine)
        #expect(fix.allTaps().count == 2)
    }

    @Test("Failed listener registration cannot be reported as recovered")
    func registrationFailureIsVisible() async {
        let fix = makeFixture()
        defer { fix.engine.stop() }
        fix.engine.serviceRecoveryRetryDelays = [.zero]
        fix.processMonitor.isMonitoringReady = false
        fix.engine.handleAudioServiceRestart()
        await settle(fix.engine)
        #expect(fix.engine.audioServiceRecoveryError != nil)
        #expect(fix.allTaps().isEmpty)
    }

    @Test("Never-started output recovers after three misses; input-only and pause reset misses")
    func outputOnlyHealthCheck() async throws {
        let fix = makeFixture()
        defer { fix.engine.stop() }
        fix.engine.applyPersistedSettings()
        let old = try #require(fix.lastTap())
        old.healthEligible = true
        await fix.engine.checkTapHealth()
        await fix.engine.checkTapHealth()
        fix.processMonitor.outputAppsOverride = []
        await fix.engine.checkTapHealth()
        await fix.engine.checkTapHealth()
        #expect(fix.allTaps().count == 1)
        fix.processMonitor.outputAppsOverride = [fix.app]
        await fix.engine.checkTapHealth()
        await fix.engine.checkTapHealth()
        #expect(fix.allTaps().count == 1)
        await fix.engine.checkTapHealth()
        #expect(fix.allTaps().count == 2)
    }

    @Test("Invalid HAL identity is repaired even for a paused app")
    func pausedInvalidIdentityIsRepaired() async throws {
        let fix = makeFixture()
        defer { fix.engine.stop() }
        fix.engine.applyPersistedSettings()
        let old = try #require(fix.lastTap())
        old.hasValidAudioResources = false
        fix.processMonitor.activeApps = []
        await fix.engine.checkTapHealth()
        #expect(fix.allTaps().count == 2)
    }

    @Test("Health checks do not interrupt an in-flight route resource transition")
    func validRouteTransitionIsNotADeadTap() async throws {
        let fix = makeFixture()
        defer { fix.engine.stop() }
        fix.engine.applyPersistedSettings()
        let tap = try #require(fix.lastTap())
        tap.hasValidAudioResources = false
        tap.isAudioResourceTransitionInProgress = true
        await fix.engine.checkTapHealth()
        #expect(fix.allTaps().count == 1)
        tap.isAudioResourceTransitionInProgress = false
        await fix.engine.checkTapHealth()
        #expect(fix.allTaps().count == 2)
    }

    @Test("A failed health replacement shows protection loss and clears it only after retry succeeds")
    func failedHealthReplacementIsVisible() async throws {
        let fix = makeFixture()
        defer { fix.engine.stop() }
        fix.engine.applyPersistedSettings()
        let tap = try #require(fix.lastTap())
        tap.hasValidAudioResources = false
        fix.failNextTapCreations(20)
        await fix.engine.checkTapHealth()
        #expect(fix.engine.audioServiceRecoveryError != nil)
        #expect(fix.allTaps().count == 1)
        fix.failNextTapCreations(0)
        await fix.engine.checkTapHealth()
        #expect(fix.allTaps().count == 2)
        #expect(fix.engine.audioServiceRecoveryError == nil)
    }

    @Test("Late pre-reset route completion cannot update the replacement graph")
    func oldRouteCompletionIsIgnored() async throws {
        let fix = makeFixture()
        defer { fix.engine.stop() }
        fix.engine.applyPersistedSettings()
        let old = try #require(fix.lastTap())
        old.pauseNextDeviceSwitch = true
        let other = AudioDevice(id: 101, uid: "uid-other", name: "Other", icon: nil, supportsAutoEQ: false)
        fix.deviceMonitor.addOutputDevice(other)
        fix.engine.setDevice(for: fix.app, deviceUID: other.uid)
        for _ in 0..<20 where !old.hasPendingDeviceSwitch { await Task.yield() }
        fix.engine.serviceRecoveryRetryDelays = [.zero]
        fix.engine.handleAudioServiceRestart()
        await settle(fix.engine)
        let replacement = try #require(fix.lastTap())
        old.resumePendingDeviceSwitch()
        for _ in 0..<20 { await Task.yield() }
        #expect(replacement !== old)
        #expect(fix.lastTap() === replacement)
        #expect(replacement.currentDeviceUID == other.uid)
    }

    @Test("Standby creation cannot overtake an in-flight persistent producer handoff")
    func asyncHandoffBlocksStandbyProducer() async throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        defer { fix.engine.stop() }
        fix.engine.pinApp(fix.app)
        fix.engine.applyPersistedSettings()
        let old = try #require(fix.lastTap())
        old.hasValidAudioResources = false
        old.pauseInvalidation = true
        let repair = Task { await fix.engine.checkTapHealth() }
        for _ in 0..<30 where !old.hasPendingInvalidation { await Task.yield() }
        #expect(old.hasPendingInvalidation)
        fix.processMonitor.connectedApps = []
        fix.processMonitor.activeApps = []
        fix.processMonitor.onAppsChanged?([])
        #expect(fix.allTaps().count == 1)
        old.resumeInvalidation()
        await repair.value
        #expect(fix.allTaps().count == 2)
    }

    @Test("Stop and start during an async handoff cannot permanently block provisioning")
    func stopStartDuringHandoffRecovers() async throws {
        let fix = makeFixture()
        defer { fix.engine.stop() }
        fix.engine.applyPersistedSettings()
        let old = try #require(fix.lastTap())
        old.hasValidAudioResources = false
        old.pauseInvalidation = true
        let repair = Task { await fix.engine.checkTapHealth() }
        for _ in 0..<30 where !old.hasPendingInvalidation { await Task.yield() }
        fix.engine.stop()
        fix.engine.start()
        #expect(fix.allTaps().count == 1)
        old.resumeInvalidation()
        await repair.value
        await fix.engine.checkTapHealth()
        #expect(fix.allTaps().count == 2)
    }
}

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
        fix.processMonitor.connectedApps = []
        fix.processMonitor.activeApps = []
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

    @Test("Connected clients remain available for pre-arming while the active list stays quiet")
    func separatesConnectedClientsFromRunningAudio() {
        let idle = AudioApp(
            id: 300,
            processObjectIDs: [31, 32],
            name: "Idle Player",
            icon: NSImage(),
            bundleID: "com.test.idle-player"
        )
        let playing = AudioApp(
            id: 400,
            processObjectIDs: [41, 42],
            name: "Playing Player",
            icon: NSImage(),
            bundleID: "com.test.playing-player"
        )

        let active = AudioProcessMonitor.appsRunningAudio(
            from: [idle, playing],
            isRunning: { $0 == 42 }
        )

        #expect(active.map(\.id) == [playing.id])
    }

    @Test("Stable PID/object IDs still notify when helper bundle metadata becomes complete")
    func processMetadataChangesTriggerLifecycleRefresh() {
        let base = AudioApp(
            id: 401,
            processObjectIDs: [51],
            name: "Browser",
            icon: NSImage(),
            bundleID: "com.test.browser",
            audioProcessBundleIDs: ["com.test.browser"]
        )
        let enriched = AudioApp(
            id: base.id,
            processObjectIDs: base.processObjectIDs,
            name: base.name,
            icon: NSImage(),
            bundleID: base.bundleID,
            isHelperBacked: true,
            audioProcessBundleIDs: ["com.test.browser", "com.test.browser.helper"]
        )

        #expect(AudioProcessMonitor.lifecycleChanged(
            oldConnected: [base],
            oldActive: [base],
            newConnected: [enriched],
            newActive: [enriched]
        ))
    }

    @Test("Stable helper state still notifies when a shared process bundle arrives late")
    func rawProcessBundleChangesTriggerLifecycleRefresh() {
        let baseOnly = AudioApp(
            id: 402,
            processObjectIDs: [52, 53],
            name: "Browser",
            icon: NSImage(),
            bundleID: "com.test.browser",
            isHelperBacked: true,
            audioProcessBundleIDs: ["com.test.browser"]
        )
        let sharedHelperResolved = AudioApp(
            id: baseOnly.id,
            processObjectIDs: baseOnly.processObjectIDs,
            name: baseOnly.name,
            icon: NSImage(),
            bundleID: baseOnly.bundleID,
            isHelperBacked: true,
            audioProcessBundleIDs: ["com.test.browser", "com.apple.WebKit.GPU"]
        )

        // Both snapshots intentionally have the same restoration-safe bundle set and
        // helper flag. The raw Core Audio identity is what must wake the engine.
        #expect(baseOnly.restorationBundleIDs == sharedHelperResolved.restorationBundleIDs)
        #expect(AudioProcessMonitor.lifecycleChanged(
            oldConnected: [baseOnly],
            oldActive: [baseOnly],
            newConnected: [sharedHelperResolved],
            newActive: [sharedHelperResolved]
        ))
    }

    @Test("Bundle restoration keeps app-specific helpers but rejects shared system helpers")
    func restorationBundleIDsStayInsideAppNamespace() {
        let chrome = AudioApp(
            id: 301,
            processObjectIDs: [31, 32],
            name: "Google Chrome",
            icon: NSImage(),
            bundleID: "com.google.Chrome",
            isHelperBacked: true,
            audioProcessBundleIDs: [
                "com.apple.WebKit.GPU",
                "com.google.Chrome.helper",
                "com.google.Chrome"
            ]
        )

        #expect(chrome.restorationBundleIDs == [
            "com.google.Chrome",
            "com.google.Chrome.helper"
        ])
    }

    @Test("Pinned metadata written before bundle restoration remains decodable")
    func legacyPinnedMetadataDecodesWithoutRestorationBundles() throws {
        let data = Data(#"{"persistenceIdentifier":"com.test.legacy","displayName":"Legacy","bundleID":"com.test.legacy"}"#.utf8)
        let info = try JSONDecoder().decode(PinnedAppInfo.self, from: data)

        #expect(info.persistenceIdentifier == "com.test.legacy")
        #expect(info.restorationBundleIDs == nil)
    }

    @Test("Saved gain provisions a connected idle app before its first IO buffer")
    func connectedIdleAppIsProvisionedBeforeRunning() throws {
        let fix = makeFixture()
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = [fix.app]
        fix.settings.setVolume(for: fix.app.persistenceIdentifier, to: 0.125)

        fix.engine.applyPersistedSettings()

        let tap = try #require(fix.lastTap())
        #expect(tap.app.id == fix.app.id)
        #expect(abs(tap.volume - 0.125) < 0.000_001)
        #expect(tap.events.first.map { event in
            if case .activate = event { return true }
            return false
        } == true)
    }

    @Test("An explicit route provisions a connected idle app before playback")
    func routeOnlyIdleAppIsProvisioned() throws {
        let fix = makeFixture()
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = [fix.app]
        fix.settings.setDeviceRouting(
            for: fix.app.persistenceIdentifier,
            deviceUID: fix.device.uid
        )

        fix.engine.applyPersistedSettings()

        let tap = try #require(fix.lastTap())
        #expect(tap.app.id == fix.app.id)
        #expect(tap.currentDeviceUIDs == [fix.device.uid])
    }

    @Test("Pinned bundle tap is already live while absent and is adopted without rebuilding")
    func pinnedBundleTapClosesColdRelaunchGap() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.settings.setVolume(for: fix.app.persistenceIdentifier, to: 0.1)

        fix.engine.pinApp(fix.app)

        let standby = try #require(fix.lastTap())
        #expect(fix.allTaps().count == 1)
        #expect(standby.app.id < 0)
        #expect(standby.app.processObjectIDs.isEmpty)
        #expect(standby.restoresProcessByBundleID)
        #expect(abs(standby.volume - 0.1) < 0.000_001)

        fix.engine.setVolumeForInactive(
            identifier: fix.app.persistenceIdentifier,
            to: 0.2
        )
        #expect(abs(standby.volume - 0.2) < 0.000_001)

        let relaunched = AudioApp(
            id: 54321,
            processObjectIDs: [501, 502],
            name: fix.app.name,
            icon: NSImage(),
            bundleID: fix.app.bundleID,
            audioProcessBundleIDs: ["com.test.tapinitial"]
        )
        fix.processMonitor.connectedApps = [relaunched]
        fix.engine.applyPersistedSettings()

        #expect(fix.allTaps().count == 1)
        #expect(fix.lastTap() === standby)
        #expect(standby.app.id == relaunched.id)
        #expect(standby.app.processObjectIDs == relaunched.processObjectIDs)
        #expect(standby.events.contains(.rebind(relaunched.id, relaunched.processObjectIDs)))
        #expect(abs(standby.volume - 0.2) < 0.000_001)
    }

    @Test("A standby missing a newly observed helper is rebuilt instead of falsely adopted")
    func helperBundleGrowthRebuildsStandby() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.settings.setVolume(for: fix.app.persistenceIdentifier, to: 0.1)
        fix.engine.pinApp(fix.app)

        let baseOnlyStandby = try #require(fix.lastTap())
        #expect(baseOnlyStandby.configuredRestorationBundleIDs == ["com.test.tapinitial"])

        let relaunched = AudioApp(
            id: 54322,
            processObjectIDs: [601],
            name: fix.app.name,
            icon: NSImage(),
            bundleID: fix.app.bundleID,
            isHelperBacked: true,
            audioProcessBundleIDs: ["com.test.tapinitial.helper"]
        )
        fix.processMonitor.connectedApps = [relaunched]
        fix.processMonitor.activeApps = [relaunched]
        fix.engine.applyPersistedSettings()

        let replacement = try #require(fix.lastTap())
        #expect(fix.allTaps().count == 2)
        #expect(replacement !== baseOnlyStandby)
        #expect(baseOnlyStandby.events.contains(.invalidateForHandoff))
        #expect(replacement.app.id == relaunched.id)
        #expect(replacement.configuredRestorationBundleIDs == [
            "com.test.tapinitial",
            "com.test.tapinitial.helper"
        ])
        #expect(abs(replacement.volume - 0.1) < 0.000_001)
    }

    @Test("A restoring tap absorbs new process objects already covered by its bundles")
    func coveredProcessMembershipGrowthRebindsWithoutRebuild() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        let helperAwareApp = AudioApp(
            id: fix.app.id,
            processObjectIDs: [],
            name: fix.app.name,
            icon: NSImage(),
            bundleID: fix.app.bundleID,
            isHelperBacked: true,
            audioProcessBundleIDs: ["com.test.tapinitial.helper"]
        )
        fix.engine.pinApp(helperAwareApp)
        let restoringTap = try #require(fix.lastTap())
        #expect(restoringTap.configuredRestorationBundleIDs == [
            "com.test.tapinitial",
            "com.test.tapinitial.helper"
        ])

        let firstSnapshot = AudioApp(
            id: 54325,
            processObjectIDs: [901],
            name: fix.app.name,
            icon: NSImage(),
            bundleID: fix.app.bundleID,
            isHelperBacked: true,
            audioProcessBundleIDs: ["com.test.tapinitial.helper"]
        )
        fix.processMonitor.connectedApps = [firstSnapshot]
        fix.processMonitor.activeApps = [firstSnapshot]
        fix.engine.applyPersistedSettings()

        let expandedSnapshot = AudioApp(
            id: firstSnapshot.id,
            processObjectIDs: [901, 902],
            name: firstSnapshot.name,
            icon: NSImage(),
            bundleID: firstSnapshot.bundleID,
            isHelperBacked: true,
            audioProcessBundleIDs: firstSnapshot.audioProcessBundleIDs
        )
        fix.processMonitor.connectedApps = [expandedSnapshot]
        fix.processMonitor.activeApps = [expandedSnapshot]
        fix.engine.applyPersistedSettings()

        #expect(fix.allTaps().count == 1)
        #expect(fix.lastTap() === restoringTap)
        #expect(restoringTap.app.processObjectIDs == [901, 902])
        #expect(!restoringTap.events.contains(.invalidateForHandoff))
        #expect(restoringTap.events.contains(.rebind(expandedSnapshot.id, [901, 902])))
    }

    @Test("An uncovered shared helper forces an object-ID handoff from a restoring tap")
    func uncoveredHelperMembershipRebuildsRestoringTap() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.engine.pinApp(fix.app)
        let restoringTap = try #require(fix.lastTap())

        let helperSnapshot = AudioApp(
            id: 54326,
            processObjectIDs: [903],
            name: fix.app.name,
            icon: NSImage(),
            bundleID: fix.app.bundleID,
            isHelperBacked: true,
            audioProcessBundleIDs: ["com.apple.WebKit.GPU"]
        )
        fix.processMonitor.connectedApps = [helperSnapshot]
        fix.processMonitor.activeApps = [helperSnapshot]
        fix.engine.applyPersistedSettings()

        let replacement = try #require(fix.lastTap())
        #expect(fix.allTaps().count == 2)
        #expect(replacement !== restoringTap)
        #expect(restoringTap.events.contains(.invalidateForHandoff))
        #expect(replacement.app.processObjectIDs == [903])
        #expect(!replacement.restoresProcessByBundleID)
        #expect(replacement.configuredRestorationBundleIDs.isEmpty)

        // The replacement explicitly contains object 903. An unrelated settings pass
        // must not rebuild it forever merely because the shared helper remains unsafe
        // for future bundle-only restoration.
        fix.engine.applyPersistedSettings()
        #expect(fix.allTaps().count == 2)
        #expect(fix.lastTap() === replacement)
    }

    @Test("A shared helper bundle arriving on stable process objects forces one handoff")
    func lateSharedHelperMetadataRebuildsRestoringTapOnce() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.engine.pinApp(fix.app)
        let restoringTap = try #require(fix.lastTap())

        let baseOnlySnapshot = AudioApp(
            id: 54327,
            processObjectIDs: [904, 905],
            name: fix.app.name,
            icon: NSImage(),
            bundleID: fix.app.bundleID,
            isHelperBacked: true,
            audioProcessBundleIDs: ["com.test.tapinitial"]
        )
        fix.processMonitor.connectedApps = [baseOnlySnapshot]
        fix.processMonitor.activeApps = [baseOnlySnapshot]
        fix.engine.applyPersistedSettings()

        #expect(fix.allTaps().count == 1)
        #expect(fix.lastTap() === restoringTap)
        #expect(restoringTap.app.processObjectIDs == baseOnlySnapshot.processObjectIDs)

        let resolvedSharedHelper = AudioApp(
            id: baseOnlySnapshot.id,
            processObjectIDs: baseOnlySnapshot.processObjectIDs,
            name: baseOnlySnapshot.name,
            icon: NSImage(),
            bundleID: baseOnlySnapshot.bundleID,
            isHelperBacked: true,
            audioProcessBundleIDs: ["com.test.tapinitial", "com.apple.WebKit.GPU"]
        )
        fix.processMonitor.connectedApps = [resolvedSharedHelper]
        fix.processMonitor.activeApps = [resolvedSharedHelper]
        fix.engine.applyPersistedSettings()

        let replacement = try #require(fix.lastTap())
        #expect(fix.allTaps().count == 2)
        #expect(replacement !== restoringTap)
        #expect(restoringTap.events.contains(.invalidateForHandoff))
        #expect(replacement.app.processObjectIDs == resolvedSharedHelper.processObjectIDs)
        #expect(!replacement.restoresProcessByBundleID)
        #expect(replacement.configuredRestorationBundleIDs.isEmpty)

        fix.engine.applyPersistedSettings()
        #expect(fix.allTaps().count == 2)
        #expect(fix.lastTap() === replacement)
    }

    @Test("Unresolved helper metadata rejects bundle-only standby adoption")
    func unresolvedHelperMetadataUsesExplicitObjectTap() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.engine.pinApp(fix.app)
        let restoringTap = try #require(fix.lastTap())

        let incompleteSnapshot = AudioApp(
            id: 54328,
            processObjectIDs: [906, 907],
            name: fix.app.name,
            icon: NSImage(),
            bundleID: fix.app.bundleID,
            isHelperBacked: true,
            audioProcessBundleIDs: ["com.test.tapinitial"],
            hasUnresolvedAudioProcessBundleMetadata: true
        )
        fix.processMonitor.connectedApps = [incompleteSnapshot]
        fix.processMonitor.activeApps = [incompleteSnapshot]
        fix.engine.applyPersistedSettings()

        let explicitTap = try #require(fix.lastTap())
        #expect(fix.allTaps().count == 2)
        #expect(explicitTap !== restoringTap)
        #expect(restoringTap.events.contains(.invalidateForHandoff))
        #expect(explicitTap.app.processObjectIDs == incompleteSnapshot.processObjectIDs)
        #expect(!explicitTap.restoresProcessByBundleID)
        #expect(explicitTap.configuredRestorationBundleIDs.isEmpty)

        fix.engine.applyPersistedSettings()
        #expect(fix.allTaps().count == 2)
        #expect(fix.lastTap() === explicitTap)
    }

    @Test("An exited unsafe explicit tap is immediately backed by a safe bundle standby")
    func unsafeHelperExitRearmsBundleStandbyWithoutCleanupDelay() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.engine.pinApp(fix.app)
        let originalStandby = try #require(fix.lastTap())

        let helperSnapshot = AudioApp(
            id: 54329,
            processObjectIDs: [908, 909],
            name: fix.app.name,
            icon: NSImage(),
            bundleID: fix.app.bundleID,
            isHelperBacked: true,
            audioProcessBundleIDs: ["com.test.tapinitial", "com.apple.WebKit.GPU"]
        )
        fix.processMonitor.connectedApps = [helperSnapshot]
        fix.processMonitor.activeApps = [helperSnapshot]
        fix.engine.applyPersistedSettings()

        let unsafeLiveTap = try #require(fix.lastTap())
        #expect(unsafeLiveTap !== originalStandby)
        #expect(!unsafeLiveTap.restoresProcessByBundleID)

        // Deliver the same lifecycle callback production receives when Core Audio drops
        // the live objects. The unsafe producer must be joined before the new standby is
        // given the same persistent AU strip; two simultaneous producers are forbidden.
        fix.processMonitor.connectedApps = []
        fix.processMonitor.activeApps = []
        fix.processMonitor.onAppsChanged?([])

        let safeStandby = try #require(fix.lastTap())
        #expect(fix.allTaps().count == 3)
        #expect(safeStandby !== unsafeLiveTap)
        #expect(unsafeLiveTap.events.contains(.invalidateForHandoff))
        #expect(safeStandby.app.id < 0)
        #expect(safeStandby.app.processObjectIDs.isEmpty)
        #expect(safeStandby.restoresProcessByBundleID)
        #expect(safeStandby.configuredRestorationBundleIDs == ["com.test.tapinitial"])
    }

    @Test("Learned helper identities survive a base-process-only monitor snapshot")
    func learnedHelperBundleIDsAccumulate() throws {
        let fix = makeFixture()
        fix.engine.pinApp(fix.app)
        fix.settings.updatePinnedAppRestorationBundleIDs(
            fix.app.persistenceIdentifier,
            bundleIDs: ["com.test.tapinitial", "com.test.tapinitial.helper"]
        )
        fix.settings.updatePinnedAppRestorationBundleIDs(
            fix.app.persistenceIdentifier,
            bundleIDs: ["com.test.tapinitial"]
        )

        let info = try #require(fix.settings.getPinnedAppInfo().first)
        #expect(info.restorationBundleIDs == [
            "com.test.tapinitial",
            "com.test.tapinitial.helper"
        ])
    }

    @Test("A base-only live snapshot still provisions every previously learned helper")
    func persistedHelpersEnrichConnectedAppProvisioning() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.settings.pinApp(
            fix.app.persistenceIdentifier,
            info: PinnedAppInfo(
                persistenceIdentifier: fix.app.persistenceIdentifier,
                displayName: fix.app.name,
                bundleID: fix.app.bundleID,
                restorationBundleIDs: [
                    "com.test.tapinitial",
                    "com.test.tapinitial.helper"
                ]
            )
        )
        // The current HAL snapshot has only the base client. Provisioning must merge the
        // historical helper identity before the ProcessTapController description is built.
        fix.processMonitor.connectedApps = [fix.app]
        fix.processMonitor.activeApps = [fix.app]

        fix.engine.applyPersistedSettings()

        let tap = try #require(fix.lastTap())
        #expect(tap.configuredRestorationBundleIDs == [
            "com.test.tapinitial",
            "com.test.tapinitial.helper"
        ])
    }

    @Test("A route completion after standby adoption keeps the live PID's saved gain")
    func asyncStandbyRouteUsesAdoptedPID() async throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.settings.setVolume(for: fix.app.persistenceIdentifier, to: 0.1)
        fix.engine.pinApp(fix.app)
        let standby = try #require(fix.lastTap())

        let secondDevice = AudioDevice(
            id: AudioDeviceID(100),
            uid: "uid-second",
            name: "Second Output",
            icon: nil,
            supportsAutoEQ: false
        )
        fix.deviceMonitor.addOutputDevice(secondDevice)
        standby.pauseNextDeviceUpdate = true
        fix.engine.setDeviceRoutingForInactive(
            identifier: fix.app.persistenceIdentifier,
            deviceUID: secondDevice.uid
        )
        for _ in 0..<50 where !standby.hasPendingDeviceUpdate {
            await Task.yield()
        }
        #expect(standby.hasPendingDeviceUpdate)

        let relaunched = AudioApp(
            id: 54323,
            processObjectIDs: [701],
            name: fix.app.name,
            icon: NSImage(),
            bundleID: fix.app.bundleID
        )
        fix.processMonitor.connectedApps = [relaunched]
        fix.processMonitor.activeApps = [relaunched]
        fix.engine.applyPersistedSettings()
        for _ in 0..<10 { await Task.yield() }

        standby.resumePendingDeviceUpdate()
        for _ in 0..<20 { await Task.yield() }

        #expect(standby.app.id == relaunched.id)
        #expect(abs(standby.volume - 0.1) < 0.000_001)
    }

    @Test("A failed inactive route keeps the actual route and remains retryable")
    func failedInactiveRouteCanRetry() async throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.engine.pinApp(fix.app)
        let standby = try #require(fix.lastTap())

        let secondDevice = AudioDevice(
            id: AudioDeviceID(101),
            uid: "uid-route-retry",
            name: "Retry Output",
            icon: nil,
            supportsAutoEQ: false
        )
        fix.deviceMonitor.addOutputDevice(secondDevice)
        standby.failNextDeviceUpdate = true

        fix.engine.setDeviceRoutingForInactive(
            identifier: fix.app.persistenceIdentifier,
            deviceUID: secondDevice.uid
        )
        for _ in 0..<20 { await Task.yield() }
        #expect(standby.currentDeviceUIDs == [fix.device.uid])

        // Failure removed the applied marker, so the next connected-app settings pass can
        // retry the persisted destination instead of accepting stale route metadata.
        let relaunched = AudioApp(
            id: 54324,
            processObjectIDs: [801],
            name: fix.app.name,
            icon: NSImage(),
            bundleID: fix.app.bundleID
        )
        fix.processMonitor.connectedApps = [relaunched]
        fix.processMonitor.activeApps = [relaunched]
        fix.engine.applyPersistedSettings()
        for _ in 0..<20 { await Task.yield() }
        #expect(standby.currentDeviceUIDs == [secondDevice.uid])
    }

    @Test("A failed default-follow switch rolls back standby metadata and retries")
    func failedDefaultFollowRouteCanRetry() async throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.engine.pinApp(fix.app)
        let standby = try #require(fix.lastTap())

        let secondDevice = AudioDevice(
            id: AudioDeviceID(102),
            uid: "uid-default-route-retry",
            name: "Default Retry Output",
            icon: nil,
            supportsAutoEQ: false
        )
        fix.deviceMonitor.addOutputDevice(secondDevice)
        fix.deviceVolume.defaultDeviceID = secondDevice.id
        fix.deviceVolume.defaultDeviceUID = secondDevice.uid
        standby.failNextDeviceSwitch = true

        #expect(fix.engine.setDefaultOutputDevice(secondDevice.id))
        for _ in 0..<20 { await Task.yield() }
        #expect(standby.currentDeviceUIDs == [fix.device.uid])

        for _ in 0..<40 where standby.currentDeviceUIDs != [secondDevice.uid] {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(standby.currentDeviceUIDs == [secondDevice.uid])
    }

    @Test("A late inactive route completion cannot overwrite the newest target")
    func latestInactiveRouteIntentWins() async throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.engine.pinApp(fix.app)
        let standby = try #require(fix.lastTap())

        let second = AudioDevice(
            id: AudioDeviceID(103), uid: "uid-route-second", name: "Second",
            icon: nil, supportsAutoEQ: false
        )
        let third = AudioDevice(
            id: AudioDeviceID(104), uid: "uid-route-third", name: "Third",
            icon: nil, supportsAutoEQ: false
        )
        fix.deviceMonitor.addOutputDevice(second)
        fix.deviceMonitor.addOutputDevice(third)

        standby.pauseNextDeviceUpdate = true
        fix.engine.setDeviceRoutingForInactive(
            identifier: fix.app.persistenceIdentifier,
            deviceUID: second.uid
        )
        for _ in 0..<50 where !standby.hasPendingDeviceUpdate { await Task.yield() }
        #expect(standby.hasPendingDeviceUpdate)

        fix.engine.setDeviceRoutingForInactive(
            identifier: fix.app.persistenceIdentifier,
            deviceUID: third.uid
        )
        for _ in 0..<50 where standby.currentDeviceUIDs != [third.uid] { await Task.yield() }
        #expect(standby.currentDeviceUIDs == [third.uid])

        // The older Second operation now finishes last and physically mutates the mock.
        // FineTune must reject its metadata and reconcile the actual tap back to Third.
        standby.resumePendingDeviceUpdate()
        for _ in 0..<40 where standby.completedRouteOperations.count < 3 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(Array(standby.completedRouteOperations.suffix(3)) == [
            [third.uid], [second.uid], [third.uid]
        ])
        #expect(standby.currentDeviceUIDs == [third.uid])
    }

    @Test("A late follow-default completion cannot overwrite the newest default")
    func latestDefaultRouteIntentWins() async throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.engine.pinApp(fix.app)
        let standby = try #require(fix.lastTap())

        let second = AudioDevice(
            id: AudioDeviceID(105), uid: "uid-default-second", name: "Second Default",
            icon: nil, supportsAutoEQ: false
        )
        let third = AudioDevice(
            id: AudioDeviceID(106), uid: "uid-default-third", name: "Third Default",
            icon: nil, supportsAutoEQ: false
        )
        fix.deviceMonitor.addOutputDevice(second)
        fix.deviceMonitor.addOutputDevice(third)

        standby.pauseNextDeviceSwitch = true
        // Deliberately leave DeviceVolumeMonitor's cache on the original default. HAL
        // setters succeed before their listener callback updates this property.
        #expect(fix.engine.setDefaultOutputDevice(second.id))
        for _ in 0..<50 where !standby.hasPendingDeviceSwitch { await Task.yield() }
        #expect(standby.hasPendingDeviceSwitch)

        #expect(fix.engine.setDefaultOutputDevice(third.id))
        for _ in 0..<50 where standby.currentDeviceUIDs != [third.uid] { await Task.yield() }
        #expect(standby.currentDeviceUIDs == [third.uid])

        standby.resumePendingDeviceSwitch()
        for _ in 0..<40 where standby.completedRouteOperations.count < 3 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(Array(standby.completedRouteOperations.suffix(3)) == [
            [third.uid], [second.uid], [third.uid]
        ])
        #expect(standby.currentDeviceUIDs == [third.uid])
        #expect(standby.tapSourceDeviceUID == third.uid)
    }

    @Test("A late device-reconnect restore cannot overwrite a newer explicit route")
    func latestRouteWinsOverReconnectRestore() async throws {
        let fix = makeFixture()
        var appSettings = fix.settings.appSettings
        appSettings.showDeviceDisconnectAlerts = false
        fix.settings.updateAppSettings(appSettings)
        let reconnected = AudioDevice(
            id: AudioDeviceID(107), uid: "uid-reconnected", name: "Reconnected",
            icon: nil, supportsAutoEQ: false
        )
        let newest = AudioDevice(
            id: AudioDeviceID(108), uid: "uid-after-reconnect", name: "Newest",
            icon: nil, supportsAutoEQ: false
        )

        // Persist an unavailable preference so initial provisioning temporarily falls
        // back to the current default, as it does across a physical disconnect.
        fix.settings.setDeviceRouting(
            for: fix.app.persistenceIdentifier,
            deviceUID: reconnected.uid
        )
        fix.engine.applyPersistedSettings()
        let tap = try #require(fix.lastTap())
        #expect(tap.currentDeviceUIDs == [fix.device.uid])

        fix.deviceMonitor.addOutputDevice(reconnected)
        tap.pauseNextDeviceSwitch = true
        fix.deviceMonitor.onDeviceConnected?(reconnected.uid, reconnected.name)
        for _ in 0..<50 where !tap.hasPendingDeviceSwitch { await Task.yield() }
        #expect(tap.hasPendingDeviceSwitch)

        fix.deviceMonitor.addOutputDevice(newest)
        fix.engine.setDevice(for: fix.app, deviceUID: newest.uid)
        for _ in 0..<50 where tap.currentDeviceUIDs != [newest.uid] { await Task.yield() }
        #expect(tap.currentDeviceUIDs == [newest.uid])

        tap.resumePendingDeviceSwitch()
        for _ in 0..<40 where tap.completedRouteOperations.count < 3 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(Array(tap.completedRouteOperations.suffix(3)) == [
            [newest.uid], [reconnected.uid], [newest.uid]
        ])
        #expect(tap.currentDeviceUIDs == [newest.uid])
    }

    @Test("Adding device AU processing dynamically pre-arms a connected idle client")
    func dynamicDeviceAUProvisionsConnectedIdleApp() throws {
        let fix = makeFixture()
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = [fix.app]
        fix.engine.applyPersistedSettings()
        #expect(fix.lastTap() == nil)

        fix.engine.addDeviceAUEffect(
            deviceUID: fix.device.uid,
            plugin: AUPluginDescriptor(
                componentType: kAudioUnitType_Effect,
                componentSubType: 0x6465_6C79,
                componentManufacturer: 0x6170_706C,
                name: "AUDelay",
                manufacturer: "Apple",
                version: 1
            )
        )

        let tap = try #require(fix.lastTap())
        let deviceAttach = try #require(tap.startupEvents.firstIndex(of: .attachDeviceAU))
        let activate = try #require(tap.startupEvents.firstIndex(of: .activate))
        #expect(deviceAttach < activate)
    }

    @Test("A processed new default pre-arms a connected idle client")
    func defaultDeviceChangeReevaluatesIdleEligibility() throws {
        let fix = makeFixture()
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = [fix.app]
        let processedDefault = AudioDevice(
            id: AudioDeviceID(110),
            uid: "uid-processed-default",
            name: "Processed Default",
            icon: nil,
            supportsAutoEQ: false
        )
        fix.deviceMonitor.addOutputDevice(processedDefault)
        let deviceEntry = AUEffectChainEntry(plugin: AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6465_6C79,
            componentManufacturer: 0x6170_706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        ))
        fix.settings.setDeviceAUEffectChain([deviceEntry], for: processedDefault.uid)

        fix.engine.applyPersistedSettings()
        #expect(fix.lastTap() == nil)

        // Model the HAL write/listener ordering: the setter records an echo first,
        // then DeviceVolumeMonitor publishes its updated cache and callback.
        #expect(fix.engine.setDefaultOutputDevice(processedDefault.id))
        fix.deviceVolume.defaultDeviceID = processedDefault.id
        fix.deviceVolume.defaultDeviceUID = processedDefault.uid
        fix.deviceVolume.onDefaultDeviceChanged?(processedDefault.uid)

        let tap = try #require(fix.lastTap())
        #expect(tap.currentDeviceUIDs == [processedDefault.uid])
        #expect(tap.attachedAppAUEntries.isEmpty)
        #expect(tap.attachedDeviceAUEntries.map(\.id) == [deviceEntry.id])
        let deviceAttach = try #require(tap.startupEvents.firstIndex(of: .attachDeviceAU))
        let activate = try #require(tap.startupEvents.firstIndex(of: .activate))
        #expect(deviceAttach < activate)
    }

    @Test("A reconnected explicit device moves the warm idle tap with its processor")
    func deviceConnectReevaluatesIdleEligibility() async throws {
        let fix = makeFixture()
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = [fix.app]
        var appSettings = fix.settings.appSettings
        appSettings.showDeviceDisconnectAlerts = false
        fix.settings.updateAppSettings(appSettings)
        let reconnected = AudioDevice(
            id: AudioDeviceID(111),
            uid: "uid-idle-reconnected",
            name: "Reconnected Processed Output",
            icon: nil,
            supportsAutoEQ: false
        )
        let deviceEntry = AUEffectChainEntry(plugin: AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6465_6C79,
            componentManufacturer: 0x6170_706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        ))
        fix.settings.setDeviceRouting(
            for: fix.app.persistenceIdentifier,
            deviceUID: reconnected.uid
        )
        fix.settings.setDeviceAUEffectChain([deviceEntry], for: reconnected.uid)

        fix.engine.applyPersistedSettings()
        let fallbackTap = try #require(fix.lastTap())
        #expect(fallbackTap.currentDeviceUIDs == [fix.device.uid])

        fix.deviceMonitor.addOutputDevice(reconnected)
        fix.deviceMonitor.onDeviceConnected?(reconnected.uid, reconnected.name)
        for _ in 0..<50 where fallbackTap.currentDeviceUIDs != [reconnected.uid] {
            await Task.yield()
        }

        let tap = try #require(fix.lastTap())
        #expect(tap === fallbackTap)
        #expect(tap.currentDeviceUIDs == [reconnected.uid])
        #expect(tap.attachedDeviceAUEntries.map(\.id) == [deviceEntry.id])
        let deviceAttach = try #require(tap.startupEvents.firstIndex(of: .attachDeviceAU))
        let activate = try #require(tap.startupEvents.firstIndex(of: .activate))
        #expect(deviceAttach < activate)
    }

    @Test("Hardware-to-software tier promotion pre-arms saved gain and mute")
    func softwareTierPromotionReevaluatesIdleEligibility() throws {
        let fix = makeFixture()
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = [fix.app]
        fix.deviceVolume.autoDetectedTiersByID[fix.device.id] = .hardware
        fix.deviceVolume.volumes[fix.device.id] = 0.8
        fix.deviceVolume.muteStates[fix.device.id] = true
        fix.settings.setSoftwareDeviceVolume(for: fix.device.uid, to: 0.2)
        fix.settings.setSoftwareDeviceMuteState(for: fix.device.uid, to: true)

        fix.engine.applyPersistedSettings()
        #expect(fix.lastTap() == nil)

        fix.deviceVolume.overridesByUID[fix.device.uid] = .software
        // Production readOneState loads these persisted values before publishing both
        // callbacks. Seed the mock with that post-read state.
        fix.deviceVolume.volumes[fix.device.id] = 0.2
        fix.deviceVolume.muteStates[fix.device.id] = true
        fix.deviceVolume.applyTierOverrideChange(for: fix.device.id)

        let tap = try #require(fix.lastTap())
        #expect(tap.currentDeviceUIDs == [fix.device.uid])
        #expect(abs(tap.currentDeviceVolume - 0.2) < 0.000_001)
        #expect(tap.isDeviceMuted)
        #expect(tap.volume == 0)
    }

    @Test("Software-to-hardware tier demotion clears stale digital attenuation")
    func hardwareTierDemotionRestoresAppGain() throws {
        let fix = makeFixture()
        fix.deviceVolume.overridesByUID[fix.device.uid] = .software
        fix.deviceVolume.volumes[fix.device.id] = 0.5
        fix.deviceVolume.muteStates[fix.device.id] = false
        fix.settings.setSoftwareDeviceVolume(for: fix.device.uid, to: 0.5)

        fix.engine.applyPersistedSettings()
        let tap = try #require(fix.lastTap())
        #expect(abs(tap.volume - 0.5) < 0.000_001)

        fix.deviceVolume.overridesByUID[fix.device.uid] = .hardware
        fix.deviceVolume.volumes[fix.device.id] = 0.8
        fix.deviceVolume.muteStates[fix.device.id] = false
        fix.deviceVolume.applyTierOverrideChange(for: fix.device.id)

        #expect(abs(tap.volume - 1.0) < 0.000_001)
        #expect(abs(tap.currentDeviceVolume - 0.8) < 0.000_001)
    }

    @Test("DDC mute retains digital silence until the user unmutes")
    func ddcMuteKeepsDigitalGainZero() throws {
        let fix = makeFixture()
        fix.deviceVolume.overridesByUID[fix.device.uid] = .ddc
        fix.engine.applyPersistedSettings()
        let tap = try #require(fix.lastTap())
        #expect(abs(tap.volume - 1) < 0.000_001)

        fix.deviceVolume.setMute(for: fix.device.id, to: true)
        #expect(tap.volume == 0)

        // Re-publishing the same intent after a probe/write does not release digital mute.
        fix.deviceVolume.onMuteChanged?(fix.device.id, true)
        #expect(tap.volume == 0)
        fix.deviceVolume.setMute(for: fix.device.id, to: false)
        #expect(abs(tap.volume - 1) < 0.000_001)
    }

    @Test("A paused connected app survives the real 30-second stale cleanup window")
    func pausedConnectedAppKeepsItsTapAcrossCleanupDeadline() async throws {
        let fix = makeFixture()
        fix.settings.setVolume(for: fix.app.persistenceIdentifier, to: 0.1)
        fix.engine.applyPersistedSettings()
        let tap = try #require(fix.lastTap())
        fix.processMonitor.activeApps = []
        fix.processMonitor.onAppsChanged?([])

        // Exercise the production 350 ms debounce + 30 s grace, not a copied policy.
        try await Task.sleep(for: .seconds(31))
        #expect(!tap.events.contains(.invalidate))
        #expect(!tap.events.contains(.invalidateForHandoff))
        #expect(abs(tap.volume - 0.1) < 0.000_001)

        fix.processMonitor.activeApps = [fix.app]
        fix.processMonitor.onAppsChanged?([fix.app])
        #expect(fix.allTaps().count == 1)
        #expect(fix.lastTap() === tap)
    }

    @Test("Complete safe metadata upgrades an unpinned tap only after playback pauses")
    func completedMetadataEnablesRestoration() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.settings.setVolume(for: fix.app.persistenceIdentifier, to: 0.1)
        let incomplete = AudioApp(
            id: fix.app.id, processObjectIDs: [999], name: fix.app.name,
            icon: NSImage(), bundleID: fix.app.bundleID,
            hasUnresolvedAudioProcessBundleMetadata: true
        )
        fix.processMonitor.connectedApps = [incomplete]
        fix.processMonitor.activeApps = [incomplete]
        fix.engine.applyPersistedSettings()
        let explicit = try #require(fix.lastTap())
        #expect(!explicit.restoresProcessByBundleID)

        let complete = AudioApp(
            id: incomplete.id, processObjectIDs: incomplete.processObjectIDs,
            name: incomplete.name, icon: NSImage(), bundleID: incomplete.bundleID,
            audioProcessBundleIDs: ["com.test.tapinitial"]
        )
        fix.processMonitor.connectedApps = [complete]
        fix.processMonitor.activeApps = [complete]
        fix.engine.applyPersistedSettings()
        // An optional restoration upgrade must not tear down a playing mutedWhenTapped
        // graph and expose raw audio while the replacement aggregate becomes ready.
        #expect(fix.allTaps().count == 1)
        #expect(!explicit.events.contains(.invalidateForHandoff))
        fix.processMonitor.activeApps = []
        fix.engine.applyPersistedSettings()
        let upgraded = try #require(fix.lastTap())
        #expect(fix.allTaps().count == 2)
        #expect(upgraded.restoresProcessByBundleID)
        #expect(explicit.events.contains(.invalidateForHandoff))
        #expect(abs(upgraded.volume - 0.1) < 0.000_001)
        fix.engine.applyPersistedSettings()
        #expect(fix.allTaps().count == 2)
    }

    #if !APP_STORE
    @Test("A DDC probe demotion to software pre-arms connected idle gain and mute")
    func ddcProbeDemotionReevaluatesIdleEligibility() throws {
        let fix = makeFixture()
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = [fix.app]
        fix.deviceVolume.autoDetectedTiersByID[fix.device.id] = .ddc
        fix.settings.setSoftwareDeviceVolume(for: fix.device.uid, to: 0.2)
        fix.settings.setSoftwareDeviceMuteState(for: fix.device.uid, to: true)

        fix.engine.applyPersistedSettings()
        #expect(fix.lastTap() == nil)

        // A display re-probe can remove DDC without a CoreAudio device-list event.
        // Model the post-refresh caches before delivering the production callback.
        fix.deviceVolume.autoDetectedTiersByID[fix.device.id] = .software
        fix.deviceVolume.volumes[fix.device.id] = 0.2
        fix.deviceVolume.muteStates[fix.device.id] = true
        fix.engine.ddcController.onProbeCompleted?()

        let tap = try #require(fix.lastTap())
        #expect(tap.currentDeviceUIDs == [fix.device.uid])
        #expect(abs(tap.currentDeviceVolume - 0.2) < 0.000_001)
        #expect(tap.isDeviceMuted)
        #expect(tap.volume == 0)
    }
    #endif

    @Test("Enabling loudness processing dynamically pre-arms a connected idle client")
    func dynamicLoudnessProvisionsConnectedIdleApp() throws {
        let fix = makeFixture()
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = [fix.app]
        fix.engine.applyPersistedSettings()
        #expect(fix.lastTap() == nil)

        var appSettings = fix.settings.appSettings
        appSettings.loudnessCompensationEnabled = true
        fix.settings.updateAppSettings(appSettings)
        fix.engine.setLoudnessCompensationEnabled(true)

        let tap = try #require(fix.lastTap())
        guard case let .activate(initial)? = tap.events.first else {
            Issue.record("Expected activation as the first tap event")
            return
        }
        #expect(initial.loudnessCompensationEnabled)
    }

    @Test("Changing the global app volume dynamically pre-arms a connected idle client")
    func dynamicDefaultVolumeProvisionsConnectedIdleApp() throws {
        let fix = makeFixture()
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = [fix.app]
        fix.engine.applyPersistedSettings()
        #expect(fix.lastTap() == nil)

        var appSettings = fix.settings.appSettings
        appSettings.defaultNewAppVolume = 0.5
        fix.settings.updateAppSettings(appSettings)
        fix.engine.defaultNewAppVolumeDidChange()

        let tap = try #require(fix.lastTap())
        #expect(abs(tap.volume - 0.5) < 0.000_001)
    }

    @Test("A transient bundle-only factory failure retries without a lifecycle event")
    func coldStartPrearmRetriesTransientFailure() async throws {
        let fix = makeFixture(
            enableColdStartPrearming: true,
            tapFactoryFailures: 1
        )
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []

        fix.engine.pinApp(fix.app)
        #expect(fix.lastTap() == nil)

        for _ in 0..<40 where fix.lastTap() == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let tap = try #require(fix.lastTap())
        #expect(tap.restoresProcessByBundleID)
        #expect(fix.allTaps().count == 1)
    }

    @Test("Pinned cold-start prearming resumes when the default device appears late")
    func coldStartPrearmWaitsForLateDefaultDevice() async throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.deviceVolume.defaultDeviceID = 0
        fix.deviceVolume.defaultDeviceUID = nil

        fix.engine.pinApp(fix.app)
        #expect(fix.lastTap() == nil)

        fix.deviceVolume.defaultDeviceID = fix.device.id
        fix.deviceVolume.defaultDeviceUID = fix.device.uid
        fix.deviceVolume.onDefaultDeviceChanged?(fix.device.uid)

        for _ in 0..<40 where fix.lastTap() == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        let tap = try #require(fix.lastTap())
        #expect(tap.currentDeviceUIDs == [fix.device.uid])
        #expect(tap.restoresProcessByBundleID)
    }

    @Test("A default-device echo catches up a cold-prearm retry created from stale cache")
    func defaultEchoCatchesUpLateColdPrearm() async throws {
        let fix = makeFixture(
            enableColdStartPrearming: true,
            tapFactoryFailures: 1
        )
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        let nextDefault = AudioDevice(
            id: AudioDeviceID(109), uid: "uid-echo-default", name: "Echo Default",
            icon: nil, supportsAutoEQ: false
        )
        fix.deviceMonitor.addOutputDevice(nextDefault)

        fix.engine.pinApp(fix.app)
        #expect(fix.lastTap() == nil)

        // The HAL write succeeds, but the monitor intentionally still reports the old
        // UID until its property listener fires.
        #expect(fix.engine.setDefaultOutputDevice(nextDefault.id))
        #expect(fix.deviceVolume.defaultDeviceUID == fix.device.uid)

        for _ in 0..<40 where fix.lastTap() == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        let tap = try #require(fix.lastTap())
        #expect(tap.currentDeviceUIDs == [fix.device.uid])

        fix.deviceVolume.defaultDeviceID = nextDefault.id
        fix.deviceVolume.defaultDeviceUID = nextDefault.uid
        fix.deviceVolume.onDefaultDeviceChanged?(nextDefault.uid)
        for _ in 0..<40 where tap.currentDeviceUIDs != [nextDefault.uid] {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(tap.currentDeviceUIDs == [nextDefault.uid])
        #expect(tap.tapSourceDeviceUID == nextDefault.uid)
    }

    @Test("Changing follow-default mode on the same UID refreshes the tap source")
    func sameUIDInactiveRoutingRefreshesTapSource() async throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.engine.pinApp(fix.app)
        let standby = try #require(fix.lastTap())
        #expect(standby.currentDeviceUIDs == [fix.device.uid])
        #expect(standby.tapSourceDeviceUID == fix.device.uid)

        fix.engine.setDeviceRoutingForInactive(
            identifier: fix.app.persistenceIdentifier,
            deviceUID: fix.device.uid
        )
        for _ in 0..<20 { await Task.yield() }
        #expect(standby.currentDeviceUIDs == [fix.device.uid])
        #expect(standby.tapSourceDeviceUID == nil)

        fix.engine.setDeviceRoutingForInactive(
            identifier: fix.app.persistenceIdentifier,
            deviceUID: nil
        )
        for _ in 0..<20 { await Task.yield() }
        #expect(standby.tapSourceDeviceUID == fix.device.uid)
    }

    @Test("Inactive volume edits refresh loudness compensation on a standby tap")
    func inactiveVolumeRefreshesLoudnessCompensation() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        var appSettings = fix.settings.appSettings
        appSettings.loudnessCompensationEnabled = true
        fix.settings.updateAppSettings(appSettings)
        fix.settings.setVolume(for: fix.app.persistenceIdentifier, to: 0.1)
        fix.engine.pinApp(fix.app)
        let standby = try #require(fix.lastTap())

        fix.engine.setVolumeForInactive(
            identifier: fix.app.persistenceIdentifier,
            to: 0.2
        )

        #expect(standby.events.contains {
            if case let .updateLoudnessCompensation(volume, enabled) = $0 {
                return enabled && abs(volume - 0.15) < 0.000_001
            }
            return false
        })
    }

    @Test("Unpinning an absent app with no saved processing retires its standby tap")
    func unpinRetiresUnneededStandbyTap() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        fix.engine.pinApp(fix.app)
        let standby = try #require(fix.lastTap())

        fix.engine.unpinApp(fix.app.persistenceIdentifier)

        #expect(standby.events.contains(.invalidate))
        #expect(!fix.settings.isPinned(fix.app.persistenceIdentifier))
    }

    @Test("A global default volume does not retain every unpinned app aggregate forever")
    func globalDefaultsDoNotRetainAbsentStandby() throws {
        let fix = makeFixture(enableColdStartPrearming: true)
        fix.processMonitor.activeApps = []
        fix.processMonitor.connectedApps = []
        var appSettings = fix.settings.appSettings
        appSettings.defaultNewAppVolume = 0.5
        fix.settings.updateAppSettings(appSettings)
        fix.engine.pinApp(fix.app)
        let standby = try #require(fix.lastTap())

        fix.engine.unpinApp(fix.app.persistenceIdentifier)

        #expect(standby.events.contains(.invalidate))
    }

    @Test("Per-app gain and mute round-trips to defaults do not leak warm aggregates")
    func resetOverridesDoNotRetainAbsentStandby() throws {
        let volumeFix = makeFixture(enableColdStartPrearming: true)
        volumeFix.processMonitor.activeApps = []
        volumeFix.processMonitor.connectedApps = []
        volumeFix.settings.setVolume(for: volumeFix.app.persistenceIdentifier, to: 0.2)
        volumeFix.settings.setVolume(for: volumeFix.app.persistenceIdentifier, to: 1.0)
        volumeFix.engine.pinApp(volumeFix.app)
        let volumeTap = try #require(volumeFix.lastTap())
        volumeFix.engine.unpinApp(volumeFix.app.persistenceIdentifier)
        #expect(volumeTap.events.contains(.invalidate))

        let muteFix = makeFixture(enableColdStartPrearming: true)
        muteFix.processMonitor.activeApps = []
        muteFix.processMonitor.connectedApps = []
        muteFix.settings.setMute(for: muteFix.app.persistenceIdentifier, to: true)
        muteFix.settings.setMute(for: muteFix.app.persistenceIdentifier, to: false)
        muteFix.engine.pinApp(muteFix.app)
        let muteTap = try #require(muteFix.lastTap())
        muteFix.engine.unpinApp(muteFix.app.persistenceIdentifier)
        #expect(muteTap.events.contains(.invalidate))

        let boostFix = makeFixture(enableColdStartPrearming: true)
        boostFix.processMonitor.activeApps = []
        boostFix.processMonitor.connectedApps = []
        boostFix.settings.setBoost(for: boostFix.app.persistenceIdentifier, to: .x2)
        boostFix.settings.setBoost(for: boostFix.app.persistenceIdentifier, to: .x1)
        boostFix.engine.pinApp(boostFix.app)
        let boostTap = try #require(boostFix.lastTap())
        boostFix.engine.unpinApp(boostFix.app.persistenceIdentifier)
        #expect(boostTap.events.contains(.invalidate))
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

    @Test("Persisted app and device AU graphs are published before AudioDeviceStart")
    func auGraphsAttachBeforeActivation() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        #expect(tap.startupEvents == [.attachAppAU, .attachDeviceAU, .activate])
    }

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
            case .activate, .rebind, .invalidate, .invalidateForHandoff:
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
