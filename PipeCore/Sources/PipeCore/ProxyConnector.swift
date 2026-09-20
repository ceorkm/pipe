import Foundation
import Network

/// Where a proxied connection should end up. `host` may be a hostname or a literal IP.
/// A hostname is passed to the proxy unresolved so the proxy resolves it on its side.
public struct ProxyTarget: Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Opens connections through a proxy. Pure protocol logic, no routing policy.
public enum ProxyConnector {
    public static let handshakeTimeout: TimeInterval = 15

    /// Returns an NWConnection that is ready to relay application bytes to `target`.
    public static func connectTCP(through endpoint: ProxyEndpoint, to target: ProxyTarget, queue: DispatchQueue) async throws -> NWConnection {
        let conn = makeProxyConnection(endpoint.profile)
        do {
            try await conn.startAndWaitReady(queue: queue, timeout: handshakeTimeout)
            switch endpoint.profile.proto {
            case .socks5:
                try await SOCKS5.handshake(on: conn, endpoint: endpoint)
                try await SOCKS5.connect(on: conn, target: target)
            case .http, .https:
                try await HTTPConnect.connect(on: conn, endpoint: endpoint, target: target)
            }
            return conn
        } catch let error as ProxyError {
            conn.cancel()
            throw error
        } catch let error as NWError {
            conn.cancel()
            throw ProxyError.fromTransport(error, proxyHost: endpoint.profile.host)
        } catch {
            conn.cancel()
            throw ProxyError.protocolError(String(describing: error))
        }
    }

    /// Establish a SOCKS5 UDP association. The returned object owns the control TCP connection
    /// (the association dies when it closes) and a UDP socket to the proxy's relay endpoint.
    public static func associateUDP(through endpoint: ProxyEndpoint, queue: DispatchQueue) async throws -> UDPAssociation {
        guard endpoint.profile.proto.supportsUDP else { throw ProxyError.udpUnsupported }
        let control = makeProxyConnection(endpoint.profile)
        do {
            try await control.startAndWaitReady(queue: queue, timeout: handshakeTimeout)
            try await SOCKS5.handshake(on: control, endpoint: endpoint)
            let relay = try await SOCKS5.udpAssociate(on: control)
            // Some proxies answer with 0.0.0.0 meaning "same host as the control connection".
            let relayHost: NWEndpoint.Host = relay.host.isUnspecified ? NWEndpoint.Host(endpoint.profile.host) : relay.host
            let udp = NWConnection(host: relayHost, port: NWEndpoint.Port(rawValue: relay.port)!, using: .udp)
            try await udp.startAndWaitReady(queue: queue, timeout: handshakeTimeout)
            return UDPAssociation(control: control, udp: udp)
        } catch let error as ProxyError {
            control.cancel()
            throw error
        } catch let error as NWError {
            control.cancel()
            throw ProxyError.fromTransport(error, proxyHost: endpoint.profile.host)
        }
    }

    /// Connection to the proxy server itself. For `.https` the proxy hop is wrapped in TLS.
    static func makeProxyConnection(_ profile: ProxyProfile) -> NWConnection {
        let host = NWEndpoint.Host(profile.host)
        let port = NWEndpoint.Port(rawValue: profile.port) ?? 1080
        let params: NWParameters
        if profile.proto == .https {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, profile.host)
            params = NWParameters(tls: tls)
        } else {
            params = .tcp
        }
        params.preferNoProxies = true
        return NWConnection(host: host, port: port, using: params)
    }
}

public extension NWEndpoint.Host {
    var isUnspecified: Bool {
        switch self {
        case .ipv4(let a): return a == .any
        case .ipv6(let a): return a == .any
        default: return false
        }
    }
}

/// A live SOCKS5 UDP association.
public final class UDPAssociation: @unchecked Sendable {
    public let control: NWConnection
    public let udp: NWConnection

    init(control: NWConnection, udp: NWConnection) {
        self.control = control
        self.udp = udp
    }

    /// Send one datagram to `target` through the relay.
    public func send(_ payload: Data, to target: ProxyTarget) async throws {
        try await udp.sendAsync(SOCKS5.encodeUDPHeader(target: target) + payload)
    }

    /// Receive one datagram from the relay. Returns the payload and its origin, or nil on EOF.
    public func receive() async throws -> (Data, ProxyTarget)? {
        while true {
            guard let raw = try await udp.receiveDatagram() else { return nil }
            if raw.isEmpty { continue }
            if let parsed = SOCKS5.decodeUDPHeader(raw) { return parsed }
            // Malformed relay datagram: drop it, keep the association alive.
        }
    }

    public func cancel() {
        udp.cancel()
        control.cancel()
    }
}
