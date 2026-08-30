// FineTuneTests/SettingsManagerTests.swift
// Tests for SettingsManager.Settings JSON round-trip, merge algorithm, and pruning.
// Uses temp directories — no real settings files affected.

import Testing
import Foundation
@testable import FineTune

// MARK: - Settings JSON Round-Trip

@Suite("SettingsManager.Settings — JSON serialization")
@MainActor
struct SettingsJSONTests {

    @Test("Default Settings encodes and decodes to equal value")
    func defaultRoundTrip() throws {
        let original = SettingsManager.Settings()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == original.version)
        #expect(decoded.appVolumes == original.appVolumes)
        #expect(decoded.appMutes == original.appMutes)
        #expect(decoded.systemSoundsFollowsDefault == original.systemSoundsFollowsDefault)
    }

    @Test("Populated Settings round-trips all fields")
    func populatedRoundTrip() throws {
        var original = SettingsManager.Settings()
        original.appVolumes = ["com.test.app": 0.5]
        original.appMutes = ["com.test.app": true]
        original.appBoosts = ["com.test.app": 2.0]
        original.appDeviceRouting = ["com.test.app": "device-uid-123"]
        original.pinnedApps = Set(["com.test.app"])
        original.pinnedAppInfo = [
            "com.test.app": PinnedAppInfo(
                persistenceIdentifier: "com.test.app",
                displayName: "Test App",
                bundleID: "com.test.app"
            )
        ]
        original.appAUEffectChains = ["com.test.app": [consoleEntry()]]
        original.appMixerStripSlots = ["com.test.app": 1]
        original.outputDevicePriority = ["uid-a", "uid-b", "uid-c"]
        original.ddcVolumes = ["monitor-1": 75]
        original.ddcMuteStates = ["monitor-1": false]
        original.autoEQPreampEnabled = false
        original.hiddenOutputDeviceUIDs = ["uid-hidden-out-1", "uid-hidden-out-2"]
        original.hiddenInputDeviceUIDs = ["uid-hidden-in-1"]
        original.deviceIconOverrides = ["uid-a": "airpodsmax", "uid-b": "gamecontroller.fill"]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        #expect(decoded.appVolumes == original.appVolumes)
        #expect(decoded.appMutes == original.appMutes)
        #expect(decoded.appBoosts == original.appBoosts)
        #expect(decoded.appDeviceRouting == original.appDeviceRouting)
        #expect(decoded.pinnedApps == original.pinnedApps)
        #expect(decoded.appMixerStripSlots == original.appMixerStripSlots)
        #expect(decoded.outputDevicePriority == original.outputDevicePriority)
        #expect(decoded.ddcVolumes == original.ddcVolumes)
        #expect(decoded.ddcMuteStates == original.ddcMuteStates)
        #expect(decoded.autoEQPreampEnabled == false)
        #expect(decoded.hiddenOutputDeviceUIDs == original.hiddenOutputDeviceUIDs)
        #expect(decoded.hiddenInputDeviceUIDs == original.hiddenInputDeviceUIDs)
        #expect(decoded.deviceIconOverrides == original.deviceIconOverrides)
    }

    @Test("Decoding empty JSON produces valid defaults")
    func emptyJSONDefaults() throws {
        let json = "{}"
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == 13)
        #expect(decoded.appVolumes.isEmpty)
        #expect(decoded.appMutes.isEmpty)
        #expect(decoded.systemSoundsFollowsDefault == true)
        #expect(decoded.autoEQPreampEnabled == true)
        #expect(decoded.hiddenOutputDeviceUIDs.isEmpty)
        #expect(decoded.hiddenInputDeviceUIDs.isEmpty)
        #expect(decoded.deviceIconOverrides.isEmpty)
    }

    @Test("Decoding with extra unknown keys is tolerated")
    func unknownKeysIgnored() throws {
        let json = """
        {"version": 9, "unknownField": "hello", "anotherNew": 42}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.version == 13)
    }

    @Test("Volume values above 1.0 are clamped to 1.0 on decode")
    func volumeClampedAboveOne() throws {
        let json = """
        {"appVolumes": {"com.test.app": 1.5, "com.other.app": 0.8}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appVolumes["com.test.app"] == 1.0)
        #expect(decoded.appVolumes["com.other.app"] == 0.8)
    }

    @Test("Negative volume values are filtered out on decode")
    func negativeVolumesFiltered() throws {
        let json = """
        {"appVolumes": {"com.test.app": -0.5, "com.good.app": 0.7}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appVolumes["com.test.app"] == nil, "Negative volume should be filtered out")
        #expect(decoded.appVolumes["com.good.app"] == 0.7)
    }

    @Test("Non-finite volume values cannot be encoded to JSON")
    func nonFiniteVolumesCannotEncode() throws {
        // JSON spec does not support NaN or Infinity.
        // JSONEncoder throws when encountering non-finite floats.
        // This verifies the boundary: production code's filter on decode handles
        // finite-but-invalid values (negative, >1.0); non-finite values are
        // prevented at the encoding layer.
        var settings = SettingsManager.Settings()
        settings.appVolumes["inf_app"] = Float.infinity

        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(settings)
        }
    }

    @Test("Invalid defaultNewAppVolume is reset to 1.0 on decode")
    func invalidDefaultVolumeReset() throws {
        // AppSettings uses auto-synthesized Codable — all keys required.
        // MenuBarIconStyle raw value is capitalized ("Default", not "default").
        let json = """
        {"appSettings": {"launchAtLogin": false, "menuBarIconStyle": "Default", "defaultNewAppVolume": -5.0, "lockInputDevice": true, "showDeviceDisconnectAlerts": true}}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(decoded.appSettings.defaultNewAppVolume == 1.0,
                "Negative defaultNewAppVolume should be reset to 1.0")
    }

    @Test("Decoding an older schema upgrades the encoded version to 13")
    func oldSchemaUpgradesVersion() throws {
        let decoded = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: Data(#"{"version":12}"#.utf8)
        )
        #expect(decoded.version == 13)
        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["version"] as? Int == 13)
    }

    @Test("Schema 13 removes legacy Console 1 entries from device AU chains")
    func legacyDeviceConsoleIsRemoved() throws {
        var legacy = SettingsManager.Settings()
        let generic = AUEffectChainEntry(plugin: AUPluginDescriptor(
            componentType: 0x6175_6678,
            componentSubType: 0x6465_6C79,
            componentManufacturer: 0x6170_706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        ))
        legacy.deviceAUEffectChains = [
            "mixed-device": [consoleEntry(), generic],
            "console-only-device": [consoleEntry()],
        ]

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        #expect(decoded.deviceAUEffectChains["mixed-device"]?.map(\.id) == [generic.id])
        #expect(decoded.deviceAUEffectChains["console-only-device"] == nil)
    }

    @Test("Schema 13 preserves only the first Console 1 in each legacy app chain")
    func legacyDuplicateAppConsolesAreRemoved() throws {
        var legacy = SettingsManager.Settings()
        legacy.version = 12
        let identifier = "com.test.legacy-console"
        let firstGeneric = genericEntry(name: "Before", subType: 0x6465_6C79)
        let firstConsole = consoleEntry()
        let secondGeneric = genericEntry(name: "After", subType: 0x6C70_6173)
        let duplicateConsole = consoleEntry()
        legacy.appAUEffectChains[identifier] = [
            firstGeneric,
            firstConsole,
            secondGeneric,
            duplicateConsole,
        ]
        legacy.pinnedApps = [identifier]
        legacy.appMixerStripSlots = [identifier: 9]

        let decoded = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: JSONEncoder().encode(legacy)
        )

        #expect(decoded.appAUEffectChains[identifier]?.map(\.id) == [
            firstGeneric.id,
            firstConsole.id,
            secondGeneric.id,
        ])
        #expect(decoded.appMixerStripSlots == [identifier: 1])
    }

    private func consoleEntry() -> AUEffectChainEntry {
        AUEffectChainEntry(plugin: consoleDescriptor())
    }

    private func consoleDescriptor() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: 0x6175_6678,
            componentSubType: 0x5363_5069,
            componentManufacturer: 0x5366_5462,
            name: "Console 1",
            manufacturer: "Softube",
            version: 1
        )
    }

    private func genericEntry(name: String, subType: UInt32) -> AUEffectChainEntry {
        AUEffectChainEntry(plugin: AUPluginDescriptor(
            componentType: 0x6175_6678,
            componentSubType: subType,
            componentManufacturer: 0x6170_706C,
            name: name,
            manufacturer: "Apple",
            version: 1
        ))
    }
}

