import Foundation

/// App -> extension, over NETunnelProviderSession.sendProviderMessage.
/// The system only delivers these from the app that owns the proxy configuration,
/// so no extra authentication is layered on top. Payloads are still validated on decode.
public enum AppMessage: Codable, Sendable {
    case applyConfig(ExtensionConfig)
    case getStatus
}

public enum RouteState: String, Codable, Sendable {
    /// Route is on, no traffic seen yet.
    case idle
    /// Route is on and the proxy accepted at least one connection recently.
    case connected
    /// Proxy cannot be reached. Kill switch on: traffic is blocked.
    case blocked
    /// Proxy cannot be reached. Kill switch off: traffic goes direct.
    case fallbackDirect
    /// The proxy needs a password the extension does not have (app not running yet after login).
    case missingCredential
}

public struct RouteStatus: Codable, Sendable, Identifiable, Equatable {
    public var routeID: UUID
    public var state: RouteState
    public var activeConnections: Int
    public var bytesUp: UInt64
    public var bytesDown: UInt64
    public var lastError: String?

    public var id: UUID { routeID }

    public init(routeID: UUID, state: RouteState, activeConnections: Int = 0, bytesUp: UInt64 = 0, bytesDown: UInt64 = 0, lastError: String? = nil) {
        self.routeID = routeID
        self.state = state
        self.activeConnections = activeConnections
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.lastError = lastError
    }
}

public struct ExtensionStatus: Codable, Sendable {
    public var routes: [RouteStatus]
    /// Whether the extension currently holds a config (false right after boot until the app syncs).
    public var hasConfig: Bool
    public var extensionVersion: String

    public init(routes: [RouteStatus], hasConfig: Bool, extensionVersion: String) {
        self.routes = routes
        self.hasConfig = hasConfig
        self.extensionVersion = extensionVersion
    }
}

public enum ExtensionReply: Codable, Sendable {
    case ok
    case status(ExtensionStatus)
    case error(String)
}

public enum MessageCodec {
    /// Hard cap on message size. Anything bigger is rejected before decoding.
    public static let maxBytes = 1 << 20

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maxBytes else { throw ProxyError.protocolError("message too large") }
        return try JSONDecoder().decode(type, from: data)
    }
}

/// Keys inside NETunnelProviderProtocol.providerConfiguration.
public enum ProviderConfigKeys {
    /// JSON-encoded ExtensionConfig with passwords stripped.
    public static let config = "config"
}
