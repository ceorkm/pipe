import Foundation
import Network

/// Every way a proxy connection can fail, in words a user can act on.
public enum ProxyError: Error, LocalizedError, Equatable, Sendable {
    case unreachable(String)
    case timedOut
    case dnsFailed(String)
    case authenticationRequired
    case invalidCredentials
    case authenticationFailed(String)
    case refusedByProxy(String)
    case destinationUnreachable
    case tlsFailed(String)
    case udpUnsupported
    case protocolError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail): return "Proxy unreachable (\(detail))"
        case .timedOut: return "Connection timed out"
        case .dnsFailed(let host): return "DNS resolution failed for \(host)"
        case .authenticationRequired: return "Proxy requires a username and password"
        case .invalidCredentials: return "Invalid credentials"
        case .authenticationFailed(let detail): return "Authentication failed (\(detail))"
        case .refusedByProxy(let reason): return "Proxy refused the connection: \(reason)"
        case .destinationUnreachable: return "Proxy could not reach the destination"
        case .tlsFailed(let detail): return "TLS connection failed (\(detail))"
        case .udpUnsupported: return "This proxy cannot carry UDP traffic"
        case .protocolError(let detail): return "Proxy protocol error: \(detail)"
        case .cancelled: return "Cancelled"
        }
    }

    /// Map a Network.framework error from the connection *to the proxy* into something meaningful.
    public static func fromTransport(_ error: NWError, proxyHost: String) -> ProxyError {
        switch error {
        case .posix(let code):
            switch code {
            case .ETIMEDOUT: return .timedOut
            case .ECONNREFUSED: return .unreachable("connection refused")
            case .EHOSTUNREACH, .ENETUNREACH: return .unreachable("no route to host")
            case .ECANCELED: return .cancelled
            default: return .unreachable(String(cString: strerror(code.rawValue)))
            }
        case .dns: return .dnsFailed(proxyHost)
        case .tls(let status): return .tlsFailed("OSStatus \(status)")
        default: return .unreachable(String(describing: error))
        }
    }
}
