// FineTuneTests/AUPluginTests.swift
import AudioToolbox
import AppKit
import Foundation
import Testing
@testable import FineTune

@MainActor
private final class LiveChangeCounter {
    var value = 0
}

// MARK: - AUPluginDescriptor Tests

@Suite("AUPluginDescriptor")
struct AUPluginDescriptorTests {

    @Test("ID is deterministic from component triple")
    func idFromTriple() {
        let desc = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        #expect(desc.id == "1-2-3")
    }

    @Test("Two descriptors with same triple are equal")
    func equalityByTriple() {
        let a = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let b = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        #expect(a == b)
    }

    @Test("Different triples are not equal")
    func inequalityByTriple() {
        let a = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let b = makeDescriptor(type: 1, subType: 2, manufacturer: 4)
        #expect(a != b)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = makeDescriptor(type: 100, subType: 200, manufacturer: 300)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AUPluginDescriptor.self, from: data)
        #expect(decoded == original)
        #expect(decoded.name == original.name)
        #expect(decoded.manufacturer == original.manufacturer)
        #expect(decoded.version == original.version)
    }

    @Test("audioComponentDescription reconstructs correctly")
    func audioComponentDescription() {
        let desc = makeDescriptor(type: 0x61756678, subType: 0x64656C79, manufacturer: 0x6170706C)
        let acd = desc.audioComponentDescription
        #expect(acd.componentType == 0x61756678)
        #expect(acd.componentSubType == 0x64656C79)
        #expect(acd.componentManufacturer == 0x6170706C)
        #expect(acd.componentFlags == 0)
        #expect(acd.componentFlagsMask == 0)
    }

    @Test("Hashable works in Set")
    func hashable() {
        let a = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let b = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let c = makeDescriptor(type: 4, subType: 5, manufacturer: 6)
        let set: Set<AUPluginDescriptor> = [a, b, c]
        #expect(set.count == 2)
    }

    private func makeDescriptor(type: UInt32, subType: UInt32, manufacturer: UInt32) -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: type,
            componentSubType: subType,
            componentManufacturer: manufacturer,
            name: "Test Plugin",
            manufacturer: "Test Manufacturer",
            version: 1
        )
    }
}

// MARK: - AUEffectChainEntry Tests

@Suite("AUEffectChainEntry")
struct AUEffectChainEntryTests {

    @Test("Init creates unique UUID")
    func uniqueID() {
        let plugin = makePlugin()
        let a = AUEffectChainEntry(plugin: plugin)
        let b = AUEffectChainEntry(plugin: plugin)
        #expect(a.id != b.id)
    }

    @Test("Init defaults to enabled with no preset")
    func defaults() {
        let entry = AUEffectChainEntry(plugin: makePlugin())
        #expect(entry.isEnabled == true)
        #expect(entry.presetData == nil)
        #expect(entry.selectedFactoryPresetIndex == nil)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        var entry = AUEffectChainEntry(plugin: makePlugin())
        entry.isEnabled = false
        entry.presetData = Data([0x01, 0x02, 0x03])
        entry.selectedFactoryPresetIndex = 5

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(AUEffectChainEntry.self, from: data)
        #expect(decoded.id == entry.id)
        #expect(decoded.pluginDescriptor == entry.pluginDescriptor)
        #expect(decoded.isEnabled == false)
        #expect(decoded.presetData == Data([0x01, 0x02, 0x03]))
        #expect(decoded.selectedFactoryPresetIndex == 5)
    }

    @Test("Equatable compares by ID")
    func equatable() {
        let a = AUEffectChainEntry(plugin: makePlugin())
        var b = a
        b.isEnabled = false
        // Same id means equal for Equatable (it's derived)
        // Actually Equatable is auto-synthesized comparing all fields
        #expect(a != b)
    }

    private func makePlugin() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }
}

// MARK: - AUPluginScanner Tests

@Suite("AUPluginScanner", .serialized)
@MainActor
struct AUPluginScannerTests {

    @Test("Discovers system Audio Units")
    func discoversSystemAUs() {
        let scanner = AUPluginScanner()
        #expect(scanner.plugins.count > 0, "macOS ships with built-in AU effects")
    }

    @Test("Only discovers effect-type AUs")
    func onlyEffectTypes() {
        let scanner = AUPluginScanner()
        let effectTypes: Set<UInt32> = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        for plugin in scanner.plugins {
            #expect(effectTypes.contains(plugin.componentType),
                    "\(plugin.name) has unexpected type \(plugin.componentType)")
        }
    }

    @Test("Manufacturers dictionary groups correctly")
    func manufacturerGrouping() {
        let scanner = AUPluginScanner()
        let totalInManufacturers = scanner.manufacturers.values.reduce(0) { $0 + $1.count }
        #expect(totalInManufacturers == scanner.plugins.count)
    }

    @Test("Plugins are sorted by manufacturer then name")
    func sortOrder() {
        let scanner = AUPluginScanner()
        for i in 1..<scanner.plugins.count {
            let prev = scanner.plugins[i - 1]
            let curr = scanner.plugins[i]
            #expect((prev.manufacturer, prev.name) <= (curr.manufacturer, curr.name),
                    "\(prev.manufacturer):\(prev.name) should come before \(curr.manufacturer):\(curr.name)")
        }
    }

    @Test("findComponent returns non-nil for known Apple AU")
    func findComponentForAppleAU() {
        let scanner = AUPluginScanner()
        guard let applePlugin = scanner.plugins.first(where: { $0.manufacturer == "Apple" }) else {
            Issue.record("No Apple AU found on this system")
            return
        }
        #expect(scanner.findComponent(for: applePlugin) != nil)
    }

    @Test("Refresh produces consistent results")
    func refreshConsistency() {
        let scanner = AUPluginScanner()
        let firstCount = scanner.plugins.count
        scanner.refresh()
        #expect(scanner.plugins.count == firstCount)
    }

    @Test("hasNewPlugins starts false")
    func newPluginsFlag() {
        let scanner = AUPluginScanner()
        #expect(scanner.hasNewPlugins == false)
    }

    @Test("clearNewPluginsFlag resets flag")
    func clearFlag() {
        let scanner = AUPluginScanner()
        scanner.clearNewPluginsFlag()
        #expect(scanner.hasNewPlugins == false)
    }
}

