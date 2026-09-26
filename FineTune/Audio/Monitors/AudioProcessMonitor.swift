// FineTune/Audio/Monitors/AudioProcessMonitor.swift
import AppKit
import AudioToolbox
import os

/// Lightweight value for detecting process list changes without comparing icons/names.
private struct AppFingerprint: Hashable {
    let pid: pid_t
    let objectIDs: [AudioObjectID]
    let persistenceIdentifier: String
    let name: String
    let restorationBundleIDs: [String]
    let audioProcessBundleIDs: [String]
    let isHelperBacked: Bool
    let hasUnresolvedAudioProcessBundleMetadata: Bool

    init(_ app: AudioApp) {
        pid = app.id
        objectIDs = app.processObjectIDs
        persistenceIdentifier = app.persistenceIdentifier
        name = app.name
        restorationBundleIDs = app.restorationBundleIDs
        audioProcessBundleIDs = Array(Set(app.audioProcessBundleIDs)).sorted()
        isHelperBacked = app.isHelperBacked
        hasUnresolvedAudioProcessBundleMetadata = app.hasUnresolvedAudioProcessBundleMetadata
    }
}

@Observable
@MainActor
final class AudioProcessMonitor: AudioProcessMonitoring {
    private(set) var connectedApps: [AudioApp] = []
    private(set) var activeApps: [AudioApp] = []
    private(set) var activeOutputApps: [AudioApp] = []
    private var listenerGeneration: UInt64 = 0
    private var successfulSnapshotGeneration: UInt64?
    var onAppsChanged: (([AudioApp]) -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioProcessMonitor")

    /// Bundle ID prefixes for system daemons that should be filtered from the apps list
    /// These produce system audio (Siri, alerts, notifications) and shouldn't appear as user apps
    private static let systemDaemonPrefixes: [String] = [
        "com.apple.siri",
        "com.apple.Siri",
        "com.apple.assistant",
        "com.apple.audio",
        "com.apple.coreaudio",
        "com.apple.mediaremote",
        "com.apple.accessibility.heard",
        "com.apple.hearingd",
        "com.apple.voicebankingd",
        "com.apple.systemsound",
        "com.apple.FrontBoardServices",
        "com.apple.frontboard",
        "com.apple.springboard",
        "com.apple.notificationcenter",
        "com.apple.NotificationCenter",
        "com.apple.UserNotifications",
        "com.apple.usernotifications",
        "com.apple.SpeechRecognitionCore",
        "com.apple.speech",
        "com.apple.dictation",
        "com.apple.corespeech",
        "com.apple.CoreSpeech",
        "com.apple.VoiceControl",
        "com.apple.voicecontrol",
    ]

    /// Process names for system daemons (fallback when bundle ID is nil or different format)
    private static let systemDaemonNames: [String] = [
        "systemsoundserverd",
        "systemsoundserv",
        "coreaudiod",
        "audiomxd",
        "speechrecognitiond",
        "dictationd",
        "corespeech",
    ]

    /// Returns true if the bundle ID or process name indicates a system daemon that should be filtered
    private func isSystemDaemon(bundleID: String?, name: String) -> Bool {
        // Check bundle ID prefixes
        if let bundleID {
            if Self.systemDaemonPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return true
            }
        }

        // Check process name (handles nil bundleID and format variations)
        let lowercaseName = name.lowercased()
        if Self.systemDaemonNames.contains(where: { lowercaseName.hasPrefix($0) }) {
            return true
        }

        return false
    }

    // Property listeners
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    private var processListenerBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var outputListenerProcessIDs: Set<AudioObjectID> = []
    private var monitoredProcesses: Set<AudioObjectID> = []
    private var periodicRefreshTask: Task<Void, Never>?

    private var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Function type for the private responsibility API
    private typealias ResponsibilityFunc = @convention(c) (pid_t) -> pid_t