// MARK: - Persistent Mixer Strip Slots

@Suite("SettingsManager — persistent mixer strip slots", .serialized)
@MainActor
struct MixerStripSlotTests {

    @Test("Pinning assigns the lowest free stable slot")
    func pinAssignsLowestFreeSlot() {
        let manager = makeManager()
        addConsole(to: "com.test.one", manager: manager)
        addConsole(to: "com.test.two", manager: manager)
        manager.pinApp("com.test.one", info: info("com.test.one", "One"))
        manager.pinApp("com.test.two", info: info("com.test.two", "Two"))

        #expect(manager.getMixerStripSlot(for: "com.test.one") == 1)
        #expect(manager.getMixerStripSlot(for: "com.test.two") == 2)
    }

    @Test("Moving to an occupied slot swaps the two apps")
    func occupiedSlotSwaps() {
        let manager = makeManager()
        addConsole(to: "com.test.one", manager: manager)
        addConsole(to: "com.test.two", manager: manager)
        manager.pinApp("com.test.one", info: info("com.test.one", "One"))
        manager.pinApp("com.test.two", info: info("com.test.two", "Two"))

        manager.setMixerStripSlot(1, for: "com.test.two")

        #expect(manager.getMixerStripSlot(for: "com.test.two") == 1)
        #expect(manager.getMixerStripSlot(for: "com.test.one") == 2)
    }

