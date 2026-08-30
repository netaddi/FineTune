// FineTune/Audio/AUPlugins/AUEffectChain.swift
import Foundation
import Darwin
import os

/// Immutable ordered chain of AU effect hosts.
///
/// When the chain changes (add/remove/reorder), build a new `AUEffectChain` and
/// atomically swap the pointer in `ProcessTapController`, then defer-destroy the
/// old chain after 500ms. Same pattern as `LoudnessEqualizer`.
///
/// ## RT-Safety
/// `process()` runs on CoreAudio's HAL I/O thread. Reads `_hosts`/`_hostCount`/`_isBypassed`
/// which are set once at init (except bypass, toggled from main thread).
final class AUEffectChain: @unchecked Sendable {

    let entries: [AUEffectChainEntry]
    let failedEntryIDs: Set<UUID>

    private let _hosts: [AUEffectHost]
    private let _hostCount: Int
    private nonisolated(unsafe) var _isBypassed: Bool = false
    private nonisolated(unsafe) var _userBypassed: Bool = false
    private nonisolated(unsafe) var _rateFailureBypassed: Bool = false
    /// A strip can briefly be visible to two HAL callbacks during tap handoff. Only one
    /// callback may render a stateful AU instance at a time; the loser passes audio through.
    private nonisolated(unsafe) var _rendering: Int32 = 0
    private(set) var sampleRate: Double

    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AUEffectChain")

    var isBypassed: Bool { _isBypassed }
    /// User intent is kept separate from the internal fail-closed rate latch. UI and
    /// persistence must not turn a transient safety bypass into a permanent user bypass.
    var isUserBypassed: Bool { _userBypassed }

    var maxTailTime: Double {
        var maxTail: Double = 0
        for host in _hosts where host.isEnabled {
            if host.tailTimeSeconds > maxTail {
                maxTail = host.tailTimeSeconds
            }
        }
        return maxTail
    }

    var hosts: [AUEffectHost] { _hosts }

    func host(for entryID: UUID) -> AUEffectHost? {
        _hosts.first { $0.entryID == entryID }
    }

    init(
        entries: [AUEffectChainEntry],
        sampleRate: Double,
        maxFrames: UInt32 = 4096,
        retainingDisabledConsole: Bool = false,
        forcingPresetReloadFor explicitPresetEntryID: UUID? = nil,
        preservingLiveStateFor liveStateHost: AUEffectHost? = nil,
        reusing previousChain: AUEffectChain? = nil
    ) {
        var seenEntryIDs = Set<UUID>()
        let uniqueEntries = entries.filter { seenEntryIDs.insert($0.id).inserted }
        self.entries = uniqueEntries
        self.sampleRate = sampleRate
        var hosts: [AUEffectHost] = []
        var failed = Set<UUID>()
        // Settings are user-editable JSON. A corrupt chain can contain duplicate UUIDs;
        // keep the first entry instead of trapping in Dictionary(uniqueKeysWithValues:).
        let previousEntries = (previousChain?.entries ?? []).reduce(
            into: [UUID: AUEffectChainEntry]()
        ) { result, entry in
            if result[entry.id] == nil { result[entry.id] = entry }
        }
        for entry in uniqueEntries {
            if let previousHost = previousChain?.host(for: entry.id),
               previousHost.descriptor.id == entry.pluginDescriptor.id {
                previousHost.setEnabled(entry.isEnabled)
                if !previousHost.reconfigure(sampleRate: sampleRate) {
                    // A previous immutable wrapper may still be finishing one HAL buffer.
                    // Never drop the reused host here: doing so would destroy Console 1's
                    // instance (and therefore its assigned track) when the old wrapper dies.
                    // attachPersistentAUEffectChain retries the rate change after the swap.
                    logger.warning("Deferred rate reconfiguration for \(entry.pluginDescriptor.name)")
                }

                let previousEntry = previousEntries[entry.id]
                if previousHost === liveStateHost {
                    // The editor already changed this exact instance. Update immutable
                    // wrapper metadata without loading its just-saved ClassInfo back into
                    // the source host; independent hosts still receive the new state.
                } else if entry.id == explicitPresetEntryID {
                    if let presetData = entry.presetData {
                        _ = previousHost.loadPreset(presetData)
                    } else if let presetIndex = entry.selectedFactoryPresetIndex {
                        _ = previousHost.selectFactoryPreset(index: presetIndex)
                    } else {
                        _ = previousHost.restoreDefaultPreset()
                    }
                } else if entry.presetData != previousEntry?.presetData, let presetData = entry.presetData {
                    _ = previousHost.loadPreset(presetData)
                } else if entry.selectedFactoryPresetIndex != previousEntry?.selectedFactoryPresetIndex,
                          let presetIndex = entry.selectedFactoryPresetIndex {
                    _ = previousHost.selectFactoryPreset(index: presetIndex)
                } else if entry.presetData == nil,
                          entry.selectedFactoryPresetIndex == nil,
                          (previousEntry?.presetData != nil
                            || previousEntry?.selectedFactoryPresetIndex != nil) {
                    _ = previousHost.restoreDefaultPreset()
                }
                hosts.append(previousHost)
                continue
            }

            // Only crash-quarantined entries skip third-party construction. A normal
            // user-disabled Console 1 must still instantiate in deterministic slot order
            // so disabling it across a restart does not surrender its stable track.
            guard entry.shouldInstantiateOnColdStart(
                retainingDisabledConsole: retainingDisabledConsole
            ) else { continue }

            let host = AUEffectHost(
                descriptor: entry.pluginDescriptor,
                entryID: entry.id,
                sampleRate: sampleRate,
                maxFrames: maxFrames,
                enabled: entry.isEnabled
            )
            if host.instantiate() {
                if let presetData = entry.presetData {
                    _ = host.loadPreset(presetData)
                } else if let presetIndex = entry.selectedFactoryPresetIndex {
                    _ = host.selectFactoryPreset(index: presetIndex)
                }
                hosts.append(host)
            } else {
                failed.insert(entry.id)
                logger.error("Failed to instantiate \(entry.pluginDescriptor.name), skipping")
            }
        }
        self.failedEntryIDs = failed
        self._hosts = hosts
        self._hostCount = hosts.count
        self._userBypassed = previousChain?._userBypassed ?? false
        let hostsMatchRequestedFormat = hosts.allSatisfy {
            $0.isFormatValid && abs($0.configuredSampleRate - sampleRate) <= 0.5
        }
        self._rateFailureBypassed = !hostsMatchRequestedFormat
        self._isBypassed = _userBypassed || _rateFailureBypassed

        logger.info("Created AU effect chain with \(hosts.count)/\(uniqueEntries.count) plugins at \(sampleRate)Hz")
    }

