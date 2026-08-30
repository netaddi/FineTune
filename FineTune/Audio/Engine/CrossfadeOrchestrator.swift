// FineTune/Audio/Engine/CrossfadeOrchestrator.swift
import AudioToolbox
import os

/// Error types for crossfade and tap operations
enum CrossfadeError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case deviceNotReady
    case sampleRateUnavailable
    case secondaryTapFailed
    case secondaryWarmupTimedOut
    case noTapDescription
    case persistentAURequiresDestructiveSwitch
    case persistentAUReconfigurationFailed(Double)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            return "Failed to create process tap: \(status)"
        case .aggregateCreationFailed(let status):
            return "Failed to create aggregate device: \(status)"
        case .deviceNotReady:
            return "Device not ready within timeout"
        case .sampleRateUnavailable:
            return "Aggregate device sample rate was unavailable"
        case .secondaryTapFailed:
            return "Secondary tap invalid after timeout"
        case .secondaryWarmupTimedOut:
            return "Secondary tap did not render enough warmup audio"
        case .noTapDescription:
            return "No tap description available"
        case .persistentAURequiresDestructiveSwitch:
            return "A persistent app Audio Unit requires a single-producer device switch"
        case .persistentAUReconfigurationFailed(let sampleRate):
            return "Persistent app Audio Unit rejected \(sampleRate) Hz"
        }
    }
}

/// Configuration for crossfade behavior during device switching.
/// The crossfade overlaps audio from old and new devices using equal-power curves
/// to maintain perceived loudness during the transition.
enum CrossfadeConfig {
    /// 50ms is short enough to feel instantaneous but long enough to avoid clicks.
    /// Shorter durations risk audible artifacts; longer durations feel sluggish.
    /// Can be overridden via UserDefaults for testing/debugging.
    static let defaultDuration: TimeInterval = 0.050  // 50ms

    static var duration: TimeInterval {
        let custom = UserDefaults.standard.double(forKey: "FineTuneCrossfadeDuration")
        return custom > 0 ? custom : defaultDuration
    }

    static func totalSamples(at sampleRate: Double) -> Int64 {
        max(1, Int64(sampleRate * duration))
    }
}