    @Test("Moving past the end clamps to the last contiguous track")
    func outOfRangeClampsToLastTrack() {
        let manager = makeManager()
        addConsole(to: "com.test.one", manager: manager)
        addConsole(to: "com.test.two", manager: manager)
        manager.pinApp("com.test.one", info: info("com.test.one", "One"))
        manager.pinApp("com.test.two", info: info("com.test.two", "Two"))

        manager.setMixerStripSlot(32, for: "com.test.one")

        #expect(manager.getMixerStripSlot(for: "com.test.one") == 2)
        #expect(manager.getMixerStripSlot(for: "com.test.two") == 1)
    }

    @Test("Legacy settings deterministically repair missing and duplicate slots")
    func decodingRepairsSlots() throws {
        var encoded = SettingsManager.Settings()
        encoded.pinnedApps = ["com.test.c", "com.test.b", "com.test.a"]
        encoded.appAUEffectChains = [
            "com.test.a": [consoleEntry()],
            "com.test.b": [consoleEntry()],
            "com.test.c": [consoleEntry()]
        ]
        encoded.appMixerStripSlots = [
            "com.test.a": 2,
            "com.test.b": 2,
            "com.test.c": 0,
            "com.unpinned": 1
        ]

        let decoded = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: JSONEncoder().encode(encoded)
        )