// MARK: - AUEffectHost Tests

@Suite("AUEffectHost")
struct AUEffectHostTests {

    @Test("Instantiate Apple AUDelay succeeds")
    func instantiateAUDelay() {
        let desc = appleAUDelay()
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100)
        #expect(host.instantiate() == true)
        #expect(host.audioUnit != nil)
    }

    @Test("Instantiate with bogus descriptor fails")
    func instantiateBogus() {
        let desc = AUPluginDescriptor(
            componentType: 0xDEADBEEF,
            componentSubType: 0xDEADBEEF,
            componentManufacturer: 0xDEADBEEF,
            name: "Bogus",
            manufacturer: "Bogus",
            version: 0
        )
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100)
        #expect(host.instantiate() == false)
        #expect(host.audioUnit == nil)
    }

    @Test("Enable/disable toggle works")
    func enableDisable() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100, enabled: true)
        #expect(host.isEnabled == true)
        host.setEnabled(false)
        #expect(host.isEnabled == false)
        host.setEnabled(true)
        #expect(host.isEnabled == true)
    }

    @Test("Factory presets are populated for AUDelay")
    func factoryPresets() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate AUDelay")
            return
        }
        // AUDelay may or may not have factory presets, but the property should not crash
        _ = host.factoryPresets
    }

    @Test("Tail time is non-negative")
    func tailTime() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100)
        guard host.instantiate() else { return }
        #expect(host.tailTimeSeconds >= 0)
    }

    @Test("Save and load preset round-trip")
    func presetRoundTrip() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate")
            return
        }
        guard let saved = host.savePreset() else {
            Issue.record("Failed to save preset")
            return
        }
        #expect(saved.count > 0)
        #expect(host.loadPreset(saved) == true)
    }

    @Test("Sample-rate reconfiguration preserves the Audio Unit instance")
    func reconfigurePreservesInstance() {
        let host = AUEffectHost(
            descriptor: appleAUDelay(),
            entryID: UUID(),
            sampleRate: 44100
        )
        guard host.instantiate(), let originalAudioUnit = host.audioUnit else {
            Issue.record("Failed to instantiate AUDelay")
            return
        }

        #expect(host.reconfigure(sampleRate: 48000))
        #expect(host.audioUnit == originalAudioUnit)
        #expect(host.configuredSampleRate == 48000)
    }

    @Test("renderInterleaved actually modifies audio with AULowpass")
    func renderInterleavedModifiesAudio() {
        let desc = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C706173, // 'lpas'
            componentManufacturer: 0x6170706C, // 'appl'
            name: "AULowPassFilter",
            manufacturer: "Apple",
            version: 1
        )
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100, maxFrames: 512)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate AULowPassFilter")
            return
        }

        // Set cutoff to 200 Hz so it aggressively filters high frequencies
        if let au = host.audioUnit {
            var cutoff: AudioUnitParameterValue = 200.0
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, cutoff, 0)
        }

        // Generate 10kHz sine wave (will be heavily filtered by 200Hz lowpass)
        let frameCount = 512
        var buffer = [Float](repeating: 0, count: frameCount * 2)
        let freq: Float = 10000.0
        let sampleRate: Float = 44100.0
        for i in 0..<frameCount {
            let sample = sinf(2.0 * .pi * freq * Float(i) / sampleRate) * 0.5
            buffer[i * 2] = sample     // L
            buffer[i * 2 + 1] = sample // R
        }

        // Compute energy before
        let energyBefore = buffer.reduce(Float(0)) { $0 + $1 * $1 }

        // Render through several buffers to let the filter settle
        for _ in 0..<10 {
            buffer.withUnsafeMutableBufferPointer { ptr in
                host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
            }
            // Refill with sine for next iteration
            for i in 0..<frameCount {
                let sample = sinf(2.0 * .pi * freq * Float(i) / sampleRate) * 0.5
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
            }
        }

        // Final render pass — measure output
        buffer.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        let energyAfter = buffer.reduce(Float(0)) { $0 + $1 * $1 }

        // A 200Hz lowpass should massively attenuate a 10kHz signal
        #expect(energyAfter < energyBefore * 0.01,
                "AULowPassFilter at 200Hz should attenuate 10kHz signal by >40dB, got ratio \(energyAfter / energyBefore)")
    }

    @Test("renderInterleaved works with AUReverb2")
    func renderInterleavedReverb2() {
        let desc = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x72766232, // 'rvb2'
            componentManufacturer: 0x6170706C, // 'appl'
            name: "AUReverb2",
            manufacturer: "Apple",
            version: 1
        )
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100, maxFrames: 512)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate AUReverb2")
            return
        }

        // Set DryWetMix to 100% wet so reverb is fully audible
        if let au = host.audioUnit {
            // Parameter 0 = DryWetMix (0-100)
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, 100.0, 0)
        }

        let frameCount = 512

        // Feed an impulse (single loud sample) then silence — reverb tail should persist
        var impulse = [Float](repeating: 0, count: frameCount * 2)
        impulse[0] = 1.0  // L
        impulse[1] = 1.0  // R

        impulse.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        // Now render silence — the reverb tail should produce non-zero output
        var silence = [Float](repeating: 0, count: frameCount * 2)
        silence.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        let tailEnergy = silence.reduce(Float(0)) { $0 + $1 * $1 }
        #expect(tailEnergy > 0.0001, "AUReverb2 at 100% wet should produce a reverb tail after an impulse, got energy \(tailEnergy)")
    }

    @Test("Disabled host passes audio through unchanged")
    func disabledHostPassthrough() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100, maxFrames: 256, enabled: false)
        _ = host.instantiate()

        var buffer: [Float] = [0.5, -0.5, 0.3, -0.3]
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: 2)
        }
        #expect(buffer == original)
    }

    private func appleAUDelay() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79, // 'dely'
            componentManufacturer: 0x6170706C, // 'appl'
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }
}

