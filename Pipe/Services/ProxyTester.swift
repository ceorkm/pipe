import Foundation
import Network
import PipeCore

struct ProxyTestResult: Equatable, Codable {
    var latencyMs: Int
    var publicIP: String?
    var country: String?
    var countryCode: String?
}

/// "Test Connection". Step 1 uses Pipe's own SOCKS5/HTTP client so failures are precise
/// (bad password vs unreachable vs timeout). Step 2 fetches the exit IP through the proxy.
enum ProxyTester {
    static func test(_ endpoint: ProxyEndpoint) async throws -> ProxyTestResult {
        let queue = DispatchQueue(label: "pipe.proxytest")
        let start = Date()
        let conn = try await ProxyConnector.connectTCP(through: endpoint, to: ProxyTarget(host: "ipwho.is", port: 443), queue: queue)
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        conn.cancel()

        var result = ProxyTestResult(latencyMs: latency)
        do {
            let info = try await fetchExitInfo(through: endpoint)
            result.publicIP = info.ip
            result.country = info.country
            result.countryCode = info.country_code
        } catch {
            // Handshake worked, so the proxy is up; the lookup service may be down or blocked.
            Log.proxy.info("exit IP lookup failed: \(error.localizedDescription, privacy: .public)")
        }
        return result
    }

    private struct ExitInfo: Decodable {
        var ip: String
        var country: String?
        var country_code: String?
    }

    private static func fetchExitInfo(through endpoint: ProxyEndpoint) async throws -> ExitInfo {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        let host = NWEndpoint.Host(endpoint.profile.host)
        let port = NWEndpoint.Port(rawValue: endpoint.profile.port)!
        var proxy: ProxyConfiguration
        switch endpoint.profile.proto {
        case .socks5: proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: host, port: port))
        case .http: proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: host, port: port))
        case .https:
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, endpoint.profile.host)
            proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: host, port: port), tlsOptions: tls)
        }
        if let user = endpoint.profile.username { proxy.applyCredential(username: user, password: endpoint.password ?? "") }
        cfg.proxyConfigurations = [proxy]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: URL(string: "https://ipwho.is/?fields=ip,country,country_code")!)
        return try JSONDecoder().decode(ExitInfo.self, from: data)
    }
}