        #expect(decoded.appMixerStripSlots == [
            "com.test.a": 1,
            "com.test.b": 2,
            "com.test.c": 3
        ])
    }

    @Test("Decoding compacts slot gaps while preserving requested order")
    func decodingCompactsGaps() throws {
        var encoded = SettingsManager.Settings()
        encoded.pinnedApps = ["com.test.two", "com.test.one"]
        encoded.appAUEffectChains = [
            "com.test.one": [consoleEntry()],
            "com.test.two": [consoleEntry()]
        ]
        encoded.appMixerStripSlots = ["com.test.one": 5, "com.test.two": 12]

        let decoded = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: JSONEncoder().encode(encoded)
        )

        #expect(decoded.appMixerStripSlots == [
            "com.test.one": 1,
            "com.test.two": 2
        ])
    }

    @Test("Unpinning releases the slot for the next pinned app")
    func unpinReleasesSlot() {
        let manager = makeManager()
        addConsole(to: "com.test.one", manager: manager)
        addConsole(to: "com.test.two", manager: manager)
        manager.pinApp("com.test.one", info: info("com.test.one", "One"))
        manager.unpinApp("com.test.one")
        manager.pinApp("com.test.two", info: info("com.test.two", "Two"))

        #expect(manager.getMixerStripSlot(for: "com.test.two") == 1)
    }

    @Test("Unpinning compacts higher slots")
    func unpinCompactsHigherSlots() {
        let manager = makeManager()
        addConsole(to: "com.test.one", manager: manager)
        addConsole(to: "com.test.two", manager: manager)
        addConsole(to: "com.test.three", manager: manager)
        manager.pinApp("com.test.one", info: info("com.test.one", "One"))
        manager.pinApp("com.test.two", info: info("com.test.two", "Two"))
        manager.pinApp("com.test.three", info: info("com.test.three", "Three"))

        manager.unpinApp("com.test.two")

        #expect(manager.getMixerStripSlot(for: "com.test.one") == 1)
        #expect(manager.getMixerStripSlot(for: "com.test.three") == 2)
    }

    @Test("Pinned apps without exactly one eligible Console 1 do not consume positions")
    func onlyEligibleConsoleStripsReceiveSlots() {
        let manager = makeManager()
        manager.pinApp("com.test.empty", info: info("com.test.empty", "Empty"))
        manager.setAUEffectChain(
            [AUEffectChainEntry(plugin: genericDescriptor())],
            for: "com.test.generic"
        )
        manager.pinApp("com.test.generic", info: info("com.test.generic", "Generic"))
        addConsole(to: "com.test.console", manager: manager)
        manager.pinApp("com.test.console", info: info("com.test.console", "Console"))

        #expect(manager.getMixerStripSlot(for: "com.test.empty") == nil)
        #expect(manager.getMixerStripSlot(for: "com.test.generic") == nil)
        #expect(manager.getMixerStripSlot(for: "com.test.console") == 1)
        #expect(manager.mixerStripSlots.count == 1)
    }

    @Test("A user-disabled Console 1 keeps its startup position, quarantine releases it")
    func disabledConsoleKeepsSlotUnlessQuarantined() {
        let manager = makeManager()
        var entry = consoleEntry()
        entry.isEnabled = false
        manager.setAUEffectChain([entry], for: "com.test.console")
        manager.pinApp("com.test.console", info: info("com.test.console", "Console"))

        #expect(manager.getMixerStripSlot(for: "com.test.console") == 1)

        entry.isCrashQuarantined = true
        manager.setAUEffectChain([entry], for: "com.test.console")
        #expect(manager.getMixerStripSlot(for: "com.test.console") == nil)
    }

    @Test("Runtime app-chain commits preserve the first Console 1 and its strip slot")
    func runtimeDuplicateConsolesAreRemoved() {
        let manager = makeManager()
        let identifier = "com.test.duplicate-console"
        let firstConsole = consoleEntry()
        let generic = AUEffectChainEntry(plugin: genericDescriptor())
        let duplicateConsole = consoleEntry()
        manager.pinApp(identifier, info: info(identifier, "Duplicate Console"))

        manager.setAUEffectChain(
            [firstConsole, generic, duplicateConsole],
            for: identifier
        )

        #expect(manager.getAUEffectChain(for: identifier).map(\.id) == [
            firstConsole.id,
            generic.id,
        ])
        #expect(manager.getMixerStripSlot(for: identifier) == 1)
    }

    private func makeManager() -> SettingsManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneMixerStripTests-\(UUID().uuidString)")
        return SettingsManager(directory: directory)
    }

    private func info(_ identifier: String, _ displayName: String) -> PinnedAppInfo {
        PinnedAppInfo(
            persistenceIdentifier: identifier,
            displayName: displayName,
            bundleID: identifier
        )
    }

    private func addConsole(to identifier: String, manager: SettingsManager) {
        manager.setAUEffectChain([consoleEntry()], for: identifier)
    }

    private func consoleEntry() -> AUEffectChainEntry {
        AUEffectChainEntry(plugin: consoleDescriptor())
    }

    private func consoleDescriptor() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: 0x6175_6678,
            componentSubType: 0x5363_5069,
            componentManufacturer: 0x5366_5462,
            name: "Console 1",
            manufacturer: "Softube",
            version: 1
        )
    }

    private func genericDescriptor() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: 0x6175_6678,
            componentSubType: 0x6465_6C79,
            componentManufacturer: 0x6170_706C,
            name: "Delay",
            manufacturer: "Apple",
            version: 1
        )
    }
}

