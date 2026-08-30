// FineTune/Audio/AUPlugins/AUEffectHost.swift
import AudioToolbox
import Darwin
import Foundation
import os

/// RT-safe wrapper around a single Audio Unit effect instance.
///
/// ## Threading Model
/// - **Main thread**: instantiation, preset loading, teardown
/// - **HAL I/O thread**: `render()` — RT-safe once the AU is initialized
///
/// ## Audio Format
/// Apple AUs require non-interleaved stereo (separate L/R buffers). Our pipeline
/// uses interleaved stereo (LRLRLR...). This host handles the conversion:
/// deinterleave before AU render, interleave after.
///
/// Follows the same deferred-destroy pattern as `BiquadProcessor`.
final class AUEffectHost: @unchecked Sendable {

    let descriptor: AUPluginDescriptor
    let entryID: UUID

    private nonisolated(unsafe) var _audioUnit: AudioUnit?
    private nonisolated(unsafe) var _isEnabled: Bool
    private nonisolated(unsafe) var _sampleTime: Float64 = 0
    private var isTrackedByCrashGuard = false
    /// ClassInfo captured immediately after initialization. Restoring this state resets a
    /// reused Console 1 instance without destroying it (and therefore without changing track).
    private var defaultPresetData: Data?
    /// Normalized ClassInfo immediately after the last explicit Default/factory/custom load.
    /// Direct edits in a plugin's own UI do not update this marker, allowing shutdown saves
    /// to preserve a preset label when nothing changed and capture custom state when it did.
    private var lastAppliedPresetData: Data?
    /// Guards this stateful instance when immutable chain wrappers overlap briefly.
    private nonisolated(unsafe) var _rendering: Int32 = 0

    // Pre-allocated deinterleaved buffers for AU rendering (RT-safe).
    // Accessed by the C render callback — must not be private.
    let _bufferL: UnsafeMutablePointer<Float>
    let _bufferR: UnsafeMutablePointer<Float>
    let _bufferCapacity: Int

    /// Pre-allocated AudioBufferList with space for 2 AudioBuffers (non-interleaved stereo).
    /// Swift's AudioBufferList struct only has room for 1 buffer inline, so we heap-allocate
    /// at init time with correct size. RT-safe: no allocation in render path.
    private let _ablPtr: UnsafeMutablePointer<AudioBufferList>

    private(set) var factoryPresets: [(index: Int, name: String)] = []
    private(set) var tailTimeSeconds: Double = 0

    private let logger: Logger
    private var sampleRate: Double
    /// False only when both a requested format change and the attempt to restore the
    /// previous format failed. A wrapper rebuild must never make such a host renderable
    /// again until a later, successful `reconfigure` validates it in place.
    private(set) var isFormatValid = false
    private let maxFrames: UInt32

    var isEnabled: Bool { _isEnabled }
    var audioUnit: AudioUnit? { _audioUnit }
    var configuredSampleRate: Double { sampleRate }

    init(
        descriptor: AUPluginDescriptor,
        entryID: UUID,
        sampleRate: Double,
        maxFrames: UInt32 = 4096,
        enabled: Bool = true
    ) {
        self.descriptor = descriptor
        self.entryID = entryID
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        self._isEnabled = enabled
        self._bufferCapacity = Int(maxFrames)
        self._bufferL = .allocate(capacity: Int(maxFrames))
        self._bufferR = .allocate(capacity: Int(maxFrames))
        self._bufferL.initialize(repeating: 0, count: Int(maxFrames))
        self._bufferR.initialize(repeating: 0, count: Int(maxFrames))

        // Allocate AudioBufferList with space for 2 AudioBuffers.
        // AudioBufferList has 1 inline AudioBuffer; we need room for 1 extra.
        let ablSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        ablRaw.initializeMemory(as: UInt8.self, repeating: 0, count: ablSize)
        self._ablPtr = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)

