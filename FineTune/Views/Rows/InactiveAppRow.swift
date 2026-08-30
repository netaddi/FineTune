// FineTune/Views/Rows/InactiveAppRow.swift
import SwiftUI

/// A row displaying a pinned but inactive app (not currently producing audio).
/// Similar to AppRow but:
/// - Uses PinnedAppInfo instead of AudioApp
/// - VU meter always shows 0 (no audio level polling)
/// - Slightly dimmed appearance to indicate inactive state
/// - All settings (volume/mute/EQ/device) work normally and are persisted
struct InactiveAppRow: View {
    let appInfo: PinnedAppInfo
    let icon: NSImage
    let volume: Float  // Linear gain 0-1 (boost applied separately)
    let devices: [AudioDevice]
    let deviceIconOverrides: [String: String]
    let selectedDeviceUID: String?
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let isMuted: Bool
    let boost: BoostLevel
    let onBoostChange: (BoostLevel) -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let eqSettings: EQSettings
    let userPresets: [UserEQPreset]
    let onEQChange: (EQSettings) -> Void
    let onUserPresetSelected: (UserEQPreset) -> Void
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void
    let isFocused: Bool
    let mixerStripSlot: Int?
    let mixerStripSlotCount: Int
    let onMixerStripSlotChange: (Int) -> Void

    // AU effect chain — available while inactive because the persistent strip owns it.
    let auEffectChain: [AUEffectChainEntry]
    let isAUChainBypassed: Bool
    let auPluginScanner: AUPluginScanner?
    let getFavoriteAUPlugins: () -> Set<String>
    let getAUCrashHistory: () -> Set<String>
    let onAddAUEffect: (AUPluginDescriptor) -> Void
    let onRemoveAUEffect: (UUID) -> Void
    let onToggleAUEffect: (UUID, Bool) -> Void
    let onAUBypassToggle: () -> Void
    let onToggleAUFavorite: (String) -> Void
    let onOpenAUUI: (UUID) -> Void
    let onOpenAUGenericUI: (UUID) -> Void
    let auFailedEntryIDs: Set<UUID>
    let getAUFactoryPresets: (UUID) -> [(index: Int, name: String)]
    let onSelectAUFactoryPreset: (UUID, Int) -> Void

    @State private var localEQSettings: EQSettings