// MARK: - mergePriorityOrder

@Suite("SettingsManager — mergePriorityOrder algorithm")
@MainActor
struct MergePriorityOrderTests {

    @Test("No disconnected devices: returns connectedOrder as-is")
    func noDisconnected() {
        let old = ["A", "B", "C"]
        let connected = ["C", "A", "B"] // user reordered
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        #expect(result == ["C", "A", "B"])
    }

    @Test("Disconnected device anchored between two connected devices")
    func disconnectedBetween() {
        let old = ["A", "D", "B"] // D is disconnected (not in connectedOrder)
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D was after A in old, so anchored to A. Result: A, D, B
        #expect(result == ["A", "D", "B"])
    }

    @Test("Disconnected device at the beginning (no preceding connected device)")
    func disconnectedAtStart() {
        let old = ["D", "A", "B"] // D is disconnected, before all connected
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D has nil anchor → inserted at front
        #expect(result == ["D", "A", "B"])
    }

    @Test("Multiple disconnected devices with same anchor")
    func multipleDisconnectedSameAnchor() {
        let old = ["A", "D1", "D2", "B"]
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        #expect(result == ["A", "D1", "D2", "B"])
    }

    @Test("All devices disconnected: returns disconnected in old order")
    func allDisconnected() {
        let old = ["A", "B", "C"]
        let connected: [String] = []
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // All disconnected, anchored to nil → inserted at front in order
        #expect(result == ["A", "B", "C"])
    }

    @Test("Empty old priority: returns connectedOrder")
    func emptyOldPriority() {
        let result = SettingsManager.mergePriorityOrder(oldPriority: [], connectedOrder: ["X", "Y"])
        #expect(result == ["X", "Y"])
    }

    @Test("Both empty: returns empty")
    func bothEmpty() {
        let result = SettingsManager.mergePriorityOrder(oldPriority: [], connectedOrder: [])
        #expect(result.isEmpty)
    }

    @Test("Reordering connected devices preserves disconnected anchors")
    func reorderPreservesAnchors() {
        let old = ["A", "D1", "B", "D2", "C"]
        let connected = ["C", "A", "B"] // user moved C to front
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D1 anchored to A, D2 anchored to B
        // Result: C, A, D1, B, D2
        #expect(result == ["C", "A", "D1", "B", "D2"])
    }

    @Test("Disconnected device at end (anchored to last connected)")
    func disconnectedAtEnd() {
        let old = ["A", "B", "D"]
        let connected = ["A", "B"]
        let result = SettingsManager.mergePriorityOrder(oldPriority: old, connectedOrder: connected)
        // D anchored to B → after B
        #expect(result == ["A", "B", "D"])
    }
}

// MARK: - Serialized Settings Writes

@Suite("SettingsManager — serialized disk writes", .serialized)
@MainActor
struct SettingsManagerSerializedWriteTests {

    @Test("flushSync writes the latest snapshot after an older queued save")
    func finalFlushWinsOverQueuedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneSerializedWriteTests-\(UUID().uuidString)")
        let writeQueue = DispatchQueue(label: "FineTuneSerializedWriteTests.blocked-write")
        writeQueue.suspend()
        let manager = SettingsManager(directory: directory, saveQueue: writeQueue)
        manager.setVolume(for: "com.test.app", to: 0.2)

