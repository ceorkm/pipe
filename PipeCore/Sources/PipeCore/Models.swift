import Foundation

/// Shared identifiers. One place, so the app, extension and scripts never drift.
public enum PipeIdentifiers {
    public static let teamID = "DN478SNPML"
    public static let appBundleID = "com.rkmlabs.pipe"
    public static let extensionBundleID = "com.rkmlabs.pipe.extension"
    public static let appGroup = "\(teamID).com.rkmlabs.pipe"
    public static let keychainService = "com.rkmlabs.pipe.proxy-credentials"
}

public enum ProxyProtocol: String, Codable, CaseIterable, Sendable {
    case socks5
    case http
    /// HTTP CONNECT to a proxy that itself speaks TLS.
    case https

    public var displayName: String {
        switch self {
        case .socks5: return "SOCKS5"
        case .http: return "HTTP"
        case .https: return "HTTPS"
        }
    }

    /// Only SOCKS5 can carry UDP (RFC 1928 UDP ASSOCIATE). HTTP CONNECT is TCP only.
    public var supportsUDP: Bool { self == .socks5 }
}

/// A proxy as the user sees it. The password is never in this struct; it lives in the Keychain.
public struct ProxyProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var proto: ProxyProtocol
    public var username: String?

    public init(id: UUID = UUID(), name: String, host: String, port: UInt16, proto: ProxyProtocol, username: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.proto = proto
        self.username = username?.isEmpty == true ? nil : username
    }
}

/// A route: this app's traffic goes through that proxy.
public struct Route: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var appBundleID: String
    public var appName: String
    /// Path of the .app bundle when the route was created. Used to match helper processes
    /// living inside the bundle whose signing identifier differs from the app's.
    public var appPath: String
    public var proxyID: UUID
    public var isEnabled: Bool
    /// True: when the proxy is unreachable the app gets no network at all.
    /// False: when the proxy is unreachable the app falls back to the direct connection.
    public var killSwitch: Bool

    public init(id: UUID = UUID(), appBundleID: String, appName: String, appPath: String, proxyID: UUID, isEnabled: Bool = true, killSwitch: Bool = true) {
        self.id = id
        self.appBundleID = appBundleID
        self.appName = appName
        self.appPath = appPath
        self.proxyID = proxyID
        self.isEnabled = isEnabled
        self.killSwitch = killSwitch
    }
}

/// What the app persists on disk (no secrets).
public struct PipeConfig: Codable, Sendable, Equatable {
    public var proxies: [ProxyProfile]
    public var routes: [Route]

    public init(proxies: [ProxyProfile] = [], routes: [Route] = []) {
        self.proxies = proxies
        self.routes = routes
    }

    public func proxy(for route: Route) -> ProxyProfile? {
        proxies.first { $0.id == route.proxyID }
    }
}

/// A proxy with its credential, ready to connect. Exists only in memory: sent from the app to the
/// extension over the provider message channel, never written to disk by either side.
public struct ProxyEndpoint: Codable, Hashable, Sendable {
    public var profile: ProxyProfile
    public var password: String?

    public init(profile: ProxyProfile, password: String?) {
        self.profile = profile
        self.password = password?.isEmpty == true ? nil : password
    }

    public var id: UUID { profile.id }
}

/// Everything the extension needs to route.
public struct ExtensionConfig: Codable, Sendable {
    public var proxies: [ProxyEndpoint]
    public var routes: [Route]

    public init(proxies: [ProxyEndpoint], routes: [Route]) {
        self.proxies = proxies
        self.routes = routes
    }
}
