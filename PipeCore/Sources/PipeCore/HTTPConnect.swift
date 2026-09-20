import Foundation
import Network

/// HTTP CONNECT tunnelling (RFC 9110 §9.3.6) with optional Basic proxy authentication.
public enum HTTPConnect {
    static func connect(on conn: NWConnection, endpoint: ProxyEndpoint, target: ProxyTarget) async throws {
        let authority = formatAuthority(target)
        var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\nProxy-Connection: keep-alive\r\n"
        if let user = endpoint.profile.username {
            let token = Data("\(user):\(endpoint.password ?? "")".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(token)\r\n"
        }
        request += "\r\n"
        try await conn.sendAsync(Data(request.utf8))

        // Read until the end of the response headers. Anything after is tunnel data and must be kept.
        var buffer = Data()
        while true {
            guard let chunk = try await conn.receiveSome() else {
                throw ProxyError.protocolError("proxy closed the connection before replying")
            }
            buffer.append(chunk)
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                try checkStatus(head, hadCredentials: endpoint.profile.username != nil)
                // ponytail: bytes after the header block are discarded. A compliant proxy sends
                // nothing before the client speaks (the client always talks first in TLS/HTTP),
                // so this is safe in practice; revisit if a proxy is seen to pre-send data.
                return
            }
            if buffer.count > 64 * 1024 { throw ProxyError.protocolError("response headers too large") }
        }
    }

    static func checkStatus(_ head: String, hadCredentials: Bool) throws {
        guard let statusLine = head.split(separator: "\r\n", maxSplits: 1).first else {
            throw ProxyError.protocolError("empty response")
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            throw ProxyError.protocolError("not an HTTP proxy")
        }
        let reason = parts.count > 2 ? String(parts[2]) : ""
        switch code {
        case 200...299: return
        case 407: throw hadCredentials ? ProxyError.invalidCredentials : ProxyError.authenticationRequired
        case 403: throw ProxyError.refusedByProxy("forbidden (\(code) \(reason))")
        case 502, 503, 504: throw ProxyError.destinationUnreachable
        default: throw ProxyError.refusedByProxy("\(code) \(reason)")
        }
    }

    static func formatAuthority(_ t: ProxyTarget) -> String {
        if IPv6Address(t.host) != nil { return "[\(t.host)]:\(t.port)" }
        return "\(t.host):\(t.port)"
    }
}