        // Let the first debounce enqueue its stale snapshot behind the suspended queue.
        try await Task.sleep(for: .milliseconds(650))
        manager.setVolume(for: "com.test.app", to: 0.9)

        let resumer = Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            writeQueue.resume()
        }
        #expect(manager.flushSync())
        await resumer.value

        let reloaded = SettingsManager(directory: directory)
        #expect(reloaded.getVolume(for: "com.test.app") == 0.9)
    }
}

// MARK: - AppSettings Defaults

@Suite("AppSettings — Default values")
struct AppSettingsDefaultTests {

    @Test("Default AppSettings has expected values")
    func defaults() {
        let settings = AppSettings()
        #expect(settings.launchAtLogin == false)
        #expect(settings.menuBarIconStyle == .default)
        #expect(settings.defaultNewAppVolume == 1.0)
        #expect(settings.lockInputDevice == true)
        #expect(settings.showDeviceDisconnectAlerts == true)
    }

    @Test("loudnessEqualizationEnabled defaults to false")
    func loudnessEqualizationEnabledDefault() {
        let settings = AppSettings()
        #expect(settings.loudnessEqualizationEnabled == false)
    }

    @Test("loudnessEqualizationEnabled round-trips through JSON as true")
    func loudnessEqualizationEnabledRoundTrip() throws {
        var settings = AppSettings()
        settings.loudnessEqualizationEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.loudnessEqualizationEnabled == true)
    }

    @Test("Unified loudness toggle updates compensation and equalization together")
    func unifiedLoudnessToggleSetsBothFlags() {
        var settings = AppSettings()

        settings.setUnifiedLoudnessEnabled(true)
        #expect(settings.loudnessCompensationEnabled == true)
        #expect(settings.loudnessEqualizationEnabled == true)

        settings.setUnifiedLoudnessEnabled(false)
        #expect(settings.loudnessCompensationEnabled == false)
        #expect(settings.loudnessEqualizationEnabled == false)
    }

    @Test("loudnessEqualizationEnabled persists via SettingsManager")
    @MainActor
    func loudnessEqualizationEnabledPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let manager = SettingsManager(directory: tempDir)
        var newSettings = manager.appSettings
        newSettings.loudnessEqualizationEnabled = true
        manager.updateAppSettings(newSettings)
        #expect(manager.appSettings.loudnessEqualizationEnabled == true)
    }

    @Test("volumeHotkeyStep defaults to .normal")
    func volumeHotkeyStepDefault() {
        let settings = AppSettings()
        #expect(settings.volumeHotkeyStep == .normal)
    }

    @Test("volumeHotkeyStep round-trips through JSON")
    func volumeHotkeyStepRoundTrip() throws {
        var settings = AppSettings()
        settings.volumeHotkeyStep = .fine
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.volumeHotkeyStep == .fine)
    }

    @Test("Missing volumeHotkeyStep key decodes to .normal")
    func volumeHotkeyStepMissingKeyDefault() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.volumeHotkeyStep == .normal)
    }

}

// MARK: - Hidden Devices

@Suite("SettingsManager — hidden device UIDs")
@MainActor
struct SettingsManagerHiddenDevicesTests {

    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    @Test("hideOutputDevice / unhideOutputDevice / isOutputDeviceHidden round-trip")
    func outputHideUnhideParity() {
        let m = makeManager()
        let uid = "uid-output-1"

        #expect(m.isOutputDeviceHidden(uid) == false)
        m.hideOutputDevice(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == true)
        #expect(m.hiddenOutputDeviceUIDs.contains(uid))
        m.unhideOutputDevice(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == false)
        #expect(m.hiddenOutputDeviceUIDs.contains(uid) == false)
    }

    @Test("hideInputDevice / unhideInputDevice / isInputDeviceHidden round-trip")
    func inputHideUnhideParity() {
        let m = makeManager()
        let uid = "uid-input-1"

        #expect(m.isInputDeviceHidden(uid) == false)
        m.hideInputDevice(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == true)
        m.unhideInputDevice(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == false)
    }