    init(
        appInfo: PinnedAppInfo,
        icon: NSImage,
        volume: Float,
        devices: [AudioDevice],
        deviceIconOverrides: [String: String] = [:],
        selectedDeviceUID: String?,
        selectedDeviceUIDs: Set<String> = [],
        isFollowingDefault: Bool = true,
        defaultDeviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        isMuted: Bool = false,
        boost: BoostLevel = .x1,
        onBoostChange: @escaping (BoostLevel) -> Void = { _ in },
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
        eqSettings: EQSettings = .disabledFlat,
        userPresets: [UserEQPreset] = [],
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        onUserPresetSelected: @escaping (UserEQPreset) -> Void = { _ in },
        onSavePreset: @escaping (String, EQSettings) -> Void = { _, _ in },
        onDeleteUserPreset: @escaping (UUID) -> Void = { _ in },
        onRenameUserPreset: @escaping (UUID, String) -> Void = { _, _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {},
        isFocused: Bool = false,
        mixerStripSlot: Int? = nil,
        mixerStripSlotCount: Int = 1,
        onMixerStripSlotChange: @escaping (Int) -> Void = { _ in },
        auEffectChain: [AUEffectChainEntry] = [],
        isAUChainBypassed: Bool = false,
        auPluginScanner: AUPluginScanner? = nil,
        getFavoriteAUPlugins: @escaping () -> Set<String> = { [] },
        getAUCrashHistory: @escaping () -> Set<String> = { [] },
        onAddAUEffect: @escaping (AUPluginDescriptor) -> Void = { _ in },
        onRemoveAUEffect: @escaping (UUID) -> Void = { _ in },
        onToggleAUEffect: @escaping (UUID, Bool) -> Void = { _, _ in },
        onAUBypassToggle: @escaping () -> Void = {},
        onToggleAUFavorite: @escaping (String) -> Void = { _ in },
        onOpenAUUI: @escaping (UUID) -> Void = { _ in },
        onOpenAUGenericUI: @escaping (UUID) -> Void = { _ in },
        auFailedEntryIDs: Set<UUID> = [],
        getAUFactoryPresets: @escaping (UUID) -> [(index: Int, name: String)] = { _ in [] },
        onSelectAUFactoryPreset: @escaping (UUID, Int) -> Void = { _, _ in }
    ) {
        self.appInfo = appInfo
        self.icon = icon
        self.volume = volume
        self.devices = devices
        self.deviceIconOverrides = deviceIconOverrides
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.isMuted = isMuted
        self.boost = boost
        self.onBoostChange = onBoostChange
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
        self.eqSettings = eqSettings
        self.userPresets = userPresets
        self.onEQChange = onEQChange
        self.onUserPresetSelected = onUserPresetSelected
        self.onSavePreset = onSavePreset
        self.onDeleteUserPreset = onDeleteUserPreset
        self.onRenameUserPreset = onRenameUserPreset
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        self.isFocused = isFocused
        self.mixerStripSlot = mixerStripSlot
        self.mixerStripSlotCount = mixerStripSlotCount
        self.onMixerStripSlotChange = onMixerStripSlotChange
        self.auEffectChain = auEffectChain
        self.isAUChainBypassed = isAUChainBypassed
        self.auPluginScanner = auPluginScanner
        self.getFavoriteAUPlugins = getFavoriteAUPlugins
        self.getAUCrashHistory = getAUCrashHistory
        self.onAddAUEffect = onAddAUEffect
        self.onRemoveAUEffect = onRemoveAUEffect
        self.onToggleAUEffect = onToggleAUEffect
        self.onAUBypassToggle = onAUBypassToggle
        self.onToggleAUFavorite = onToggleAUFavorite
        self.onOpenAUUI = onOpenAUUI
        self.onOpenAUGenericUI = onOpenAUGenericUI
        self.auFailedEntryIDs = auFailedEntryIDs
        self.getAUFactoryPresets = getAUFactoryPresets
        self.onSelectAUFactoryPreset = onSelectAUFactoryPreset
        self._localEQSettings = State(initialValue: eqSettings)
    }

    var body: some View {
        ExpandableGlassRow(isExpanded: isEQExpanded, isFocused: isFocused) {
            // Header: Main row content (always visible)
            HStack(spacing: DesignTokens.Spacing.sm) {
                // VU Meter (always 0 for inactive apps)
                VUMeter(level: 0, isMuted: isMuted || volume == 0)

                // App icon (no activation for inactive apps)
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: DesignTokens.Dimensions.rowContentHeight - 4, height: DesignTokens.Dimensions.rowContentHeight - 4)

                // App name + optional routing subtitle (hidden when the app is on
                // system default).
                VStack(alignment: .leading, spacing: 1) {
                    Text(appInfo.displayName)
                        .font(DesignTokens.Typography.rowName)
                        .lineLimit(1)
                        .help(appInfo.displayName)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)

                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if let mixerStripSlot {
                            Text("Console order #\(mixerStripSlot) next launch")
                                .foregroundStyle(DesignTokens.Colors.accentPrimary)
                        }
                        if let subtitle = DevicePicker.routingSubtitle(
                            devices: devices,
                            selectedDeviceUID: selectedDeviceUID ?? defaultDeviceUID ?? "",
                            selectedDeviceUIDs: selectedDeviceUIDs,
                            isFollowingDefault: isFollowingDefault,
                            mode: deviceSelectionMode
                        ) {
                            Text(subtitle)
                                .foregroundStyle(DesignTokens.Colors.textTertiary)
                        }
                    }
                    .font(.system(size: 9))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Shared controls section (VU meter always 0 for inactive apps)
                AppRowControls(
                    volume: volume,
                    isMuted: isMuted,
                    devices: devices,
                    deviceIconOverrides: deviceIconOverrides,
                    selectedDeviceUID: selectedDeviceUID ?? defaultDeviceUID ?? "",
                    selectedDeviceUIDs: selectedDeviceUIDs,
                    isFollowingDefault: isFollowingDefault,
                    defaultDeviceUID: defaultDeviceUID,
                    deviceSelectionMode: deviceSelectionMode,
                    boost: boost,
                    isEQExpanded: isEQExpanded,
                    onVolumeChange: onVolumeChange,
                    onMuteChange: onMuteChange,
                    onBoostChange: onBoostChange,
                    onDeviceSelected: onDeviceSelected,
                    onDevicesSelected: onDevicesSelected,
                    onDeviceModeChange: onDeviceModeChange,
                    onSelectFollowDefault: onSelectFollowDefault,
                    onEQToggle: onEQToggle,
                    isRowFocused: isFocused
                )
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
            .opacity(0.6)
        } expandedContent: {
            if let mixerStripSlot {
                PersistentMixerStripControl(
                    slot: mixerStripSlot,
                    maximumSlot: mixerStripSlotCount,
                    onChange: onMixerStripSlotChange
                )
            }

            // EQ panel
            EQPanelView(
                settings: $localEQSettings,
                userPresets: userPresets,
                onPresetSelected: { preset in
                    localEQSettings = preset.settings
                    onEQChange(preset.settings)
                },
                onUserPresetSelected: { userPreset in
                    localEQSettings = userPreset.settings
                    onUserPresetSelected(userPreset)
                },
                onSettingsChanged: { settings in
                    onEQChange(settings)
                },
                onSavePreset: onSavePreset,
                onDeleteUserPreset: onDeleteUserPreset,
                onRenameUserPreset: onRenameUserPreset
            )
            .padding(.top, DesignTokens.Spacing.sm)

            if let scanner = auPluginScanner {
                AUEffectChainView(
                    entries: auEffectChain,
                    isBypassed: isAUChainBypassed,
                    scanner: scanner,
                    getFavoriteIDs: getFavoriteAUPlugins,
                    getCrashHistory: getAUCrashHistory,
                    onToggle: onToggleAUEffect,
                    onRemove: onRemoveAUEffect,
                    onAddEffect: onAddAUEffect,
                    onBypassToggle: onAUBypassToggle,
                    onToggleFavorite: onToggleAUFavorite,
                    onOpenUI: onOpenAUUI,
                    onOpenGenericUI: onOpenAUGenericUI,
                    failedEntryIDs: auFailedEntryIDs,
                    getFactoryPresets: getAUFactoryPresets,
                    onSelectFactoryPreset: onSelectAUFactoryPreset,
                    allowsPlugin: { plugin in
                        !plugin.isSoftubeConsole1
                            || !auEffectChain.contains(where: { $0.pluginDescriptor.isSoftubeConsole1 })
                    }
                )
            }
        }
        .onChange(of: eqSettings) { _, newValue in
            localEQSettings = newValue
        }
    }
}
