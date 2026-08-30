// FineTuneTests/SettingsManagerAppSettingsBindingTests.swift
import Testing
import Foundation
@testable import FineTune

@MainActor
@Suite("SettingsManager.appSettings — direct binding setter")
struct SettingsManagerAppSettingsBindingTests {

    @Test("Direct assignment to appSettings persists the new value")
    func directAssignmentPersists() async {
        let manager = makeManager()
        var newSettings = manager.appSettings
        newSettings.defaultNewAppVolume = 0.42
        newSettings.lockInputDevice = true

        manager.appSettings = newSettings

        #expect(manager.appSettings.defaultNewAppVolume == 0.42)
        #expect(manager.appSettings.lockInputDevice == true)
    }

    @Test("Direct assignment forwards launch-at-login change to LaunchAtLoginService")
    func directAssignmentForwardsLaunchAtLogin() async {
        let service = RecordingLaunchAtLoginService()
        let manager = makeManager(launchAtLoginService: service)
        var newSettings = manager.appSettings
        let original = newSettings.launchAtLogin
        newSettings.launchAtLogin = !original

        manager.appSettings = newSettings

        #expect(manager.appSettings.launchAtLogin == !original)
        #expect(service.setEnabledCalls == [!original])
    }

    @Test("Direct assignment is equivalent to updateAppSettings for the same input")
    func directAssignmentEquivalentToUpdate() async {
        let managerA = makeManager()
        let managerB = makeManager()

        var modified = managerA.appSettings
        modified.defaultNewAppVolume = 0.7
        modified.mediaKeyControlEnabled = true
        modified.showDeviceDisconnectAlerts = false

        managerA.appSettings = modified
        managerB.updateAppSettings(modified)

        #expect(managerA.appSettings == managerB.appSettings)
    }

    @Test("Launch-at-login failure rolls the observable and persisted value back")
    func launchAtLoginFailureRollsBack() {
        let service = RecordingLaunchAtLoginService()
        service.errorToThrow = TestLaunchAtLoginError.rejected
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneBindingTests-\(UUID().uuidString)")
        let manager = SettingsManager(directory: directory, launchAtLoginService: service)
        var newSettings = manager.appSettings
        newSettings.launchAtLogin = true

        manager.appSettings = newSettings
        manager.flushSync()

        #expect(manager.appSettings.launchAtLogin == false)
        let reloaded = SettingsManager(
            directory: directory,
            launchAtLoginService: service
        )
        #expect(reloaded.appSettings.launchAtLogin == false)
    }

    @Test("Reset rolls back launch-at-login when unregister is rejected")
    func resetLaunchAtLoginFailureRollsBack() {
        let service = RecordingLaunchAtLoginService()
        service.isEnabled = true
        service.errorToThrow = TestLaunchAtLoginError.rejected
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneBindingTests-\(UUID().uuidString)")
        let manager = SettingsManager(directory: directory, launchAtLoginService: service)

        manager.resetAllSettings()
        manager.flushSync()

        #expect(manager.appSettings.launchAtLogin == true)
        let reloaded = SettingsManager(
            directory: directory,
            launchAtLoginService: service
        )
        #expect(reloaded.appSettings.launchAtLogin == true)
    }

    private func makeManager(
        launchAtLoginService: (any LaunchAtLoginServicing)? = nil
    ) -> SettingsManager {
        SettingsManager(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("FineTuneBindingTests-\(UUID().uuidString)"),
            launchAtLoginService: launchAtLoginService
        )
    }
}

@MainActor
private final class RecordingLaunchAtLoginService: LaunchAtLoginServicing {
    var isEnabled = false
    var errorToThrow: Error?
    private(set) var setEnabledCalls: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        if let errorToThrow { throw errorToThrow }
        isEnabled = enabled
        setEnabledCalls.append(enabled)
    }
}

private enum TestLaunchAtLoginError: Error {
    case rejected
}