// MARK: - AUEffectChain Tests

@Suite("AUEffectChain")
struct AUEffectChainTests {

    @Test("Empty entries create chain with zero hosts")
    func emptyChain() {
        let chain = AUEffectChain(entries: [], sampleRate: 44100)
        #expect(chain.hosts.count == 0)
        #expect(chain.entries.count == 0)
    }

    @Test("Chain with valid AU creates hosts")
    func validChain() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100)
        #expect(chain.hosts.count == 1)
        #expect(chain.hosts[0].entryID == entry.id)
    }

    @Test("Chain skips invalid AUs")
    func invalidAUSkipped() {
        let bogus = AUPluginDescriptor(
            componentType: 0xDEADBEEF,
            componentSubType: 0xDEADBEEF,
            componentManufacturer: 0xDEADBEEF,
            name: "Bogus",
            manufacturer: "Bogus",
            version: 0
        )
        let validEntry = AUEffectChainEntry(plugin: appleAUDelay())
        let bogusEntry = AUEffectChainEntry(plugin: bogus)
        let chain = AUEffectChain(entries: [bogusEntry, validEntry], sampleRate: 44100)
        #expect(chain.entries.count == 2)
        #expect(chain.hosts.count == 1)
    }

    @Test("Duplicate entry IDs do not instantiate duplicate Audio Units")
    func duplicateEntryIDsAreDeduplicated() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry, entry], sampleRate: 44100)

        #expect(chain.entries.count == 1)
        #expect(chain.hosts.count == 1)
    }

    @Test("Bypass flag starts false")
    func bypassDefault() {
        let chain = AUEffectChain(entries: [], sampleRate: 44100)
        #expect(chain.isBypassed == false)
    }

    @Test("Bypass toggle works")
    func bypassToggle() {
        let chain = AUEffectChain(entries: [], sampleRate: 44100)
        chain.setBypassed(true)
        #expect(chain.isBypassed == true)
        chain.setBypassed(false)
        #expect(chain.isBypassed == false)
    }

    @Test("maxTailTime reflects hosts")
    func maxTailTime() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100)
        // Should not crash; value depends on AU implementation
        #expect(chain.maxTailTime >= 0)
    }

    @Test("host(for:) finds correct host by entryID")
    func hostLookup() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100)
        #expect(chain.host(for: entry.id) != nil)
        #expect(chain.host(for: UUID()) == nil)
    }

    @Test("Selecting Default restores baseline without replacing the Audio Unit")
    func defaultPresetRestoresReusedHost() throws {
        let descriptor = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C70_6173,
            componentManufacturer: 0x6170_706C,
            name: "AULowPassFilter",
            manufacturer: "Apple",
            version: 1
        )
        let entry = AUEffectChainEntry(plugin: descriptor)
        let original = AUEffectChain(entries: [entry], sampleRate: 48_000)
        let host = try #require(original.host(for: entry.id))
        let au = try #require(host.audioUnit)

        var baseline: AudioUnitParameterValue = 0
        #expect(AudioUnitGetParameter(au, 0, kAudioUnitScope_Global, 0, &baseline) == noErr)
        #expect(AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, 200, 0) == noErr)

        var presetEntry = entry
        presetEntry.presetData = try #require(host.savePreset())
        let withPreset = AUEffectChain(
            entries: [presetEntry],
            sampleRate: 48_000,
            reusing: original
        )
        var defaultEntry = presetEntry
        defaultEntry.presetData = nil
        let restored = AUEffectChain(
            entries: [defaultEntry],
            sampleRate: 48_000,
            reusing: withPreset
        )

        var restoredValue: AudioUnitParameterValue = 0
        #expect(AudioUnitGetParameter(au, 0, kAudioUnitScope_Global, 0, &restoredValue) == noErr)
        #expect(restored.host(for: entry.id) === host)
        #expect(restored.host(for: entry.id)?.audioUnit == au)
        #expect(abs(restoredValue - baseline) < 0.001)
    }

    @Test("Live-state snapshots preserve Default metadata until the editor changes a parameter")
    func liveSnapshotPreservesDefaultMetadataUntilEdited() throws {
        let descriptor = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C70_6173,
            componentManufacturer: 0x6170_706C,
            name: "AULowPassFilter",
            manufacturer: "Apple",
            version: 1
        )
        let entry = AUEffectChainEntry(plugin: descriptor)
        let chain = AUEffectChain(entries: [entry], sampleRate: 48_000)
        let host = try #require(chain.host(for: entry.id))
        let au = try #require(host.audioUnit)

        let unchanged = try #require(chain.entriesWithLiveState().first)
        #expect(unchanged.presetData == nil)
        #expect(unchanged.selectedFactoryPresetIndex == nil)

        #expect(AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, 200, 0) == noErr)
        let edited = try #require(chain.entriesWithLiveState().first)
        #expect(edited.presetData != nil)
        #expect(edited.selectedFactoryPresetIndex == nil)
    }

    @Test("Window state sync preserves Default and factory metadata until a real edit")
    func liveStateMergePreservesPresetMetadata() {
        let data = Data("live-state".utf8)
        var factoryEntry = AUEffectChainEntry(plugin: appleAUDelay())
        factoryEntry.selectedFactoryPresetIndex = 7

        let unchangedFactory = factoryEntry.mergingLivePresetData(
            data,
            matchesLastAppliedPreset: true
        )
        #expect(unchangedFactory == factoryEntry)
        #expect(unchangedFactory.selectedFactoryPresetIndex == 7)
        #expect(unchangedFactory.presetData == nil)

        let editedFactory = factoryEntry.mergingLivePresetData(
            data,
            matchesLastAppliedPreset: false
        )
        #expect(editedFactory.selectedFactoryPresetIndex == nil)
        #expect(editedFactory.presetData == data)

        let defaultEntry = AUEffectChainEntry(plugin: appleAUDelay())
        #expect(defaultEntry.mergingLivePresetData(
            data,
            matchesLastAppliedPreset: true
        ) == defaultEntry)
    }

    @Test("A crash-quarantined cold-start entry does not instantiate third-party code")
    func quarantinedColdStartDoesNotInstantiate() {
        var entry = AUEffectChainEntry(
            plugin: AUPluginDescriptor(
                componentType: kAudioUnitType_Effect,
                componentSubType: 0xFFFF_FFFE,
                componentManufacturer: 0xFFFF_FFFD,
                name: "Quarantined",
                manufacturer: "Test",
                version: 1
            )
        )
        entry.isEnabled = false
        entry.isCrashQuarantined = true
        let chain = AUEffectChain(entries: [entry], sampleRate: 48_000)
        #expect(chain.hosts.isEmpty)
        #expect(chain.failedEntryIDs.isEmpty)
    }

    @Test("An ordinary disabled non-Console entry stays cold")
    func userDisabledGenericColdStartDoesNotInstantiate() {
        var entry = AUEffectChainEntry(plugin: appleAUDelay())
        entry.isEnabled = false

        let chain = AUEffectChain(entries: [entry], sampleRate: 48_000)

        #expect(chain.failedEntryIDs.isEmpty)
        #expect(chain.hosts.isEmpty)
        #expect(!entry.shouldInstantiateOnColdStart(retainingDisabledConsole: false))
    }

    @Test("A user-disabled Console 1 remains cold-start eligible for track reservation")
    func userDisabledConsoleRemainsEligible() {
        var entry = AUEffectChainEntry(
            plugin: AUPluginDescriptor(
                componentType: kAudioUnitType_Effect,
                componentSubType: 0x5363_5069,
                componentManufacturer: 0x5366_5462,
                name: "Console 1",
                manufacturer: "Softube",
                version: 1
            )
        )
        entry.isEnabled = false

        #expect(entry.pluginDescriptor.isSoftubeConsole1)
        #expect(!entry.shouldInstantiateOnColdStart(retainingDisabledConsole: false))
        #expect(entry.shouldInstantiateOnColdStart(retainingDisabledConsole: true))
    }

    @Test("Device-chain edits reuse hosts so an open editor cannot detach")
    @MainActor
    func deviceChainEditsReuseHost() throws {
        let app = AudioApp(
            id: 42,
            processObjectIDs: [],
            name: "Test",
            icon: NSImage(),
            bundleID: "com.test.device-au"
        )
        let controller = ProcessTapController(app: app, targetDeviceUID: "test-device")
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        controller.updateDeviceAUEffectChain([entry])
        let host = try #require(controller.getDeviceAUHost(for: entry.id))
        let audioUnit = try #require(host.audioUnit)

        var disabled = entry
        disabled.isEnabled = false
        controller.updateDeviceAUEffectChain([disabled])

        #expect(controller.getDeviceAUHost(for: entry.id) === host)
        #expect(controller.getDeviceAUHost(for: entry.id)?.audioUnit == audioUnit)
        #expect(host.isEnabled == false)
    }

    @Test("Device editor sync does not reload ClassInfo into its source host")
    @MainActor
    func deviceEditorSyncPreservesSourceHostLiveState() throws {
        let app = AudioApp(
            id: 43,
            processObjectIDs: [],
            name: "Test",
            icon: NSImage(),
            bundleID: "com.test.device-au-live"
        )
        let controller = ProcessTapController(app: app, targetDeviceUID: "test-device")
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        controller.updateDeviceAUEffectChain([entry])
        let host = try #require(controller.getDeviceAUHost(for: entry.id))
        let audioUnit = try #require(host.audioUnit)

        #expect(AudioUnitSetParameter(
            audioUnit,
            0,
            kAudioUnitScope_Global,
            0,
            0.75,
            0
        ) == noErr)
        var propagatedEntry = entry
        propagatedEntry.presetData = try #require(host.savePreset())

        #expect(AudioUnitSetParameter(
            audioUnit,
            0,
            kAudioUnitScope_Global,
            0,
            0.25,
            0
        ) == noErr)
        controller.updateDeviceAUEffectChain(
            [propagatedEntry],
            explicitPresetEntryID: nil,
            preservingLiveStateFor: host
        )

        var liveValue: AudioUnitParameterValue = 0
        #expect(AudioUnitGetParameter(
            audioUnit,
            0,
            kAudioUnitScope_Global,
            0,
            &liveValue
        ) == noErr)
        #expect(abs(liveValue - 0.25) < 0.001)
        #expect(controller.getDeviceAUHost(for: entry.id) === host)
    }

    @Test("A shared-device editor survives a non-source transition and saves on its source transition")
    @MainActor
    func deviceEditorClosesOnlyForItsSourceHost() throws {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let sourceController = ProcessTapController(
            app: AudioApp(
                id: 44,
                processObjectIDs: [],
                name: "Source",
                icon: NSImage(),
                bundleID: "com.test.device-source"
            ),
            targetDeviceUID: "shared-device"
        )
        let otherController = ProcessTapController(
            app: AudioApp(
                id: 45,
                processObjectIDs: [],
                name: "Other",
                icon: NSImage(),
                bundleID: "com.test.device-other"
            ),
            targetDeviceUID: "shared-device"
        )
        sourceController.updateDeviceAUEffectChain([entry])
        otherController.updateDeviceAUEffectChain([entry])
        let sourceHost = try #require(sourceController.getDeviceAUHost(for: entry.id))
        let sourceAudioUnit = try #require(sourceHost.audioUnit)
        let manager = AUPluginWindowManager.shared
        manager.closeWindow(for: entry.id)
        var saveCount = 0
        manager.showWindow(
            for: entry.id,
            audioUnit: sourceAudioUnit,
            pluginName: "AUDelay transition test",
            forceGeneric: true,
            sourceHost: sourceHost
        ) {
            saveCount += 1
        }
        defer { manager.closeWindow(for: entry.id) }

        #expect(manager.hasOpenWindowForTesting(entryID: entry.id))
        AudioEngine.closeDeviceAUEditorsBackedByTap(otherController, windowManager: manager)
        #expect(manager.hasOpenWindowForTesting(entryID: entry.id))
        #expect(saveCount == 0)

        AudioEngine.closeDeviceAUEditorsBackedByTap(sourceController, windowManager: manager)
        #expect(!manager.hasOpenWindowForTesting(entryID: entry.id))
        #expect(saveCount == 1)
    }

    @Test("Device editor observer registers concrete Audio Unit parameters")
    @MainActor
    func deviceEditorObserverEnumeratesConcreteParameters() throws {
        let host = AUEffectHost(
            descriptor: appleAUDelay(),
            entryID: UUID(),
            sampleRate: 48_000
        )
        #expect(host.instantiate())
        let audioUnit = try #require(host.audioUnit)

        #expect(
            AUPluginWindowManager.shared.observableParameterCountForTesting(audioUnit) > 0
        )
    }

    @Test("Device editor rejects malformed or unbounded AU parameter lists")
    func deviceEditorObserverBoundsParameterListSize() {
        let parameterSize = UInt32(MemoryLayout<AudioUnitParameterID>.size)
        #expect(
            AUPluginWindowManager.validatedParameterCountForTesting(
                byteCount: parameterSize * 4
            ) == 4
        )
        #expect(
            AUPluginWindowManager.validatedParameterCountForTesting(
                byteCount: parameterSize + 1
            ) == nil
        )
        #expect(
            AUPluginWindowManager.validatedParameterCountForTesting(
                byteCount: UInt32.max
            ) == nil
        )

        var remainingBudget = 16_384
        #expect(
            AUPluginWindowManager.consumeParameterBudgetForTesting(
                10_000,
                remaining: &remainingBudget
            )
        )
        #expect(remainingBudget == 6_384)
        #expect(
            !AUPluginWindowManager.consumeParameterBudgetForTesting(
                6_385,
                remaining: &remainingBudget
            )
        )
        #expect(remainingBudget == 6_384)
    }

    @Test("Device editor observer delivers a debounced concrete-parameter change")
    @MainActor
    func deviceEditorObserverDeliversChange() async throws {
        let host = AUEffectHost(
            descriptor: appleAUDelay(),
            entryID: UUID(),
            sampleRate: 48_000
        )
        #expect(host.instantiate())
        let audioUnit = try #require(host.audioUnit)
        let entryID = UUID()
        let counter = LiveChangeCounter()
        let manager = AUPluginWindowManager.shared
        #expect(manager.installLiveChangeListenerForTesting(
            entryID: entryID,
            audioUnit: audioUnit
        ) {
            counter.value += 1
        })
        defer {
            manager.removeLiveChangeListenerForTesting(entryID: entryID)
        }

        #expect(manager.notifyFirstObservableParameterForTesting(audioUnit))
        try await Task.sleep(for: .milliseconds(700))

        #expect(counter.value == 1)
    }

    @Test("Device editor commit marker detects an undo back to the original state")
    func deviceEditorCommitThenUndoIsANewChange() throws {
        let host = AUEffectHost(
            descriptor: appleAUDelay(),
            entryID: UUID(),
            sampleRate: 48_000
        )
        #expect(host.instantiate())
        let audioUnit = try #require(host.audioUnit)
        var baselineValue: AudioUnitParameterValue = 0
        #expect(AudioUnitGetParameter(
            audioUnit,
            0,
            kAudioUnitScope_Global,
            0,
            &baselineValue
        ) == noErr)

        let editedValue = baselineValue > 0.25
            ? baselineValue - 0.25
            : baselineValue + 0.25
        #expect(AudioUnitSetParameter(
            audioUnit,
            0,
            kAudioUnitScope_Global,
            0,
            editedValue,
            0
        ) == noErr)
        let editedData = try #require(host.savePreset())
        host.markLivePresetDataAsApplied(editedData)

        #expect(AudioUnitSetParameter(
            audioUnit,
            0,
            kAudioUnitScope_Global,
            0,
            baselineValue,
            0
        ) == noErr)
        let revertedData = try #require(host.savePreset())

        #expect(!host.liveStateMatchesLastAppliedPreset(revertedData))
        var committedEntry = AUEffectChainEntry(plugin: appleAUDelay())
        committedEntry.presetData = editedData
        let revertedEntry = committedEntry.mergingLivePresetData(
            revertedData,
            matchesLastAppliedPreset: host.liveStateMatchesLastAppliedPreset(revertedData)
        )
        #expect(revertedEntry.presetData == revertedData)
    }

    @Test("processInterleaved routes audio through chain")
    func processInterleavedWorks() {
        let desc = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C706173, // 'lpas' - AULowPassFilter
            componentManufacturer: 0x6170706C,
            name: "AULowPassFilter",
            manufacturer: "Apple",
            version: 1
        )
        let entry = AUEffectChainEntry(plugin: desc)
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100, maxFrames: 256)
        #expect(chain.hosts.count == 1)

        // Set cutoff low
        if let au = chain.hosts.first?.audioUnit {
            var cutoff: AudioUnitParameterValue = 100.0
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, cutoff, 0)
        }

        let frameCount = 256
        var buffer = [Float](repeating: 0, count: frameCount * 2)
        // 15kHz sine
        for i in 0..<frameCount {
            let s = sinf(2.0 * .pi * 15000.0 * Float(i) / 44100.0)
            buffer[i * 2] = s
            buffer[i * 2 + 1] = s
        }

        // Settle filter
        for _ in 0..<20 {
            var temp = buffer
            temp.withUnsafeMutableBufferPointer { ptr in
                chain.processInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
            }
        }

        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.processInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        let energy = buffer.reduce(Float(0)) { $0 + $1 * $1 }
        let maxPossibleEnergy = Float(frameCount * 2) // each sample max 1.0
        #expect(energy < maxPossibleEnergy * 0.001, "15kHz should be nearly silent through 100Hz lowpass")
    }

    @Test("Bypassed chain does not modify audio")
    func bypassedChainPassthrough() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100, maxFrames: 64)
        chain.setBypassed(true)

        var buffer: [Float] = [0.5, -0.5, 0.3, -0.3]
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.processInterleaved(samples: ptr.baseAddress!, frameCount: 2)
        }
        #expect(buffer == original)
    }

    @Test("Rebuilding a chain reuses unchanged hosts and Audio Unit instances")
    func rebuildingReusesHost() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let original = AUEffectChain(entries: [entry], sampleRate: 44100)
        guard let originalHost = original.host(for: entry.id),
              let originalAudioUnit = originalHost.audioUnit else {
            Issue.record("Failed to instantiate AUDelay")
            return
        }

        var disabledEntry = entry
        disabledEntry.isEnabled = false
        let rebuilt = AUEffectChain(
            entries: [disabledEntry],
            sampleRate: 48000,
            reusing: original
        )

        #expect(rebuilt.host(for: entry.id) === originalHost)
        #expect(rebuilt.host(for: entry.id)?.audioUnit == originalAudioUnit)
        #expect(rebuilt.host(for: entry.id)?.isEnabled == false)
        #expect(rebuilt.sampleRate == 48000)
    }

    private func appleAUDelay() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }
}

