// FineTune/Views/Sheets/AUPluginWindow.swift
import AppKit
import AudioToolbox
import CoreAudioKit
import os

@MainActor
final class AUPluginWindowManager {
    static let shared = AUPluginWindowManager()

    /// A UI listener does not need to accept an unbounded parameter list from a
    /// third-party Audio Unit. This still leaves ample room for unusually large AUs.
    private static let maximumObservedParameterCount = 16_384

    private var windows: [UUID: NSWindow] = [:]
    /// Device entries are shared in settings but each tap owns a distinct host. Keep the
    /// concrete source identity so a different tap leaving that device cannot close an
    /// editor that is still backed by a live host.
    private var sourceHostIDs: [UUID: ObjectIdentifier] = [:]
    /// NSWindow.delegate is weak, so retain delegates until their windows close.
    private var windowDelegates: [UUID: WindowDelegate] = [:]
    private var saveCallbacks: [UUID: () -> Void] = [:]
    private var liveChangeCallbacks: [UUID: () -> Void] = [:]
    private var liveChangeListeners: [UUID: AUParameterListenerRef] = [:]
    private var liveChangeTasks: [UUID: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AUPluginWindow")

    func showWindow(
        for entryID: UUID,
        audioUnit: AudioUnit,
        pluginName: String,
        forceGeneric: Bool = false,
        sourceHost: AUEffectHost,
        onLiveChange: (() -> Void)? = nil,
        onSave: @escaping () -> Void
    ) {
        if let existing = windows[entryID] {
            existing.orderFrontRegardless()
            return
        }

        let contentView = forceGeneric ? loadGenericView(for: audioUnit) : (loadCustomView(for: audioUnit) ?? loadGenericView(for: audioUnit))

        let viewSize = contentView.fittingSize
        let width = max(viewSize.width, 400)
        let height = max(viewSize.height, 300)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = pluginName
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.center()
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let windowDelegate = WindowDelegate(entryID: entryID, manager: self)
        windowDelegates[entryID] = windowDelegate
        window.delegate = windowDelegate
        window.orderFrontRegardless()

        windows[entryID] = window
        sourceHostIDs[entryID] = ObjectIdentifier(sourceHost)
        saveCallbacks[entryID] = onSave
        if let onLiveChange {
            installLiveChangeListener(
                for: entryID,
                audioUnit: audioUnit,
                callback: onLiveChange
            )
        }
        logger.info("Opened AU window for \(pluginName)")
    }

    func closeWindow(for entryID: UUID) {
        removeLiveChangeListener(for: entryID)
        windows[entryID]?.close()
        windows.removeValue(forKey: entryID)
        sourceHostIDs.removeValue(forKey: entryID)
    }

    /// Closes only when `sourceHost` is the exact host used to construct the editor.
    /// Multiple app taps can carry the same device entry UUID with different AU instances.
    @discardableResult
    func closeWindow(for entryID: UUID, ifSourceIs sourceHost: AUEffectHost) -> Bool {
        guard sourceHostIDs[entryID] == ObjectIdentifier(sourceHost) else { return false }
        closeWindow(for: entryID)
        return true
    }

    func closeAllWindows() {
        // NSWindow.close() invokes the delegate synchronously, and the delegate removes
        // entries from these dictionaries. Snapshot first to avoid mutating a collection
        // while iterating it. Save exactly once before clearing callbacks.
        let callbacks = Array(saveCallbacks.values)
        let openWindows = Array(windows.values)
        for entryID in Array(liveChangeListeners.keys) {
            removeLiveChangeListener(for: entryID)
        }
        saveCallbacks.removeAll()
        windows.removeAll()
        sourceHostIDs.removeAll()
        for callback in callbacks {
            callback()
        }
        for window in openWindows {
            window.close()
        }
        windowDelegates.removeAll()
    }

    func saveAllOpenWindows() {
        for (_, callback) in saveCallbacks {
            callback()
        }
    }

    fileprivate func windowDidClose(entryID: UUID) {
        removeLiveChangeListener(for: entryID)
        saveCallbacks[entryID]?()
        saveCallbacks.removeValue(forKey: entryID)
        windows.removeValue(forKey: entryID)
        sourceHostIDs.removeValue(forKey: entryID)
        windowDelegates.removeValue(forKey: entryID)
    }

    /// Device effects have one host per app tap. Observe user-driven parameter changes
    /// only for device editors, then wait until interaction goes idle before snapshotting
    /// opaque ClassInfo. Per-app (including Console 1) editors never install this listener.
    private func installLiveChangeListener(
        for entryID: UUID,
        audioUnit: AudioUnit,
        callback: @escaping () -> Void
    ) {
        liveChangeCallbacks[entryID] = callback
        var listener: AUParameterListenerRef?
        let createStatus = AUListenerCreateWithDispatchQueue(
            &listener,
            0.1,
            DispatchQueue.main
        ) { [weak self] _, _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleLiveChangeSync(for: entryID)
            }
        }
        guard createStatus == noErr, let listener else {
            liveChangeCallbacks.removeValue(forKey: entryID)
            logger.warning("Could not observe AU parameter changes: \(createStatus)")
            return
        }

        var registeredCount = 0
        for var parameter in observableParameters(for: audioUnit) {
            if AUListenerAddParameter(listener, nil, &parameter) == noErr {
                registeredCount += 1
            }
        }
        guard registeredCount > 0 else {
            AUListenerDispose(listener)
            liveChangeCallbacks.removeValue(forKey: entryID)
            logger.warning("AU exposes no observable parameters; syncing when its window closes")
            return
        }
        liveChangeListeners[entryID] = listener
    }

