// FineTune/Models/AudioApp.swift
import AppKit
import AudioToolbox

struct AudioApp: Identifiable, Hashable {
    let id: pid_t
    let processObjectIDs: [AudioObjectID]
    let name: String
    let icon: NSImage
    let bundleID: String?
    let isHelperBacked: Bool
    /// Bundle IDs observed on the Core Audio process objects coalesced into this logical
    /// app. These are distinct from the responsible GUI app's bundle ID for helpers.
    let audioProcessBundleIDs: [String]
    /// True when Core Audio published at least one process object before its bundle
    /// metadata became readable. Bundle-only restoration cannot prove that such an
    /// object is covered, so the engine must fall back to an explicit object-ID tap.
    let hasUnresolvedAudioProcessBundleMetadata: Bool

    init(
        id: pid_t,
        processObjectIDs: [AudioObjectID],
        name: String,
        icon: NSImage,
        bundleID: String?,
        isHelperBacked: Bool = false,
        audioProcessBundleIDs: [String] = [],
        hasUnresolvedAudioProcessBundleMetadata: Bool = false
    ) {
        self.id = id
        self.processObjectIDs = processObjectIDs
        self.name = name
        self.icon = icon
        self.bundleID = bundleID
        self.isHelperBacked = isHelperBacked
        self.audioProcessBundleIDs = audioProcessBundleIDs
        self.hasUnresolvedAudioProcessBundleMetadata = hasUnresolvedAudioProcessBundleMetadata
    }

    var persistenceIdentifier: String {
        bundleID ?? "name:\(name)"
    }

    /// Bundle-only taps must not claim generic helpers shared by unrelated apps (for
    /// example `com.apple.WebKit.GPU`). Keep the responsible app itself plus helper IDs
    /// in its own namespace, such as `com.google.Chrome.helper`.
    var restorationBundleIDs: [String] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        return Array(Set([bundleID] + audioProcessBundleIDs.filter {
            $0 == bundleID || $0.hasPrefix(bundleID + ".")
        })).sorted()
    }

    /// Whether a tap for this snapshot may ask Core Audio to restore future processes by
    /// bundle ID. A bundle-only standby is safe because its identities have already been
    /// namespace-filtered. A live object-ID tap is safe only when metadata is complete and
    /// every observed process belongs to that same filtered set. Otherwise enabling
    /// restoration would let HAL remember a shared helper (for example WebKit.GPU) and
    /// attach an unrelated app to this graph on a later launch.
    var supportsSafeProcessRestoration: Bool {
        let safeBundleIDs = Set(restorationBundleIDs)
        guard !safeBundleIDs.isEmpty else { return false }
        guard !processObjectIDs.isEmpty else { return true }
        guard !hasUnresolvedAudioProcessBundleMetadata else { return false }
        let observedBundleIDs = Set(audioProcessBundleIDs.filter { !$0.isEmpty })
        return !observedBundleIDs.isEmpty
            && observedBundleIDs.isSubset(of: safeBundleIDs)
    }

    /// Returns the same logical process identity enriched with helper bundles learned on
    /// earlier launches. The namespace filter prevents stale/shared system helpers from
    /// being promoted into a bundle-restoring tap.
    func includingRestorationBundleIDs(_ learnedBundleIDs: [String]) -> AudioApp {
        guard let bundleID, !bundleID.isEmpty else { return self }
        let safeLearned = learnedBundleIDs.filter {
            $0 == bundleID || $0.hasPrefix(bundleID + ".")
        }
        return AudioApp(
            id: id,
            processObjectIDs: processObjectIDs,
            name: name,
            icon: icon,
            bundleID: bundleID,
            isHelperBacked: isHelperBacked,
            audioProcessBundleIDs: Array(Set(audioProcessBundleIDs + safeLearned)).sorted(),
            hasUnresolvedAudioProcessBundleMetadata: hasUnresolvedAudioProcessBundleMetadata
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
    }
}