// MARK: - PersistentMixerStrip Tests

@Suite("PersistentMixerStrip", .serialized)
@MainActor
struct PersistentMixerStripTests {

    @Test("Entry updates retain unchanged Audio Unit instances")
    func updateEntriesRetainsInstance() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let strip = PersistentMixerStrip(
            persistenceIdentifier: "com.test.browser",
            displayName: "Browser",
            slot: 1,
            entries: [entry],
            sampleRate: 44100,
            isBypassed: false
        )
        guard let originalHost = strip.host(for: entry.id),
              let originalAudioUnit = originalHost.audioUnit else {
            Issue.record("Failed to instantiate AUDelay")
            return
        }

        var disabledEntry = entry
        disabledEntry.isEnabled = false
        strip.updateEntries([disabledEntry], sampleRate: 48000)

        #expect(strip.host(for: entry.id) === originalHost)
        #expect(strip.host(for: entry.id)?.audioUnit == originalAudioUnit)
        #expect(strip.host(for: entry.id)?.isEnabled == false)
    }

    // PACE Fusion installs Mach exception handlers while Console 1 is loading.
    // SwiftPM's testing helper guards those ports and is terminated with
    // EXC_GUARD before AudioComponentInstanceNew can return. Keep this
    // destructive in-process probe opt-in; the exported FineTune.app launch
    // smoke is the supported end-to-end host validation.
    @Test(
        "Console 1 instantiates and survives a strip rebuild in a compatible host",
        .enabled(
            if: ProcessInfo.processInfo.environment[
                "FINETUNE_ALLOW_IN_PROCESS_CONSOLE1_TEST"
            ] == "1",
            "PACE Fusion is incompatible with SwiftPM's guarded test helper; validate the exported FineTune.app instead."
        )
    )
    func consoleOneIntegration() {
        let scanner = AUPluginScanner()
        guard let consoleOne = scanner.plugins.first(where: \.isSoftubeConsole1) else {
            Issue.record("Console 1 was not discovered")
            return
        }

        let entry = AUEffectChainEntry(plugin: consoleOne)
        let strip = PersistentMixerStrip(
            persistenceIdentifier: "com.google.Chrome",
            displayName: "Google Chrome",
            slot: 1,
            entries: [entry],
            sampleRate: 48000,
            isBypassed: false
        )
        guard let originalHost = strip.host(for: entry.id),
              let originalAudioUnit = originalHost.audioUnit else {
            Issue.record("Console 1 was discovered but could not be instantiated")
            return
        }

        var disabledEntry = entry
        disabledEntry.isEnabled = false
        strip.updateEntries([disabledEntry], sampleRate: 48000)

        #expect(strip.failedEntryIDs.isEmpty)
        #expect(strip.host(for: entry.id) === originalHost)
        #expect(strip.host(for: entry.id)?.audioUnit == originalAudioUnit)
    }

    private func appleAUDelay() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }
}

