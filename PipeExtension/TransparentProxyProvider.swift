import Foundation
import NetworkExtension
import Network
import PipeCore

/// The system extension entry point. macOS hands every outbound TCP/UDP flow on the machine to
/// handleNewFlow; flows from apps without a route are returned untouched (return false), so only
/// routed apps are ever affected.
final class TransparentProxyProvider: NETransparentProxyProvider, NEAppProxyUDPFlowHandling {
    private let engine = RouteEngine()
    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
    }

    override func startProxy(options: [String: Any]? = nil) async throws {
        Log.ext.info("startProxy, version \(self.version, privacy: .public)")
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        // nil remote + nil local = every destination, IPv4 and IPv6, except loopback (documented in
        // NENetworkRule.h). Loopback is exactly what we never want to touch.
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0, protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0, protocol: .UDP, direction: .outbound),
        ]
        try await setTunnelNetworkSettings(settings)
        loadPersistedConfig()
    }

    override func stopProxy(with reason: NEProviderStopReason) async {
        Log.ext.info("stopProxy: \(reason.rawValue)")
        engine.clear()
    }

    /// Routes and proxies (never passwords) are persisted by the app in providerConfiguration so
    /// routing resumes after a reboot before the app has launched. Passwords arrive over the
    /// message channel once the app is running.
    private func loadPersistedConfig() {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let data = proto.providerConfiguration?[ProviderConfigKeys.config] as? Data else {
            Log.ext.info("no persisted config")
            return
        }
        do {
            engine.apply(try MessageCodec.decode(ExtensionConfig.self, from: data))
        } catch {
            Log.ext.error("persisted config unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Flows

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // UDP flows arrive through handleNewUDPFlow (NEAppProxyUDPFlowHandling).
        guard let tcp = flow as? NEAppProxyTCPFlow, let route = engine.matcher.route(for: flow) else { return false }
        if let dest = FlowDestination(tcp.remoteFlowEndpoint, hostname: tcp.remoteHostname) {
            // Same-machine traffic is never a proxy's business.
            if Destination.isLoopback(dest.host) { return false }
            // LAN traffic stays on the LAN, except DNS (port 53 to the router is the classic leak).
            if Destination.isPrivateNetwork(dest.host) && dest.port != 53 { return false }
        }
        Task { await TCPRelay.run(flow: tcp, route: route, engine: engine) }
        return true
    }

    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint) -> Bool {
        guard let route = engine.matcher.route(for: flow) else { return false }
        if case .hostPort(let host, let port) = remoteEndpoint {
            if Destination.isLoopback(host) { return false }
            if Destination.isPrivateNetwork(host) && port.rawValue != 53 { return false }
        }
        Task { await UDPRelay.run(flow: flow, route: route, engine: engine) }
        return true
    }

    // MARK: App messages

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        let reply: ExtensionReply
        do {
            switch try MessageCodec.decode(AppMessage.self, from: messageData) {
            case .applyConfig(let config):
                engine.apply(config)
                reply = .ok
            case .getStatus:
                reply = .status(engine.status(extensionVersion: version))
            }
        } catch {
            reply = .error("bad message: \(error.localizedDescription)")
        }
        return try? MessageCodec.encode(reply)
    }

    override func sleep() async {
        // Nothing to tear down: relayed connections fail on their own when the link drops and the
        // apps reconnect, which creates fresh flows.
    }

    override func wake() {}
}
