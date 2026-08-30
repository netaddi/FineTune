// FineTune/Audio/AUPlugins/AUEffectChainEntry.swift
import Foundation

struct AUEffectChainEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let pluginDescriptor: AUPluginDescriptor
    var isEnabled: Bool
    var presetData: Data?
    var selectedFactoryPresetIndex: Int?
    /// Distinguishes crash-loop quarantine from the ordinary user bypass toggle.
    /// Optional keeps settings written before this field backward-compatible.
    var isCrashQuarantined: Bool?

    init(plugin: AUPluginDescriptor, isEnabled: Bool = true) {
        self.id = UUID()
        self.pluginDescriptor = plugin
        self.isEnabled = isEnabled
        self.presetData = nil
        self.selectedFactoryPresetIndex = nil
        self.isCrashQuarantined = nil
    }

    var isConsole1TrackEligible: Bool {
        pluginDescriptor.isSoftubeConsole1 && isCrashQuarantined != true
    }

    func shouldInstantiateOnColdStart(retainingDisabledConsole: Bool) -> Bool {
        isCrashQuarantined != true
            && (isEnabled || (retainingDisabledConsole && pluginDescriptor.isSoftubeConsole1))
    }

    /// Merges a live ClassInfo snapshot without erasing the user's Default/factory
    /// selection when the Audio Unit has not actually changed since that selection.
    /// Returning the original value also lets editor polling avoid redundant writes.
    func mergingLivePresetData(
        _ livePresetData: Data,
        matchesLastAppliedPreset: Bool
    ) -> AUEffectChainEntry {
        guard !matchesLastAppliedPreset else { return self }
        var updated = self
        updated.presetData = livePresetData
        updated.selectedFactoryPresetIndex = nil
        return updated
    }
}

/// Observable UI state for a single AU effect chain (per-app or per-device).
/// AudioEngine owns these; SettingsManager persists entries + bypass to disk.
struct AUChainState {
    var entries: [AUEffectChainEntry] = []
    var isBypassed: Bool = false
    var failedEntryIDs: Set<UUID> = []
}