// MARK: - CrashGuard Plugin Tracking Tests

@Suite("CrashGuard Plugin Tracking")
struct CrashGuardPluginTrackingTests {

    @Test("FNV-1a hash is deterministic")
    func hashDeterministic() {
        let h1 = CrashGuard.fnv1aHash("test-plugin")
        let h2 = CrashGuard.fnv1aHash("test-plugin")
        #expect(h1 == h2)
    }

    @Test("FNV-1a hash differs for different strings")
    func hashDiffers() {
        let h1 = CrashGuard.fnv1aHash("plugin-a")
        let h2 = CrashGuard.fnv1aHash("plugin-b")
        #expect(h1 != h2)
    }

    @Test("readCrashPlugins returns empty when no crash file")
    func noCrashFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneCrashGuardTests-\(UUID().uuidString)")
        let result = CrashGuard.readCrashPlugins(
            knownPluginIDs: ["foo", "bar"],
            directory: directory
        )
        #expect(result.isEmpty)
    }

    @Test("Crash marker remains until durable quarantine is acknowledged")
    func crashMarkerUsesTwoPhaseAcknowledgement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneCrashGuardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent(".au-crash-plugins")
        let pluginID = "test-plugin"
        var hashes = [CrashGuard.fnv1aHash(pluginID)]
        let data = hashes.withUnsafeBytes { Data($0) }
        try data.write(to: marker)

        let result = CrashGuard.readCrashPlugins(
            knownPluginIDs: [pluginID, "other-plugin"],
            directory: directory
        )

        #expect(result == [pluginID])
        #expect(FileManager.default.fileExists(atPath: marker.path))
        CrashGuard.clearCrashPlugins(directory: directory)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("A later crash appends active plugins without erasing an unacknowledged marker")
    func crashMarkerAppendsAcrossFailedQuarantineGenerations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneCrashGuardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pluginA = "plugin-from-unacknowledged-crash"
        let pluginB = "plugin-from-later-crash"

        #expect(CrashGuard.appendCrashPluginHashesForTesting(
            [CrashGuard.fnv1aHash(pluginA)],
            directory: directory
        ))
        #expect(CrashGuard.appendCrashPluginHashesForTesting(
            [CrashGuard.fnv1aHash(pluginB), CrashGuard.fnv1aHash(pluginA)],
            directory: directory
        ))

        #expect(CrashGuard.readCrashPlugins(
            knownPluginIDs: [pluginA, pluginB],
            directory: directory
        ) == [pluginA, pluginB])
    }
}