    /// Gets the "responsible" PID for a process using Apple's private API.
    /// This is what Activity Monitor uses to show the correct parent for XPC services.
    private func getResponsiblePID(for pid: pid_t) -> pid_t? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        let responsiblePID = unsafeBitCast(symbol, to: ResponsibilityFunc.self)(pid)
        return responsiblePID > 0 && responsiblePID != pid ? responsiblePID : nil
    }

    /// Finds the responsible application for a helper/XPC process.
    /// Uses Apple's responsibility API first, falls back to process tree walking.
    private func findResponsibleApp(
        for pid: pid_t,
        in runningAppsByPID: [pid_t: NSRunningApplication]
    ) -> NSRunningApplication? {
        // First try Apple's responsibility API (works for XPC services like Safari's WebKit processes)
        if let responsiblePID = getResponsiblePID(for: pid),
           let app = runningAppsByPID[responsiblePID],
           app.bundleURL?.pathExtension == "app" {
            return app
        }

        // Fall back to walking up the process tree (works for Chrome/Brave helpers)
        var currentPID = pid
        var visited = Set<pid_t>()

        while currentPID > 1 && !visited.contains(currentPID) {
            visited.insert(currentPID)

            // Check if this PID is a proper app bundle (.app, not .xpc service)
            if let app = runningAppsByPID[currentPID],
               app.bundleURL?.pathExtension == "app" {
                return app
            }

            // Get parent PID using sysctl
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, currentPID]

            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }

            let parentPID = info.kp_eproc.e_ppid
            if parentPID == currentPID { break }
            currentPID = parentPID
        }

        return nil
    }

    func start() {
        if processListListenerBlock != nil {
            if !isMonitoringReady { refresh() }
            return
        }
        stop() // Drop child listeners left by an earlier failed registration.
        listenerGeneration &+= 1
        let generation = listenerGeneration

        logger.debug("Starting audio process monitor")

        // Set up listener first
        processListListenerBlock = { [weak self] numberAddresses, addresses in
            Task { @MainActor [weak self] in
                guard self?.listenerGeneration == generation else { return }
                self?.refresh()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            .system,
            &processListAddress,
            .main,
            processListListenerBlock!
        )

        if status != noErr {
            processListListenerBlock = nil
            logger.error("Failed to add process list listener: \(status)")
        }

        // Initial refresh
        refresh()

        // Periodic refresh as safety net — CoreAudio property listeners can miss
        // notifications during rapid process lifecycle changes (quit + relaunch).
        startPeriodicRefresh()
    }

    func stop() {
        listenerGeneration &+= 1
        successfulSnapshotGeneration = nil
        logger.debug("Stopping audio process monitor")

        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil

        // Remove process list listener
        if let block = processListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &processListAddress, .main, block)
            processListListenerBlock = nil
        }

        // Remove all per-process listeners
        removeAllProcessListeners()
    }

    func resetAfterServiceRestart() {
        stop()
        connectedApps = []
        activeApps = []
        activeOutputApps = []
    }

    var isMonitoringReady: Bool {
        processListListenerBlock != nil && successfulSnapshotGeneration == listenerGeneration
    }

    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 10s is sufficient as a safety net — HAL listeners handle most changes.
                // Lower intervals waste CPU at idle (#176).
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    private func refresh() {
        do {
            let processIDs = try AudioObjectID.readProcessList()
            let runningApps = NSWorkspace.shared.runningApplications
            let runningAppsByPID = Dictionary(
                runningApps.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let myPID = ProcessInfo.processInfo.processIdentifier

            var appsByPID: [pid_t: AudioApp] = [:]
            var snapshotComplete = true

            for objectID in processIDs {
                let pid: pid_t
                do { pid = try objectID.readProcessPID() } catch {
                    let nsError = error as NSError
                    if nsError.domain != NSOSStatusErrorDomain || nsError.code != Int(kAudioHardwareBadObjectError) {
                        snapshotComplete = false
                    }
                    continue
                }
                guard pid != myPID else { continue }

                // Try to find the parent app (for helper processes like Safari Graphics and Media)
                let directApp = runningAppsByPID[pid]

                // Check if it's a real app bundle (.app), not an XPC service (.xpc)
                let isRealApp = directApp?.bundleURL?.pathExtension == "app"
                let resolvedApp = isRealApp ? directApp : findResponsibleApp(for: pid, in: runningAppsByPID)
                let parentPID = resolvedApp?.processIdentifier ?? pid
                let isHelper = parentPID != pid

                // Use resolved app's info, fall back to Core Audio bundle ID
                let name = resolvedApp?.localizedName
                    ?? objectID.readProcessBundleID()?.components(separatedBy: ".").last
                    ?? "Unknown"
                let icon = resolvedApp?.icon
                    ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
                    ?? NSImage()
                let bundleID = resolvedApp?.bundleIdentifier ?? objectID.readProcessBundleID()
                let audioProcessBundleID = objectID.readProcessBundleID()

                // Skip system daemons (siri, coreaudio, etc.) - they shouldn't appear in the apps list
                if isSystemDaemon(bundleID: bundleID, name: name) { continue }

                // Merge helper process objectIDs into parent app entry
                if let existing = appsByPID[parentPID] {
                    if !existing.processObjectIDs.contains(objectID) {
                        var mergedIDs = existing.processObjectIDs
                        mergedIDs.append(objectID)
                        mergedIDs.sort()
                        appsByPID[parentPID] = AudioApp(
                            id: existing.id,
                            processObjectIDs: mergedIDs,
                            name: existing.name,
                            icon: existing.icon,
                            bundleID: existing.bundleID,
                            isHelperBacked: existing.isHelperBacked || isHelper,
                            audioProcessBundleIDs: Array(Set(
                                existing.audioProcessBundleIDs + [audioProcessBundleID].compactMap { $0 }
                            )).sorted(),
                            hasUnresolvedAudioProcessBundleMetadata:
                                existing.hasUnresolvedAudioProcessBundleMetadata
                                || audioProcessBundleID == nil
                                || audioProcessBundleID?.isEmpty == true
                        )
                    }
                } else {
                    appsByPID[parentPID] = AudioApp(
                        id: parentPID,
                        processObjectIDs: [objectID],
                        name: name,
                        icon: icon,
                        bundleID: bundleID,
                        isHelperBacked: isHelper,
                        audioProcessBundleIDs: [audioProcessBundleID].compactMap { $0 },
                        hasUnresolvedAudioProcessBundleMetadata:
                            audioProcessBundleID == nil || audioProcessBundleID?.isEmpty == true
                    )
                }
            }

            // Update per-process listeners
            updateProcessListeners(for: processIDs)
            guard snapshotComplete else {
                successfulSnapshotGeneration = nil
                // Keep the last complete view; a transient PID read must not pretend
                // an app exited or allow recovery to succeed with a partial snapshot.
                return
            }

            let connected = Self.coalesceLogicalApps(Array(appsByPID.values))
            let active = Self.appsRunningAudio(from: connected) { objectID in
                objectID.readProcessIsRunning()
            }
            activeOutputApps = Self.appsRunningAudio(from: connected) { objectID in
                var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var running: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &running) == noErr && running != 0
            }

            // Fire when either lifecycle surface changes. In particular, a newly connected
            // but not-yet-running process must wake AudioEngine so its saved volume tap can
            // be armed before the process submits its first output buffer.
            let lifecycleChanged = Self.lifecycleChanged(
                oldConnected: connectedApps,
                oldActive: activeApps,
                newConnected: connected,
                newActive: active
            )

            connectedApps = connected
            activeApps = active
            if snapshotComplete { successfulSnapshotGeneration = listenerGeneration }
            if lifecycleChanged {
                onAppsChanged?(activeApps)
            }

        } catch {
            successfulSnapshotGeneration = nil
            logger.error("Failed to refresh process list: \(error.localizedDescription)")
        }
    }

    /// CoreAudio may expose more than one responsible PID for one bundle (parallel app
    /// instances or a relaunch overlap). One logical mixer strip must have one CATap producer,
    /// so merge every process object into a single AudioApp before AudioEngine creates taps.
    nonisolated static func coalesceLogicalApps(_ apps: [AudioApp]) -> [AudioApp] {
        let grouped = Dictionary(grouping: apps, by: \.persistenceIdentifier)
        return grouped.values.compactMap { group in
            guard let representative = group.min(by: { $0.id < $1.id }) else { return nil }
            let objectIDs = Array(Set(group.flatMap(\.processObjectIDs))).sorted()
            return AudioApp(
                id: representative.id,
                processObjectIDs: objectIDs,
                name: representative.name,
                icon: representative.icon,
                bundleID: representative.bundleID,
                isHelperBacked: group.contains(where: \.isHelperBacked),
                audioProcessBundleIDs: Array(Set(group.flatMap(\.audioProcessBundleIDs))).sorted(),
                hasUnresolvedAudioProcessBundleMetadata: group.contains(
                    where: \.hasUnresolvedAudioProcessBundleMetadata
                )
            )
        }
        .sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
        }
    }

    /// Keeps the UI's historical "active" meaning separate from HAL connection state.
    /// A logical app is active when any of its (possibly helper-backed) process objects
    /// reports audio IO in progress.
    nonisolated static func appsRunningAudio(
        from connectedApps: [AudioApp],
        isRunning: (AudioObjectID) -> Bool
    ) -> [AudioApp] {
        connectedApps.filter { app in
            app.processObjectIDs.contains(where: isRunning)
        }
    }

    /// Process metadata can settle after Core Audio publishes the object. Treat bundle,
    /// helper, and display identity changes as lifecycle changes even when PID/object IDs
    /// are stable so AudioEngine can rebuild an under-specified restoring tap.
    nonisolated static func lifecycleChanged(
        oldConnected: [AudioApp],
        oldActive: [AudioApp],
        newConnected: [AudioApp],
        newActive: [AudioApp]
    ) -> Bool {
        Set(oldConnected.map(AppFingerprint.init)) != Set(newConnected.map(AppFingerprint.init))
            || Set(oldActive.map(AppFingerprint.init)) != Set(newActive.map(AppFingerprint.init))
    }

    private func updateProcessListeners(for processIDs: [AudioObjectID]) {
        let currentSet = Set(processIDs)

        // Remove listeners for processes that are gone
        let removed = monitoredProcesses.subtracting(currentSet)
        for objectID in removed {
            removeProcessListener(for: objectID)
        }

        // Add listeners for new processes
        let added = currentSet.filter {
            processListenerBlocks[$0] == nil || !outputListenerProcessIDs.contains($0)
        }
        for objectID in added {
            addProcessListener(for: objectID)
        }

        monitoredProcesses = Set(processListenerBlocks.keys)
    }

    private func addProcessListener(for objectID: AudioObjectID) {
        let generation = listenerGeneration
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = processListenerBlocks[objectID] ?? { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard self?.listenerGeneration == generation else { return }
                self?.refresh()
            }
        }

        if processListenerBlocks[objectID] == nil {
            let status = AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block)
            guard status == noErr else {
                logger.warning("Failed to add isRunning listener for \(objectID): \(status)")
                return
            }
            // Retain each successful selector even when the second add fails. A
            // best-effort rollback could itself fail and leak duplicate callbacks.
            processListenerBlocks[objectID] = block
        }
        guard !outputListenerProcessIDs.contains(objectID) else { return }
        address.mSelector = kAudioProcessPropertyIsRunningOutput
        let outputStatus = AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block)
        if outputStatus == noErr {
            outputListenerProcessIDs.insert(objectID)
        } else {
            logger.warning("Failed to add output activity listener for \(objectID): \(outputStatus)")
        }
    }

    private func removeProcessListener(for objectID: AudioObjectID) {
        guard let block = processListenerBlocks.removeValue(forKey: objectID) else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
        if outputListenerProcessIDs.remove(objectID) != nil {
            address.mSelector = kAudioProcessPropertyIsRunningOutput
            AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
        }
        // Tolerate kAudioHardwareBadObjectError (-66680): process object already destroyed
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove isRunning listener for \(objectID): \(status)")
        }
    }

    private func removeAllProcessListeners() {
        for objectID in monitoredProcesses {
            removeProcessListener(for: objectID)
        }
        monitoredProcesses.removeAll()
        processListenerBlocks.removeAll()
        outputListenerProcessIDs.removeAll()
    }

}