    @Test("toggleOutputDeviceHidden flips based on persisted state")
    func toggleOutputFlipsFromPersisted() {
        let m = makeManager()
        let uid = "uid-output-2"

        m.toggleOutputDeviceHidden(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == true)
        m.toggleOutputDeviceHidden(uid: uid)
        #expect(m.isOutputDeviceHidden(uid) == false)
    }

    @Test("toggleInputDeviceHidden flips based on persisted state")
    func toggleInputFlipsFromPersisted() {
        let m = makeManager()
        let uid = "uid-input-2"

        m.toggleInputDeviceHidden(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == true)
        m.toggleInputDeviceHidden(uid: uid)
        #expect(m.isInputDeviceHidden(uid) == false)
    }

    @Test("Hidden output and input sets are independent")
    func outputAndInputSetsIndependent() {
        let m = makeManager()
        m.hideOutputDevice(uid: "shared-uid")
        #expect(m.isOutputDeviceHidden("shared-uid") == true)
        #expect(m.isInputDeviceHidden("shared-uid") == false)
    }
}

// MARK: - Device Icon Override API

@Suite("SettingsManager — deviceIconOverrides API")
@MainActor
struct DeviceIconOverrideTests {
    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    @Test("get/set round-trip for a single UID")
    func setAndGet() {
        let manager = makeManager()
        #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)

        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        #expect(manager.getDeviceIconOverride(for: "uid-a") == "airpodsmax")

        manager.setDeviceIconOverride(for: "uid-a", to: "gamecontroller.fill")
        #expect(manager.getDeviceIconOverride(for: "uid-a") == "gamecontroller.fill")
    }

    @Test("Passing nil clears the override")
    func clearOverride() {
        let manager = makeManager()
        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        #expect(manager.getDeviceIconOverride(for: "uid-a") == "airpodsmax")

        manager.setDeviceIconOverride(for: "uid-a", to: nil)
        #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)
    }

    @Test("Overrides for different UIDs are independent")
    func independentPerUID() {
        let manager = makeManager()
        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        manager.setDeviceIconOverride(for: "uid-b", to: "gamecontroller.fill")

        #expect(manager.getDeviceIconOverride(for: "uid-a") == "airpodsmax")
        #expect(manager.getDeviceIconOverride(for: "uid-b") == "gamecontroller.fill")
        #expect(manager.deviceIconOverrides == ["uid-a": "airpodsmax", "uid-b": "gamecontroller.fill"])
    }

    @Test("resetAllSettings clears all overrides")
    func resetClearsOverrides() {
        let manager = makeManager()
        manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
        manager.setDeviceIconOverride(for: "uid-b", to: "gamecontroller.fill")

        manager.resetAllSettings()

        #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)
        #expect(manager.getDeviceIconOverride(for: "uid-b") == nil)
        #expect(manager.deviceIconOverrides.isEmpty)
    }
}

// MARK: - MenuBarIconStyle

@Suite("MenuBarIconStyle — Enumeration")
struct MenuBarIconStyleTests {

    @Test("allCases has 5 styles")
    func allCasesCount() {
        #expect(MenuBarIconStyle.allCases.count == 5)
    }

    @Test("Only 'default' is not a system symbol")
    func defaultNotSystemSymbol() {
        #expect(!MenuBarIconStyle.default.isSystemSymbol)
        #expect(MenuBarIconStyle.speaker.isSystemSymbol)
        #expect(MenuBarIconStyle.device.isSystemSymbol)
        #expect(MenuBarIconStyle.waveform.isSystemSymbol)
        #expect(MenuBarIconStyle.equalizer.isSystemSymbol)
    }

    @Test("Every style has a non-empty icon name")
    func allHaveIconNames() {
        for style in MenuBarIconStyle.allCases {
            #expect(!style.iconName.isEmpty, "Style \(style.rawValue) has empty icon name")
        }
    }

    @Test("Round-trip through JSON Codable")
    func codableRoundTrip() throws {
        for style in MenuBarIconStyle.allCases {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(MenuBarIconStyle.self, from: data)
            #expect(decoded == style)
        }
    }
}