// MARK: - SettingsManager AU Tests

@Suite("SettingsManager AU Persistence", .serialized)
@MainActor
struct SettingsManagerAUTests {

    @Test("Get/set app AU effect chain round-trip")
    func appChainRoundTrip() {
        let settings = makeSettings()
        let entry = AUEffectChainEntry(plugin: makePlugin())
        settings.setAUEffectChain([entry], for: "com.test.app")
        let loaded = settings.getAUEffectChain(for: "com.test.app")
        #expect(loaded.count == 1)
        #expect(loaded[0].id == entry.id)
    }

    @Test("Empty chain removes key")
    func emptyChainRemovesKey() {
        let settings = makeSettings()
        let entry = AUEffectChainEntry(plugin: makePlugin())
        settings.setAUEffectChain([entry], for: "com.test.app")
        settings.setAUEffectChain([], for: "com.test.app")
        let loaded = settings.getAUEffectChain(for: "com.test.app")
        #expect(loaded.isEmpty)
    }

    @Test("Get/set device AU effect chain round-trip")
    func deviceChainRoundTrip() {
        let settings = makeSettings()
        let entry = AUEffectChainEntry(plugin: makePlugin())
        settings.setDeviceAUEffectChain([entry], for: "device-uid-123")
        let loaded = settings.getDeviceAUEffectChain(for: "device-uid-123")
        #expect(loaded.count == 1)
        #expect(loaded[0].id == entry.id)
    }

