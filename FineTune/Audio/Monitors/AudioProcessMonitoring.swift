@MainActor
protocol AudioProcessMonitoring: AnyObject {
    /// Every non-system Core Audio client currently connected to the HAL, including
    /// clients whose audio IO has not started yet. AudioEngine uses this surface to
    /// arm saved volume limits before the first output buffer.
    var connectedApps: [AudioApp] { get }
    var activeApps: [AudioApp] { get }
    /// Output-only activity; input-only clients must not trigger a stalled-output repair.
    var activeOutputApps: [AudioApp] { get }
    var onAppsChanged: (([AudioApp]) -> Void)? { get set }

    func start()
    func stop()
    func resetAfterServiceRestart()
    var isMonitoringReady: Bool { get }
}

extension AudioProcessMonitoring {
    var isMonitoringReady: Bool { true }
    /// Existing test doubles and alternate monitors that only expose active clients keep
    /// their previous behavior. The production monitor overrides this with the full HAL
    /// process-object list.
    var connectedApps: [AudioApp] { activeApps }
    var activeOutputApps: [AudioApp] { activeApps }
    func resetAfterServiceRestart() { stop() }
}