    /// `kAUParameterListener_AnyParameter` is valid only when sending a notification;
    /// listener registration requires concrete IDs. Enumerate every exposed bus scope and
    /// element, deduplicating plugins that repeat global parameters on multiple buses.
    private func observableParameters(for audioUnit: AudioUnit) -> [AudioUnitParameter] {
        let scopes: [AudioUnitScope] = [
            kAudioUnitScope_Global,
            kAudioUnitScope_Input,
            kAudioUnitScope_Output,
        ]
        var parameters: [AudioUnitParameter] = []
        var seen = Set<String>()
        var remainingParameterBudget = Self.maximumObservedParameterCount

        for scope in scopes {
            var elementCount: UInt32 = 1
            var countSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioUnitGetProperty(
                audioUnit,
                kAudioUnitProperty_ElementCount,
                scope,
                0,
                &elementCount,
                &countSize
            ) != noErr {
                elementCount = 1
            }
            // A malformed third-party AU must not make opening an editor unbounded.
            let boundedElementCount = max(1, min(Int(elementCount), 64))

            for elementIndex in 0..<boundedElementCount {
                let element = AudioUnitElement(elementIndex)
                var byteCount: UInt32 = 0
                var writable = DarwinBoolean(false)
                guard AudioUnitGetPropertyInfo(
                    audioUnit,
                    kAudioUnitProperty_ParameterList,
                    scope,
                    element,
                    &byteCount,
                    &writable
                ) == noErr,
                    let parameterCount = Self.validatedParameterCount(
                        forByteCount: byteCount
                    ) else {
                    continue
                }
                // Bound the entire editor scan, not just each property response. A
                // pathological multi-bus AU could otherwise multiply the per-list cap.
                guard Self.consumeParameterBudget(
                    parameterCount,
                    remaining: &remainingParameterBudget
                ) else {
                    return parameters
                }

                var parameterIDs = [AudioUnitParameterID](
                    repeating: 0,
                    count: parameterCount
                )
                let allocatedByteCount = parameterIDs.count
                    * MemoryLayout<AudioUnitParameterID>.size
                var actualByteCount = UInt32(allocatedByteCount)
                let getStatus: OSStatus = parameterIDs.withUnsafeMutableBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else {
                        return kAudio_ParamError
                    }
                    return AudioUnitGetProperty(
                        audioUnit,
                        kAudioUnitProperty_ParameterList,
                        scope,
                        element,
                        baseAddress,
                        &actualByteCount
                    )
                }
                guard getStatus == noErr,
                    actualByteCount <= UInt32(allocatedByteCount),
                    actualByteCount % UInt32(MemoryLayout<AudioUnitParameterID>.size) == 0 else {
                    continue
                }

                let actualCount = Int(actualByteCount)
                    / MemoryLayout<AudioUnitParameterID>.size
                for parameterID in parameterIDs.prefix(actualCount) {
                    let key = "\(scope):\(element):\(parameterID)"
                    guard seen.insert(key).inserted else { continue }
                    parameters.append(AudioUnitParameter(
                        mAudioUnit: audioUnit,
                        mParameterID: parameterID,
                        mScope: scope,
                        mElement: element
                    ))
                }
            }
        }
        return parameters
    }

    private static func validatedParameterCount(forByteCount byteCount: UInt32) -> Int? {
        let parameterSize = UInt32(MemoryLayout<AudioUnitParameterID>.size)
        guard byteCount >= parameterSize,
            byteCount % parameterSize == 0 else {
            return nil
        }
        let parameterCount = Int(byteCount / parameterSize)
        guard parameterCount <= maximumObservedParameterCount else { return nil }
        return parameterCount
    }

    private static func consumeParameterBudget(
        _ parameterCount: Int,
        remaining: inout Int
    ) -> Bool {
        guard parameterCount > 0, parameterCount <= remaining else { return false }
        remaining -= parameterCount
        return true
    }

    #if DEBUG
    static func validatedParameterCountForTesting(byteCount: UInt32) -> Int? {
        validatedParameterCount(forByteCount: byteCount)
    }

    static func consumeParameterBudgetForTesting(
        _ parameterCount: Int,
        remaining: inout Int
    ) -> Bool {
        consumeParameterBudget(parameterCount, remaining: &remaining)
    }

    func observableParameterCountForTesting(_ audioUnit: AudioUnit) -> Int {
        observableParameters(for: audioUnit).count
    }

    func installLiveChangeListenerForTesting(
        entryID: UUID,
        audioUnit: AudioUnit,
        callback: @escaping () -> Void
    ) -> Bool {
        installLiveChangeListener(
            for: entryID,
            audioUnit: audioUnit,
            callback: callback
        )
        return liveChangeListeners[entryID] != nil
    }

    func notifyFirstObservableParameterForTesting(_ audioUnit: AudioUnit) -> Bool {
        for var parameter in observableParameters(for: audioUnit) {
            var info = AudioUnitParameterInfo()
            var infoSize = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            guard AudioUnitGetProperty(
                audioUnit,
                kAudioUnitProperty_ParameterInfo,
                parameter.mScope,
                parameter.mParameterID,
                &info,
                &infoSize
            ) == noErr,
                info.maxValue > info.minValue else {
                continue
            }
            var current: AudioUnitParameterValue = 0
            guard AudioUnitGetParameter(
                audioUnit,
                parameter.mParameterID,
                parameter.mScope,
                parameter.mElement,
                &current
            ) == noErr else {
                continue
            }
            let midpoint = info.minValue + ((info.maxValue - info.minValue) / 2)
            let newValue = current > midpoint ? info.minValue : info.maxValue
            return AUParameterSet(nil, nil, &parameter, newValue, 0) == noErr
        }
        return false
    }

    func removeLiveChangeListenerForTesting(entryID: UUID) {
        removeLiveChangeListener(for: entryID)
    }

    func hasOpenWindowForTesting(entryID: UUID) -> Bool {
        windows[entryID] != nil
    }
    #endif

    private func scheduleLiveChangeSync(for entryID: UUID) {
        liveChangeTasks[entryID]?.cancel()
        liveChangeTasks[entryID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.liveChangeCallbacks[entryID]?()
            self.liveChangeTasks.removeValue(forKey: entryID)
        }
    }

    private func removeLiveChangeListener(for entryID: UUID) {
        liveChangeTasks.removeValue(forKey: entryID)?.cancel()
        liveChangeCallbacks.removeValue(forKey: entryID)
        if let listener = liveChangeListeners.removeValue(forKey: entryID) {
            AUListenerDispose(listener)
        }
    }

    // MARK: - View Loading

    private func loadCustomView(for audioUnit: AudioUnit) -> NSView? {
        // Query kAudioUnitProperty_CocoaUI — returns a struct with a bundle URL
        // and an array of class name strings. We only use the first class.
        var dataSize: UInt32 = 0
        var writable: DarwinBoolean = false
        let infoErr = AudioUnitGetPropertyInfo(
            audioUnit,
            kAudioUnitProperty_CocoaUI,
            kAudioUnitScope_Global, 0,
            &dataSize,
            &writable
        )
        guard infoErr == noErr, dataSize > 0 else { return nil }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { buffer.deallocate() }

        var actualSize = dataSize
        let getErr = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_CocoaUI,
            kAudioUnitScope_Global, 0,
            buffer,
            &actualSize
        )
        guard getErr == noErr else { return nil }

        let viewInfo = buffer.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self).pointee

        let bundleURL = viewInfo.mCocoaAUViewBundleLocation.takeRetainedValue() as URL

        let classNameRef: Unmanaged<CFString> = viewInfo.mCocoaAUViewClass
        let className = classNameRef.takeRetainedValue() as String

        guard let bundle = Bundle(url: bundleURL), bundle.load() else {
            logger.warning("Failed to load AU view bundle at \(bundleURL.path)")
            return nil
        }

        // The class must implement the informal AUCocoaUIBase protocol:
        //   - (NSView *)uiViewForAudioUnit:(AudioUnit)au withSize:(NSSize)size
        guard let viewClass = bundle.classNamed(className) as? NSObject.Type else {
            logger.warning("Class \(className) not found in bundle")
            return nil
        }

        let selector = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        guard viewClass.instancesRespond(to: selector) else {
            logger.warning("\(className) does not implement uiViewForAudioUnit:withSize:")
            return nil
        }

        let factory = viewClass.init()
        let size = NSSize(width: 400, height: 300)

        // Call via IMP with correct C types — NSObject.perform() would corrupt
        // the AudioUnit pointer (OpaquePointer, not AnyObject).
        typealias AUViewFactoryIMP = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> NSView?
        guard let method = class_getInstanceMethod(viewClass, selector) else {
            logger.warning("Failed to get method for \(selector)")
            return nil
        }
        let imp = method_getImplementation(method)
        let factoryFunc = unsafeBitCast(imp, to: AUViewFactoryIMP.self)
        guard let view = factoryFunc(factory, selector, audioUnit, size) else {
            logger.warning("uiViewForAudioUnit:withSize: returned nil")
            return nil
        }

        logger.info("Loaded custom Cocoa AU view via \(className)")
        return view
    }

    private func loadGenericView(for audioUnit: AudioUnit) -> NSView {
        let view = AUGenericView(audioUnit: audioUnit)
        view.showsExpertParameters = true
        return view
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate {
    let entryID: UUID
    weak var manager: AUPluginWindowManager?

    init(entryID: UUID, manager: AUPluginWindowManager) {
        self.entryID = entryID
        self.manager = manager
    }

    func windowWillClose(_ notification: Notification) {
        manager?.windowDidClose(entryID: entryID)
    }
}