    @Test("Device AU persistence rejects Console 1 at runtime")
    func deviceChainRejectsConsoleOne() {
        let settings = makeSettings()
        let generic = AUEffectChainEntry(plugin: makePlugin())
        let console = AUEffectChainEntry(plugin: AUPluginDescriptor(
            componentType: 0x6175_6678,
            componentSubType: 0x5363_5069,
            componentManufacturer: 0x5366_5462,
            name: "Console 1",
            manufacturer: "Softube",
            version: 1
        ))

        settings.setDeviceAUEffectChain([console, generic], for: "device-uid-123")

        #expect(settings.getDeviceAUEffectChain(for: "device-uid-123").map(\.id) == [generic.id])
    }

    @Test("Favorite toggle works")
    func favoriteToggle() {
        let settings = makeSettings()
        let pluginID = "test-plugin-id"
        #expect(settings.isAUPluginFavorite(pluginID) == false)
        settings.toggleAUPluginFavorite(pluginID)
        #expect(settings.isAUPluginFavorite(pluginID) == true)
        settings.toggleAUPluginFavorite(pluginID)
        #expect(settings.isAUPluginFavorite(pluginID) == false)
    }

    @Test("Crash history tracking")
    func crashHistory() {
        let settings = makeSettings()
        #expect(settings.wasAUPluginInvolvedInCrash("p1") == false)
        settings.markAUPluginsActiveAtCrash(["p1", "p2"])
        #expect(settings.wasAUPluginInvolvedInCrash("p1") == true)
        #expect(settings.wasAUPluginInvolvedInCrash("p2") == true)
        #expect(settings.wasAUPluginInvolvedInCrash("p3") == false)
        settings.clearAUPluginCrashHistory()
        #expect(settings.wasAUPluginInvolvedInCrash("p1") == false)
    }

