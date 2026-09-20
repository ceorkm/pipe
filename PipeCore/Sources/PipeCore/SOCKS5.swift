import Foundation
import Network

/// RFC 1928 (SOCKS5) and RFC 1929 (username/password auth). Wire format only.
public enum SOCKS5 {
    enum AddressType: UInt8 { case ipv4 = 1, domain = 3, ipv6 = 4 }

    // MARK: Greeting + auth

    static func handshake(on conn: NWConnection, endpoint: ProxyEndpoint) async throws {
        let hasCreds = endpoint.profile.username != nil
        // Offer "no auth" always, and user/pass if we have one.
        var greeting: [UInt8] = [0x05, hasCreds ? 0x02 : 0x01, 0x00]
        if hasCreds { greeting.append(0x02) }
        try await conn.sendAsync(Data(greeting))
        let reply = try await conn.receiveExactly(2)
        guard reply[0] == 0x05 else { throw ProxyError.protocolError("not a SOCKS5 server (version \(reply[0]))") }
        switch reply[1] {
        case 0x00:
            return
        case 0x02:
            guard let user = endpoint.profile.username else { throw ProxyError.authenticationRequired }
            try await authenticate(on: conn, username: user, password: endpoint.password ?? "")
        case 0xFF:
            throw hasCreds ? ProxyError.authenticationFailed("server rejected all offered methods") : ProxyError.authenticationRequired
        default:
            throw ProxyError.protocolError("unsupported auth method \(reply[1])")
        }
    }

    static func authenticate(on conn: NWConnection, username: String, password: String) async throws {
        let u = Array(username.utf8), p = Array(password.utf8)
        guard u.count <= 255, p.count <= 255 else { throw ProxyError.authenticationFailed("credentials too long") }
        var msg: [UInt8] = [0x01, UInt8(u.count)]
        msg += u
        msg.append(UInt8(p.count))
        msg += p
        try await conn.sendAsync(Data(msg))
        let reply = try await conn.receiveExactly(2)
        guard reply[0] == 0x01 else { throw ProxyError.protocolError("bad auth reply version") }
        guard reply[1] == 0x00 else { throw ProxyError.invalidCredentials }
    }

    // MARK: CONNECT / UDP ASSOCIATE

    static func connect(on conn: NWConnection, target: ProxyTarget) async throws {
        try await conn.sendAsync(Data([0x05, 0x01, 0x00]) + encodeAddress(target))
        _ = try await readReply(on: conn)
    }

    /// Returns the relay endpoint the client must send UDP datagrams to.
    static func udpAssociate(on conn: NWConnection) async throws -> (host: NWEndpoint.Host, port: UInt16) {
        // Client address 0.0.0.0:0 = "I don't know my source address yet"; every server accepts it.
        try await conn.sendAsync(Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
        let bound = try await readReply(on: conn)
        guard let host = bound.nwHost else { throw ProxyError.protocolError("relay address is a domain name") }
        return (host, bound.port)
    }

    static func readReply(on conn: NWConnection) async throws -> ProxyTarget {
        let head = try await conn.receiveExactly(4)
        guard head[0] == 0x05 else { throw ProxyError.protocolError("bad reply version") }
        if head[1] != 0x00 { throw replyError(head[1]) }
        return try await readAddress(type: head[3], on: conn)
    }

    static func replyError(_ code: UInt8) -> ProxyError {
        switch code {
        case 0x01: return .refusedByProxy("general SOCKS server failure")
        case 0x02: return .refusedByProxy("connection not allowed by ruleset")
        case 0x03: return .destinationUnreachable
        case 0x04: return .destinationUnreachable
        case 0x05: return .refusedByProxy("destination refused the connection")
        case 0x06: return .refusedByProxy("TTL expired")
        case 0x07: return .refusedByProxy("command not supported")
        case 0x08: return .refusedByProxy("address type not supported")
        default: return .refusedByProxy("reply code \(code)")
        }
    }

    // MARK: Addresses

    /// ATYP + address + port, as used in requests and UDP headers.
    static func encodeAddress(_ target: ProxyTarget) -> Data {
        var out = Data()
        if let v4 = IPv4Address(target.host) {
            out.append(AddressType.ipv4.rawValue)
            out.append(v4.rawValue)
        } else if let v6 = IPv6Address(target.host) {
            out.append(AddressType.ipv6.rawValue)
            out.append(v6.rawValue)
        } else {
            let name = Array(target.host.utf8.prefix(255))
            out.append(AddressType.domain.rawValue)
            out.append(UInt8(name.count))
            out.append(contentsOf: name)
        }
        out.append(UInt8(target.port >> 8))
        out.append(UInt8(target.port & 0xFF))
        return out
    }

    static func readAddress(type: UInt8, on conn: NWConnection) async throws -> ProxyTarget {
        switch AddressType(rawValue: type) {
        case .ipv4:
            let raw = try await conn.receiveExactly(6)
            return ProxyTarget(host: IPv4Address(raw.prefix(4))!.debugDescription, port: UInt16(raw[4]) << 8 | UInt16(raw[5]))
        case .ipv6:
            let raw = try await conn.receiveExactly(18)
            return ProxyTarget(host: IPv6Address(raw.prefix(16))!.debugDescription, port: UInt16(raw[16]) << 8 | UInt16(raw[17]))
        case .domain:
            let len = Int(try await conn.receiveExactly(1)[0])
            let raw = try await conn.receiveExactly(len + 2)
            let name = String(decoding: raw.prefix(len), as: UTF8.self)
            return ProxyTarget(host: name, port: UInt16(raw[len]) << 8 | UInt16(raw[len + 1]))
        case .none:
            throw ProxyError.protocolError("unknown address type \(type)")
        }
    }

    // MARK: UDP datagram framing (RFC 1928 §7)

    static func encodeUDPHeader(target: ProxyTarget) -> Data {
        Data([0x00, 0x00, 0x00]) + encodeAddress(target)
    }

    /// Parse "RSV FRAG ATYP ADDR PORT DATA". Returns nil for malformed or fragmented datagrams.
    static func decodeUDPHeader(_ d: Data) -> (Data, ProxyTarget)? {
        let b = [UInt8](d)
        guard b.count >= 4, b[2] == 0 else { return nil }
        var i = 3
        let host: String
        switch AddressType(rawValue: b[i]) {
        case .ipv4:
            guard b.count >= i + 1 + 4 + 2 else { return nil }
            host = IPv4Address(Data(b[(i + 1)..<(i + 5)]))!.debugDescription
            i += 5
        case .ipv6:
            guard b.count >= i + 1 + 16 + 2 else { return nil }
            host = IPv6Address(Data(b[(i + 1)..<(i + 17)]))!.debugDescription
            i += 17
        case .domain:
            guard b.count > i + 1 else { return nil }
            let len = Int(b[i + 1])
            guard b.count >= i + 2 + len + 2 else { return nil }
            host = String(decoding: b[(i + 2)..<(i + 2 + len)], as: UTF8.self)
            i += 2 + len
        case .none:
            return nil
        }
        let port = UInt16(b[i]) << 8 | UInt16(b[i + 1])
        return (Data(b[(i + 2)...]), ProxyTarget(host: host, port: port))
    }
}

extension ProxyTarget {
    public var nwHost: NWEndpoint.Host? {
        if let v4 = IPv4Address(host) { return .ipv4(v4) }
        if let v6 = IPv6Address(host) { return .ipv6(v6) }
        return nil
    }
}
