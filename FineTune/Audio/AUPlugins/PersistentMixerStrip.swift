import Foundation
import os

/// Logical per-application mixer channel whose Audio Unit instances outlive any one PID/tap.
///
/// `ProcessTapController` is intentionally temporary: Chromium helpers stop, apps relaunch,
/// and CoreAudio taps are recreated during health recovery. Console 1, however, assigns its
/// track identity to an Audio Unit instance. Retaining one strip per persistence identifier
/// keeps that identity stable while temporary taps attach and detach.
@MainActor
final class PersistentMixerStrip {
    let persistenceIdentifier: String
    private(set) var displayName: String
    private(set) var slot: Int?
    private(set) var entries: [AUEffectChainEntry]
    private(set) var chain: AUEffectChain?
    private(set) var isBypassed: Bool

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FineTune",
        category: "PersistentMixerStrip"
    )

    init(
        persistenceIdentifier: String,
        displayName: String,
        slot: Int?,
        entries: [AUEffectChainEntry],
        sampleRate: Double,
        isBypassed: Bool
    ) {
        var seenEntryIDs = Set<UUID>()
        let uniqueEntries = entries.filter { seenEntryIDs.insert($0.id).inserted }
        self.persistenceIdentifier = persistenceIdentifier
        self.displayName = displayName
        self.slot = slot
        self.entries = uniqueEntries
        self.isBypassed = isBypassed

        if uniqueEntries.isEmpty {
            self.chain = nil
        } else {
            let chain = AUEffectChain(
                entries: uniqueEntries,
                sampleRate: sampleRate,
                retainingDisabledConsole: true
            )
            chain.setBypassed(isBypassed)
            self.chain = chain
        }

        logger.info("Prepared persistent strip slot=\(slot ?? 0) id=\(persistenceIdentifier, privacy: .public)")
    }

    func updateMetadata(displayName: String, slot: Int?) {
        self.displayName = displayName
        self.slot = slot
    }

    /// Rebuilds only the immutable chain wrapper while reusing unchanged hosts. This means
    /// toggling, reordering, or adding a neighboring effect does not destroy Console 1.
    func updateEntries(
        _ requestedEntries: [AUEffectChainEntry],
        sampleRate: Double,
        explicitPresetEntryID: UUID? = nil
    ) {
        let oldChain = chain
        let storedByID = entries.reduce(into: [UUID: AUEffectChainEntry]()) { result, entry in
            if result[entry.id] == nil { result[entry.id] = entry }
        }
        let liveByID = (oldChain?.entriesWithLiveState() ?? entries).reduce(
            into: [UUID: AUEffectChainEntry]()
        ) { result, entry in
            if result[entry.id] == nil { result[entry.id] = entry }
        }

        var seenEntryIDs = Set<UUID>()
        var mergedEntries = requestedEntries.filter { seenEntryIDs.insert($0.id).inserted }
        for index in mergedEntries.indices {
            let id = mergedEntries[index].id
            // Selecting Default or the already-selected factory preset is an explicit
            // command, even though its metadata may be unchanged. Do not replace that
            // command with unsaved ClassInfo from an editor that is still open.
            guard id != explicitPresetEntryID else { continue }
            guard let stored = storedByID[id], let live = liveByID[id] else { continue }

            // Preserve unsaved live ClassInfo when the requested mutation did not itself
            // change the preset. Explicit preset selection still wins.
            if mergedEntries[index].presetData == stored.presetData,
               mergedEntries[index].selectedFactoryPresetIndex == stored.selectedFactoryPresetIndex {
                mergedEntries[index].presetData = live.presetData
                mergedEntries[index].selectedFactoryPresetIndex = live.selectedFactoryPresetIndex
            }
        }

        let newChain: AUEffectChain?
        if mergedEntries.isEmpty {
            newChain = nil
        } else {
            let rebuilt = AUEffectChain(
                entries: mergedEntries,
                sampleRate: sampleRate,
                retainingDisabledConsole: true,
                forcingPresetReloadFor: explicitPresetEntryID,
                reusing: oldChain
            )
            rebuilt.setBypassed(isBypassed)
            newChain = rebuilt
        }

        entries = mergedEntries
        chain = newChain

        if let oldChain {
            // A HAL callback may have captured the old immutable wrapper just before the
            // pointer swap. Hold it briefly; reused hosts are retained by the new wrapper.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                _ = oldChain
            }
        }
    }

    func setBypassed(_ bypassed: Bool) {
        isBypassed = bypassed
        chain?.setBypassed(bypassed)
    }

    func host(for entryID: UUID) -> AUEffectHost? {
        chain?.host(for: entryID)
    }

    var failedEntryIDs: Set<UUID> {
        chain?.failedEntryIDs ?? []
    }

    func entriesWithLiveState() -> [AUEffectChainEntry] {
        chain?.entriesWithLiveState() ?? entries
    }
}