        self.logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AUEffectHost[\(descriptor.name)]")
    }

    deinit {
        if let au = _audioUnit {
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        if isTrackedByCrashGuard {
            CrashGuard.untrackPlugin(descriptor.id)
        }
        _bufferL.deallocate()
        _bufferR.deallocate()
        _ablPtr.deallocate()
    }

    // MARK: - Instantiation (main thread)

    func instantiate() -> Bool {
        if _audioUnit != nil { return true }
        var desc = descriptor.audioComponentDescription
        guard let component = AudioComponentFindNext(nil, &desc) else {
            logger.error("AudioComponent not found for \(self.descriptor.name)")
            return false
        }

        // Third-party code may run inside AudioComponentInstanceNew and every AU call after
        // it. Track before crossing that boundary so a construction/initialize crash is
        // quarantined on the next launch instead of causing a crash loop.
        CrashGuard.trackPlugin(descriptor.id)
        isTrackedByCrashGuard = true

        func abandon(_ au: AudioUnit? = nil) {
            if let au { AudioComponentInstanceDispose(au) }
            if isTrackedByCrashGuard {
                CrashGuard.untrackPlugin(descriptor.id)
                isTrackedByCrashGuard = false
            }
        }

        var au: AudioUnit?
        var err = AudioComponentInstanceNew(component, &au)
        guard err == noErr, let au else {
            logger.error("AudioComponentInstanceNew failed: \(err)")
            abandon()
            return false
        }

        guard configureStreamFormat(on: au, sampleRate: sampleRate) else {
            logger.error("Audio Unit rejected the required non-interleaved stereo format")
            abandon(au)
            return false
        }

        var frames = maxFrames
        err = AudioUnitSetProperty(
            au, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0,
            &frames, UInt32(MemoryLayout<UInt32>.size)
        )
        guard err == noErr else {
            logger.error("Failed to set MaximumFramesPerSlice: \(err)")
            abandon(au)
            return false
        }

        var renderCallback = AURenderCallbackStruct(
            inputProc: auRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        err = AudioUnitSetProperty(
            au, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0,
            &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        if err != noErr {
            logger.error("Failed to set render callback: \(err)")
            abandon(au)
            return false
        }

        err = AudioUnitInitialize(au)
        if err != noErr {
            logger.error("AudioUnitInitialize failed: \(err)")
            abandon(au)
            return false
        }

        _audioUnit = au
        isFormatValid = true
        defaultPresetData = savePreset()
        lastAppliedPresetData = defaultPresetData
        loadFactoryPresets()
        queryTailTime()
        logger.info("Instantiated \(self.descriptor.name) at \(self.sampleRate)Hz")
        return true
    }

    // MARK: - Enable/Disable

    func setEnabled(_ enabled: Bool) {
        _isEnabled = enabled
    }

    /// Reconfigures the existing Audio Unit instance in place for a new device rate.
    /// Keeping the `AudioComponentInstance` alive is essential for Console 1: creating a
    /// replacement instance would allocate a new Console track. The caller must ensure the
    /// host is not currently rendering while this method runs.
    @discardableResult
    func reconfigure(sampleRate newSampleRate: Double) -> Bool {
        guard newSampleRate.isFinite, newSampleRate > 0 else { return false }
        // A failed rollback leaves the Audio Unit untrusted even when its cached rate
        // equals the requested rate. Force the full uninitialize/configure/initialize
        // cycle in that case instead of reporting a false recovery.
        guard abs(newSampleRate - sampleRate) > 0.5 || !isFormatValid else { return true }
        guard OSAtomicCompareAndSwap32Barrier(0, 1, &_rendering) else { return false }
        defer { _ = OSAtomicCompareAndSwap32Barrier(1, 0, &_rendering) }
        guard let au = _audioUnit else {
            isFormatValid = false
            return false
        }

        let previousSampleRate = sampleRate
        AudioUnitUninitialize(au)

        let formatConfigured = configureStreamFormat(on: au, sampleRate: newSampleRate)
        let initializeStatus = formatConfigured ? AudioUnitInitialize(au) : kAudio_ParamError
        guard formatConfigured, initializeStatus == noErr else {
            logger.error("Failed to reconfigure \(self.descriptor.name) to \(newSampleRate)Hz: \(initializeStatus)")
            let rollbackConfigured = configureStreamFormat(on: au, sampleRate: previousSampleRate)
            let rollbackStatus = rollbackConfigured ? AudioUnitInitialize(au) : kAudio_ParamError
            isFormatValid = rollbackConfigured && rollbackStatus == noErr
            if !isFormatValid {
                logger.error("Failed to restore \(self.descriptor.name) to \(previousSampleRate)Hz: \(rollbackStatus)")
            }
            return false
        }

        sampleRate = newSampleRate
        isFormatValid = true
        AudioUnitReset(au, kAudioUnitScope_Global, 0)
        queryTailTime()
        logger.info("Reconfigured \(self.descriptor.name) in place at \(newSampleRate)Hz")
        return true
    }

    // MARK: - RT-Safe Rendering

    /// Process interleaved stereo audio through this AU effect.
    /// Deinterleaves input → AU render (non-interleaved) → interleaves output.
    /// All buffers are pre-allocated — no allocations on the RT thread.
    @inline(__always)
    func renderInterleaved(samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard _isEnabled, let au = _audioUnit else { return }
        guard OSAtomicCompareAndSwap32Barrier(0, 1, &_rendering) else { return }
        defer { _ = OSAtomicCompareAndSwap32Barrier(1, 0, &_rendering) }
        let count = min(frameCount, _bufferCapacity)

        // Deinterleave: LRLRLR... → separate L and R buffers
        for i in 0..<count {
            _bufferL[i] = samples[i * 2]
            _bufferR[i] = samples[i * 2 + 1]
        }

        // Configure pre-allocated 2-buffer AudioBufferList (no stack corruption)
        let byteCount = UInt32(count * MemoryLayout<Float>.size)
        let ablBufs = UnsafeMutableAudioBufferListPointer(_ablPtr)
        _ablPtr.pointee.mNumberBuffers = 2
        ablBufs[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: _bufferL)
        ablBufs[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: _bufferR)

        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        timestamp.mSampleTime = _sampleTime
        _sampleTime += Float64(count)

        let err = AudioUnitRender(au, &flags, &timestamp, 0, UInt32(count), _ablPtr)
        if err != noErr { return }

        // Interleave: separate L and R → LRLRLR...
        for i in 0..<count {
            samples[i * 2] = _bufferL[i]
            samples[i * 2 + 1] = _bufferR[i]
        }
    }

    // MARK: - Presets

    func savePreset() -> Data? {
        guard let au = _audioUnit else { return nil }
        guard acquireNonRealtimeAccess() else {
            logger.warning("Timed out waiting to save preset state")
            return nil
        }
        defer { releaseExclusiveAccess() }
        return copyPresetData(from: au)
    }

    func loadPreset(_ data: Data) -> Bool {
        guard let au = _audioUnit else { return false }
        guard acquireNonRealtimeAccess() else {
            logger.warning("Timed out waiting to load preset state")
            return false
        }
        defer { releaseExclusiveAccess() }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        let cfPlist = plist as CFPropertyList
        var unmanagedPlist: Unmanaged<CFPropertyList>? = .passUnretained(cfPlist)
        let err = AudioUnitSetProperty(
            au, kAudioUnitProperty_ClassInfo,
            kAudioUnitScope_Global, 0,
            &unmanagedPlist, UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        )
        if err != noErr {
            logger.warning("Failed to load preset: \(err)")
            return false
        }
        lastAppliedPresetData = copyPresetData(from: au) ?? data
        queryTailTime()
        return true
    }

    func selectFactoryPreset(index: Int) -> Bool {
        guard let au = _audioUnit else { return false }
        guard acquireNonRealtimeAccess() else {
            logger.warning("Timed out waiting to select factory preset")
            return false
        }
        defer { releaseExclusiveAccess() }
        var preset = AUPreset(presetNumber: Int32(index), presetName: nil)
        let err = AudioUnitSetProperty(
            au, kAudioUnitProperty_PresentPreset,
            kAudioUnitScope_Global, 0,
            &preset, UInt32(MemoryLayout<AUPreset>.size)
        )
        if err != noErr {
            logger.warning("Failed to select factory preset \(index): \(err)")
            return false
        }
        lastAppliedPresetData = copyPresetData(from: au)
        queryTailTime()
        return true
    }

    /// Restores the state captured immediately after initialization while retaining this
    /// exact AudioComponentInstance. Returns false if the AU exposes no ClassInfo baseline.
    func restoreDefaultPreset() -> Bool {
        guard let defaultPresetData else { return false }
        return loadPreset(defaultPresetData)
    }

    func liveStateMatchesLastAppliedPreset(_ data: Data) -> Bool {
        guard let lastAppliedPresetData else { return false }
        if data == lastAppliedPresetData { return true }
        guard let live = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let applied = try? PropertyListSerialization.propertyList(
                from: lastAppliedPresetData,
                format: nil
              ) else { return false }
        return (live as? NSObject)?.isEqual(applied) == true
    }

    /// Advances the comparison marker after another host receives this live ClassInfo.
    /// Device-editor synchronization deliberately does not reload state into the source
    /// instance, so it must still mark the snapshot as committed. A later undo back to an
    /// older Default/factory value will then be detected as a new change.
    func markLivePresetDataAsApplied(_ data: Data) {
        lastAppliedPresetData = data
    }

    // MARK: - Private

    private func copyPresetData(from au: AudioUnit) -> Data? {
        var classInfo: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let err = AudioUnitGetProperty(
            au, kAudioUnitProperty_ClassInfo,
            kAudioUnitScope_Global, 0,
            &classInfo, &size
        )
        guard err == noErr, let plist = classInfo?.takeRetainedValue() else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    /// Whole-preset reads and writes are not real-time operations. Wait briefly for the
    /// current render to finish, then let any overlapping HAL buffer pass through while
    /// the property operation owns the host. The HAL thread itself never waits.
    private func acquireNonRealtimeAccess() -> Bool {
        for attempt in 0..<200 {
            if OSAtomicCompareAndSwap32Barrier(0, 1, &_rendering) {
                return true
            }
            if attempt < 199 { usleep(100) }
        }
        return false
    }

    private func releaseExclusiveAccess() {
        _ = OSAtomicCompareAndSwap32Barrier(1, 0, &_rendering)
    }

    private func configureStreamFormat(on au: AudioUnit, sampleRate: Double) -> Bool {
        // Non-interleaved stereo Float32 — the format all Apple AUs support.
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let inputStatus = AudioUnitSetProperty(
            au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0,
            &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        if inputStatus != noErr {
            logger.warning("Failed to set input stream format: \(inputStatus)")
        }

        let outputStatus = AudioUnitSetProperty(
            au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0,
            &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        if outputStatus != noErr {
            logger.warning("Failed to set output stream format: \(outputStatus)")
        }
        return inputStatus == noErr && outputStatus == noErr
    }

    private func loadFactoryPresets() {
        guard let au = _audioUnit else { return }
        var unmanagedPresets: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let err = AudioUnitGetProperty(
            au, kAudioUnitProperty_FactoryPresets,
            kAudioUnitScope_Global, 0,
            &unmanagedPresets, &size
        )
        guard err == noErr, let cfArray = unmanagedPresets?.takeRetainedValue() else {
            factoryPresets = []
            return
        }

        let count = CFArrayGetCount(cfArray)
        var result: [(index: Int, name: String)] = []
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(cfArray, i) else { continue }
            let preset = ptr.load(as: AUPreset.self)
            let name: String
            if let cfName = preset.presetName {
                name = cfName.takeUnretainedValue() as String
            } else {
                name = "Preset \(preset.presetNumber)"
            }
            result.append((index: Int(preset.presetNumber), name: name))
        }
        factoryPresets = result
    }

    private func queryTailTime() {
        guard let au = _audioUnit else { return }
        var tailTime: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let err = AudioUnitGetProperty(
            au, kAudioUnitProperty_TailTime,
            kAudioUnitScope_Global, 0,
            &tailTime, &size
        )
        tailTimeSeconds = (err == noErr && tailTime.isFinite) ? tailTime : 0
    }
}

// MARK: - Render Callback (C function)

/// Provides input to the AU by copying from the host's pre-deinterleaved buffers.
/// Called synchronously by AudioUnitRender on the RT thread.
private func auRenderCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let host = Unmanaged<AUEffectHost>.fromOpaque(inRefCon).takeUnretainedValue()

    let outputBufs = UnsafeMutableAudioBufferListPointer(ioData)

    // Copy deinterleaved L/R buffers into the AU's input buffers
    if outputBufs.count >= 1, let dst = outputBufs[0].mData {
        let copyBytes = min(Int(outputBufs[0].mDataByteSize), host._bufferCapacity * MemoryLayout<Float>.size)
        memcpy(dst, host._bufferL, copyBytes)
    }
    if outputBufs.count >= 2, let dst = outputBufs[1].mData {
        let copyBytes = min(Int(outputBufs[1].mDataByteSize), host._bufferCapacity * MemoryLayout<Float>.size)
        memcpy(dst, host._bufferR, copyBytes)
    }

    return noErr
}