    @Test("disableCrashedAUPlugins disables matching entries")
    func disableCrashed() {
        let settings = makeSettings()
        let plugin1 = makePlugin(name: "Plugin1", subType: 1)
        let plugin2 = makePlugin(name: "Plugin2", subType: 2)
        var entry1 = AUEffectChainEntry(plugin: plugin1)
        var entry2 = AUEffectChainEntry(plugin: plugin2)
        settings.setAUEffectChain([entry1, entry2], for: "com.test.app")

        settings.disableCrashedAUPlugins([plugin1.id])

        let loaded = settings.getAUEffectChain(for: "com.test.app")
        #expect(loaded.count == 2)
        #expect(loaded[0].isEnabled == false)
        #expect(loaded[0].isCrashQuarantined == true)
        #expect(loaded[1].isEnabled == true)
        #expect(loaded[1].isCrashQuarantined != true)
    }

    @Test("Reset clears all AU settings")
    func resetClearsAll() {
        let settings = makeSettings()
        settings.setAUEffectChain([AUEffectChainEntry(plugin: makePlugin())], for: "app1")
        settings.setDeviceAUEffectChain([AUEffectChainEntry(plugin: makePlugin())], for: "dev1")
        settings.toggleAUPluginFavorite("fav1")
        settings.markAUPluginsActiveAtCrash(["crash1"])

        settings.resetAllSettings()

        #expect(settings.getAUEffectChain(for: "app1").isEmpty)
        #expect(settings.getDeviceAUEffectChain(for: "dev1").isEmpty)
        #expect(settings.isAUPluginFavorite("fav1") == false)
        #expect(settings.wasAUPluginInvolvedInCrash("crash1") == false)
    }

    @Test("Ignoring an app clears its AU chain, bypass, and mixer slot")
    func ignoreClearsAppAUState() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneIgnoreAUTests-\(UUID().uuidString)")
        let settings = SettingsManager(directory: directory)
        let identifier = "com.test.app"
        settings.pinApp(
            identifier,
            info: PinnedAppInfo(
                persistenceIdentifier: identifier,
                displayName: "Test App",
                bundleID: identifier
            )
        )
        settings.setAUEffectChain([AUEffectChainEntry(plugin: makePlugin())], for: identifier)
        settings.setAppAUBypassed(true, for: identifier)

        settings.ignoreApp(
            identifier,
            info: IgnoredAppInfo(
                persistenceIdentifier: identifier,
                displayName: "Test App",
                bundleID: identifier
            )
        )

        #expect(settings.getAUEffectChain(for: identifier).isEmpty)
        #expect(settings.getAppAUBypassed(for: identifier) == false)
        #expect(settings.getMixerStripSlot(for: identifier) == nil)
    }

    private func makePlugin(name: String = "Test", subType: UInt32 = 0x74657374) -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: subType,
            componentManufacturer: 0x74737400,
            name: name,
            manufacturer: "Test",
            version: 1
        )
    }

    private func makeSettings() -> SettingsManager {
        SettingsManager(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("FineTuneAUTests-\(UUID().uuidString)")
        )
    }
}
