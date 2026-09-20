import Foundation
import Network
import PipeCore

/// Holds the live config, proxy health and per-route counters. Everything in here is touched
/// from many relay tasks and from the synchronous handleNewFlow, so it is lock-protected.
final class RouteEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var proxies: [UUID: ProxyEndpoint] = [:]
    private var routes: [UUID: Route] = [:]
    private var health: [UUID: ProxyHealth] = [:]
    private var counters: [UUID: RouteCounters] = [:]
    private var probes: [UUID: Task<Void, Never>] = [:]
    private(set) var hasConfig = false
    let matcher = FlowMatcher()
    let queue = DispatchQueue(label: "\(PipeIdentifiers.extensionBundleID).relay", attributes: .concurrent)

    struct ProxyHealth {
        var isDown = false
        var lastError: String?
    }

    struct RouteCounters {
        var active = 0
        var bytesUp: UInt64 = 0
        var bytesDown: UInt64 = 0
        var lastSuccess: Date?
        var lastError: String?
    }

    /// What a new flow should do.
    enum Decision {
        case proxy(Route, ProxyEndpoint)
        case direct(Route)          // kill switch off, proxy unavailable
        case block(Route, String)   // kill switch on, proxy unavailable

        var label: String {
            switch self {
            case .proxy(_, let e): return "via \(e.profile.host):\(e.profile.port)"
            case .direct: return "direct (kill switch off, proxy down)"
            case .block(_, let why): return "blocked (\(why))"
            }
        }
    }

    // MARK: Config

    func apply(_ config: ExtensionConfig) {
        lock.lock()
        proxies = Dictionary(uniqueKeysWithValues: config.proxies.map { ($0.id, $0) })
        routes = Dictionary(uniqueKeysWithValues: config.routes.map { ($0.id, $0) })
        // A new config is a fresh start for proxy health: the user may have fixed the host, port
        // or password, and a probe loop holding the old endpoint would never notice.
        health.removeAll()
        probes.values.forEach { $0.cancel() }
        probes.removeAll()
        for id in Array(counters.keys) where routes[id] == nil { counters[id] = nil }
        hasConfig = true
        lock.unlock()
        matcher.update(routes: config.routes)
        Log.ext.info("config applied: \(config.routes.count) routes, \(config.proxies.count) proxies")
    }

    func clear() {
        lock.lock()
        proxies = [:]; routes = [:]; health = [:]; counters = [:]
        probes.values.forEach { $0.cancel() }
        probes = [:]
        hasConfig = false
        lock.unlock()
        matcher.update(routes: [])
    }

    // MARK: Decisions

    func decide(for route: Route) -> Decision {
        lock.lock(); defer { lock.unlock() }
        guard let endpoint = proxies[route.proxyID] else {
            return route.killSwitch ? .block(route, "proxy not configured") : .direct(route)
        }
        if endpoint.profile.username != nil, endpoint.password == nil {
            counters[route.id, default: .init()].lastError = "Waiting for Pipe to supply the proxy password"
            return route.killSwitch ? .block(route, "missing credential") : .direct(route)
        }
        if let h = health[route.proxyID], h.isDown {
            return route.killSwitch ? .block(route, h.lastError ?? "proxy unreachable") : .direct(route)
        }
        return .proxy(route, endpoint)
    }

    // MARK: Health

    /// Errors that mean "the proxy itself is unavailable", as opposed to "this destination failed".
    func reportProxyFailure(_ error: ProxyError, proxyID: UUID, routeID: UUID) {
        let marksDown: Bool
        switch error {
        case .unreachable, .timedOut, .dnsFailed, .tlsFailed, .authenticationRequired, .invalidCredentials, .authenticationFailed, .protocolError:
            marksDown = true
        default:
            marksDown = false
        }
        lock.lock()
        counters[routeID, default: .init()].lastError = error.localizedDescription
        if marksDown {
            let wasDown = health[proxyID]?.isDown ?? false
            health[proxyID] = ProxyHealth(isDown: true, lastError: error.localizedDescription)
            if !wasDown, let endpoint = proxies[proxyID] {
                Log.proxy.error("proxy \(endpoint.profile.host, privacy: .public):\(endpoint.profile.port) marked down: \(error.localizedDescription, privacy: .public)")
                probes[proxyID]?.cancel()
                probes[proxyID] = Task { [weak self] in await self?.probeUntilUp(endpoint) }
            }
        }
        lock.unlock()
    }

    func reportProxySuccess(proxyID: UUID, routeID: UUID) {
        lock.lock()
        health[proxyID] = ProxyHealth(isDown: false, lastError: nil)
        counters[routeID, default: .init()].lastSuccess = Date()
        counters[routeID]?.lastError = nil
        lock.unlock()
    }

    /// Reconnect attempts every few seconds while a proxy is down. Runs one probe per proxy,
    /// never one per flow, so a busy app does not hammer a dead proxy.
    private func probeUntilUp(_ endpoint: ProxyEndpoint) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            do {
                // Full handshake plus a CONNECT to a harmless target proves auth and reachability.
                let conn = try await ProxyConnector.connectTCP(through: endpoint, to: ProxyTarget(host: "www.apple.com", port: 443), queue: queue)
                conn.cancel()
                lock.lock()
                health[endpoint.id] = ProxyHealth(isDown: false, lastError: nil)
                probes[endpoint.id] = nil
                lock.unlock()
                Log.proxy.info("proxy \(endpoint.profile.host, privacy: .public) is back")
                return
            } catch let error as ProxyError {
                lock.lock()
                health[endpoint.id] = ProxyHealth(isDown: true, lastError: error.localizedDescription)
                lock.unlock()
            } catch {
                continue
            }
        }
    }

    // MARK: Counters

    func flowStarted(_ routeID: UUID) {
        lock.lock(); counters[routeID, default: .init()].active += 1; lock.unlock()
    }

    func flowEnded(_ routeID: UUID) {
        lock.lock(); counters[routeID, default: .init()].active = max(0, (counters[routeID]?.active ?? 1) - 1); lock.unlock()
    }

    func addBytes(_ routeID: UUID, up: Int = 0, down: Int = 0) {
        lock.lock()
        counters[routeID, default: .init()].bytesUp += UInt64(up)
        counters[routeID, default: .init()].bytesDown += UInt64(down)
        lock.unlock()
    }

    func status(extensionVersion: String) -> ExtensionStatus {
        lock.lock(); defer { lock.unlock() }
        let list = routes.values.filter(\.isEnabled).map { route -> RouteStatus in
            let c = counters[route.id] ?? .init()
            let endpoint = proxies[route.proxyID]
            let state: RouteState
            if let endpoint, endpoint.profile.username != nil, endpoint.password == nil {
                state = .missingCredential
            } else if endpoint == nil || (health[route.proxyID]?.isDown ?? false) {
                state = route.killSwitch ? .blocked : .fallbackDirect
            } else if c.active > 0 || (c.lastSuccess.map { Date().timeIntervalSince($0) < 30 } ?? false) {
                state = .connected
            } else {
                state = .idle
            }
            return RouteStatus(routeID: route.id, state: state, activeConnections: c.active, bytesUp: c.bytesUp, bytesDown: c.bytesDown,
                               lastError: health[route.proxyID]?.lastError ?? c.lastError)
        }
        return ExtensionStatus(routes: list.sorted { $0.routeID.uuidString < $1.routeID.uuidString }, hasConfig: hasConfig, extensionVersion: extensionVersion)
    }
}
