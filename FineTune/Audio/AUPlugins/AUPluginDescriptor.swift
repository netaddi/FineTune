// FineTune/Audio/AUPlugins/AUPluginDescriptor.swift
import AudioToolbox
import Foundation

struct AUPluginDescriptor: Codable, Identifiable, Equatable, Hashable {
    let componentType: UInt32
    let componentSubType: UInt32
    let componentManufacturer: UInt32
    let name: String
    let manufacturer: String
    let version: UInt32

    var id: String {
        "\(componentType)-\(componentSubType)-\(componentManufacturer)"
    }

    var audioComponentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    /// Softube Console 1's stable Audio Component identity (`aufx/ScPi/SfTb`).
    /// Names are localized and may change between releases, so track ordering must use
    /// the component codes rather than a display-name substring.
    var isSoftubeConsole1: Bool {
        componentType == kAudioUnitType_Effect
            && componentSubType == 0x5363_5069
            && componentManufacturer == 0x5366_5462
    }

    init(componentType: UInt32, componentSubType: UInt32, componentManufacturer: UInt32, name: String, manufacturer: String, version: UInt32) {
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
        self.name = name
        self.manufacturer = manufacturer
        self.version = version
    }

    init(component: AudioComponent, description: AudioComponentDescription) {
        self.componentType = description.componentType
        self.componentSubType = description.componentSubType
        self.componentManufacturer = description.componentManufacturer
        self.version = {
            var version: UInt32 = 0
            AudioComponentGetVersion(component, &version)
            return version
        }()

        var cfName: Unmanaged<CFString>?
        AudioComponentCopyName(component, &cfName)
        let fullName = cfName?.takeRetainedValue() as String? ?? "Unknown"

        if let colonRange = fullName.range(of: ": ") {
            self.manufacturer = String(fullName[fullName.startIndex..<colonRange.lowerBound])
            self.name = String(fullName[colonRange.upperBound...])
        } else {
            self.manufacturer = "Unknown"
            self.name = fullName
        }
    }
}