    // MARK: - Bypass

    func setBypassed(_ bypassed: Bool) {
        _userBypassed = bypassed
        _isBypassed = bypassed || _rateFailureBypassed
    }

    /// Captures live ClassInfo state without replacing any Audio Unit instances.
    func entriesWithLiveState() -> [AUEffectChainEntry] {
        var result = entries
        for host in _hosts {
            guard let index = result.firstIndex(where: { $0.id == host.entryID }),
                  let presetData = host.savePreset() else { continue }
            result[index] = result[index].mergingLivePresetData(
                presetData,
                matchesLastAppliedPreset: host.liveStateMatchesLastAppliedPreset(presetData)
            )
        }
        return result
    }

    /// Reconfigures every host in place. Call only while the chain is detached from RT
    /// rendering (for example between stopping the old tap and promoting the new tap).
    @discardableResult
    func reconfigure(sampleRate newSampleRate: Double) -> Bool {
        guard newSampleRate.isFinite, newSampleRate > 0 else { return false }
        let needsReconfiguration = _hosts.contains {
            !$0.isFormatValid || abs($0.configuredSampleRate - newSampleRate) > 0.5
        }
        guard needsReconfiguration else {
            sampleRate = newSampleRate
            // Every host is explicitly known to be initialized at the requested rate.
            // This is also the recovery path after a failed target-rate attempt whose
            // rollback to the old rate succeeded.
            _rateFailureBypassed = false
            _isBypassed = _userBypassed
            return true
        }
        guard OSAtomicCompareAndSwap32Barrier(0, 1, &_rendering) else { return false }
        defer { _ = OSAtomicCompareAndSwap32Barrier(1, 0, &_rendering) }
        let previousSampleRate = sampleRate
        var reconfiguredHosts: [AUEffectHost] = []
        for host in _hosts {
            guard host.reconfigure(sampleRate: newSampleRate) else {
                // Do not leave a multi-plugin strip split across sample rates. Each host
                // already attempts its own rollback; explicitly roll back earlier hosts too.
                for changedHost in reconfiguredHosts.reversed() {
                    _ = changedHost.reconfigure(sampleRate: previousSampleRate)
                }
                // A failing AU may also have failed its internal rollback. Preserve the
                // instances for track identity, but never feed old-rate audio through a
                // potentially mixed-rate or uninitialized chain.
                _rateFailureBypassed = true
                _isBypassed = true
                return false
            }
            reconfiguredHosts.append(host)
        }
        sampleRate = newSampleRate
        _rateFailureBypassed = false
        _isBypassed = _userBypassed
        return true
    }

    // MARK: - RT-Safe Processing

    /// Process interleaved stereo samples through the entire AU chain in-place.
    @inline(__always)
    func processInterleaved(samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !_isBypassed else { return }
        guard OSAtomicCompareAndSwap32Barrier(0, 1, &_rendering) else {
            // A second tap is finishing a handoff with the same persistent strip. Passing
            // through for one buffer is safer than concurrently mutating a stateful AU.
            return
        }
        defer { _ = OSAtomicCompareAndSwap32Barrier(1, 0, &_rendering) }
        let count = _hostCount
        for i in 0..<count {
            _hosts[i].renderInterleaved(samples: samples, frameCount: frameCount)
        }
    }
}
