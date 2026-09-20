import AppKit
import Foundation
import NetworkExtension
import ServiceManagement
import PipeCore

/// Single source of truth for the UI. Owns config, the extension lifecycle and live status.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: PipeConfig
    @Published private(set) var statuses: [UUID: RouteStatus] = [:]
    @Published private(set) var installedApps: [InstalledApp] = []
    @Published private(set) var recentAppIDs: [String]
    @Published var syncError: String?
    /// Last "Test Connection" result per proxy, persisted so the Proxies screen shows latency and location.
    @Published private(set) var testResults: [UUID: ProxyTestResult] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(testResults), forKey: "testResults") }
    }
    @Published var hasCompletedSetup: Bool {
        didSet { UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup") }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    let installer = ExtensionInstaller()
    let tunnel = TunnelController()
    private let store = ConfigStore()
    private var pollTask: Task<Void, Never>?
    /// Poll faster while the main window is showing live status.
    var isWindowVisible = false

    init() {
        config = store.load()
        recentAppIDs = UserDefaults.standard.stringArray(forKey: "recentAppIDs") ?? []
        testResults = UserDefaults.standard.data(forKey: "testResults").flatMap { try? JSONDecoder().decode([UUID: ProxyTestResult].self, from: $0) } ?? [:]
        hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Lifecycle

    func start() async {
        await tunnel.load()
        installedApps = await AppDiscovery.scan()
        if hasCompletedSetup {
            // Re-submit activation on every launch so an updated extension replaces the old one.
            // Already-approved extensions are replaced without any new prompt.
            try? await installer.activate()
            await sync()
        }
        startPolling()
    }

    /// First run: install the extension, then push the (probably empty) configuration.
    func completeSetup() async throws {
        try await installer.activate()
        hasCompletedSetup = true
        await sync()
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Proxies

    func saveProxy(_ profile: ProxyProfile, password: String?) {
        if let i = config.proxies.firstIndex(where: { $0.id == profile.id }) {
            config.proxies[i] = profile
        } else {
            config.proxies.append(profile)
        }
        KeychainStore.setPassword(profile.username == nil ? nil : password, for: profile.id)
        Task { await sync() }
    }

    func deleteProxy(_ id: UUID) {
        config.proxies.removeAll { $0.id == id }
        config.routes.removeAll { $0.proxyID == id }
        KeychainStore.delete(id)
        testResults[id] = nil
        Task { await sync() }
    }

    func password(for proxy: ProxyProfile) -> String? {
        proxy.username == nil ? nil : KeychainStore.password(for: proxy.id)
    }

    func endpoint(for proxy: ProxyProfile) -> ProxyEndpoint {
        ProxyEndpoint(profile: proxy, password: password(for: proxy))
    }

    func testProxy(_ profile: ProxyProfile, password: String?) async -> Result<ProxyTestResult, ProxyError> {
        do {
            let result = try await ProxyTester.test(ProxyEndpoint(profile: profile, password: password))
            testResults[profile.id] = result
            return .success(result)
        } catch let error as ProxyError {
            return .failure(error)
        } catch {
            return .failure(.protocolError(error.localizedDescription))
        }
    }

    // MARK: Routes

    func route(forApp bundleID: String) -> Route? {
        config.routes.first { $0.appBundleID == bundleID }
    }

    func addRoute(app: InstalledApp, proxy: ProxyProfile, killSwitch: Bool = true) {
        config.routes.removeAll { $0.appBundleID == app.bundleID }
        config.routes.append(Route(appBundleID: app.bundleID, appName: app.name, appPath: app.path, proxyID: proxy.id, isEnabled: true, killSwitch: killSwitch))
        recentAppIDs = ([app.bundleID] + recentAppIDs.filter { $0 != app.bundleID }).prefix(8).map { $0 }
        UserDefaults.standard.set(recentAppIDs, forKey: "recentAppIDs")
        Task { await sync() }
    }

    func updateRoute(_ route: Route) {
        guard let i = config.routes.firstIndex(where: { $0.id == route.id }) else { return }
        config.routes[i] = route
        Task { await sync() }
    }

    func deleteRoute(_ id: UUID) {
        config.routes.removeAll { $0.id == id }
        statuses[id] = nil
        Task { await sync() }
    }

    func setRoute(_ id: UUID, enabled: Bool) {
        guard var r = config.routes.first(where: { $0.id == id }) else { return }
        r.isEnabled = enabled
        updateRoute(r)
    }

    func setAllRoutes(enabled: Bool) {
        for i in config.routes.indices { config.routes[i].isEnabled = enabled }
        Task { await sync() }
    }

    var enabledRoutes: [Route] { config.routes.filter(\.isEnabled) }

    // MARK: Sync with the extension

    /// Save to disk, save into the system configuration, push passwords to the running extension.
    func sync() async {
        store.save(config)
        guard hasCompletedSetup else { return }
        do {
            try await tunnel.save(config)
            try await pushCredentials()
            syncError = nil
        } catch {
            syncError = error.localizedDescription
            Log.app.error("sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pushCredentials() async throws {
        // The session may take a moment to come up after save(); retry briefly.
        for attempt in 0..<10 {
            if tunnel.isRunning {
                let full = ExtensionConfig(proxies: config.proxies.map(endpoint(for:)), routes: config.routes)
                if case .error(let text)? = try await tunnel.send(.applyConfig(full)) { throw ProxyError.protocolError(text) }
                return
            }
            if !config.routes.contains(where: \.isEnabled) { return }
            try await Task.sleep(nanoseconds: UInt64(200_000_000 * (attempt + 1)))
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                let visible = self?.isWindowVisible ?? false
                try? await Task.sleep(nanoseconds: visible ? 2_000_000_000 : 10_000_000_000)
            }
        }
    }

    func refreshStatus() async {
        guard tunnel.isRunning else {
            if !statuses.isEmpty { statuses = [:] }
            return
        }
        guard case .status(let status)? = try? await tunnel.send(.getStatus) else { return }
        let fresh = Dictionary(uniqueKeysWithValues: status.routes.map { ($0.routeID, $0) })
        if fresh != statuses { statuses = fresh } // publish only real changes; every publish re-renders the window
        // Extension restarted (or booted) without our passwords: push them again.
        if !status.hasConfig || status.routes.contains(where: { $0.state == .missingCredential }) {
            try? await pushCredentials()
        }
    }

    // MARK: Helpers for views

    private var routeAppCache: [String: InstalledApp] = [:]

    /// Cached: called from every route card on every render.
    func installedApp(for route: Route) -> InstalledApp? {
        if let hit = routeAppCache[route.appBundleID] { return hit }
        let app = installedApps.first { $0.bundleID == route.appBundleID } ?? AppDiscovery.load(URL(fileURLWithPath: route.appPath))
        if let app { routeAppCache[route.appBundleID] = app }
        return app
    }

    func addAppManually(_ url: URL) -> InstalledApp? {
        guard let app = AppDiscovery.load(url) else { return nil }
        if !installedApps.contains(where: { $0.bundleID == app.bundleID }) {
            installedApps.append(app)
            installedApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return app
    }
}
