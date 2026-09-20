import Foundation
import NetworkExtension
import PipeCore

/// Owns the NETransparentProxyManager: saves the routing configuration into the system,
/// starts and stops the proxy session, and talks to the running extension.
@MainActor
final class TunnelController: ObservableObject {
    @Published private(set) var sessionStatus: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?
    private var manager: NETransparentProxyManager?
    private var observer: NSObjectProtocol?

    /// Load or create our configuration. Safe to call repeatedly.
    func load() async {
        do {
            let all = try await NETransparentProxyManager.loadAllFromPreferences()
            let mine = all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == PipeIdentifiers.extensionBundleID }
            let m = mine ?? NETransparentProxyManager()
            manager = m
            observe(m)
            sessionStatus = m.connection.status
        } catch {
            lastError = "Could not read the proxy configuration: \(error.localizedDescription)"
        }
    }

    private func observe(_ m: NETransparentProxyManager) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: m.connection, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sessionStatus = m.connection.status }
        }
    }

    /// Persist routes and proxies (without passwords) and start or stop the session accordingly.
    /// The first save on a machine triggers macOS's "add proxy configurations" consent dialog.
    func save(_ config: PipeConfig) async throws {
        if manager == nil { await load() }
        guard let m = manager else { return }
        let stripped = ExtensionConfig(proxies: config.proxies.map { ProxyEndpoint(profile: $0, password: nil) }, routes: config.routes)
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = PipeIdentifiers.extensionBundleID
        proto.serverAddress = "Pipe"
        proto.providerConfiguration = [ProviderConfigKeys.config: try MessageCodec.encode(stripped)]
        m.protocolConfiguration = proto
        m.localizedDescription = "Pipe"
        let shouldRun = config.routes.contains(where: \.isEnabled)
        m.isEnabled = shouldRun
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        sessionStatus = m.connection.status
        if shouldRun {
            if m.connection.status == .disconnected || m.connection.status == .invalid {
                try m.connection.startVPNTunnel()
            }
        } else if m.connection.status != .disconnected {
            m.connection.stopVPNTunnel()
        }
        lastError = nil
    }

    var isRunning: Bool { sessionStatus == .connected }

    /// Send a message to the running extension and decode its reply. Returns nil when not running.
    func send(_ message: AppMessage) async throws -> ExtensionReply? {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else { return nil }
        let data = try MessageCodec.encode(message)
        return try await withCheckedThrowingContinuation { cont in
            do {
                try session.sendProviderMessage(data) { reply in
                    guard let reply else { cont.resume(returning: nil); return }
                    cont.resume(with: Result { try MessageCodec.decode(ExtensionReply.self, from: reply) })
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Remove the configuration entirely (Settings > Uninstall).
    func removeConfiguration() async throws {
        try await manager?.removeFromPreferences()
        manager = nil
        sessionStatus = .invalid
    }
}
