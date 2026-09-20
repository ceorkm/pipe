import Foundation
import Network
@testable import PipeCore

/// Minimal in-process SOCKS5 server: enough to exercise the client's handshake, auth and CONNECT,
/// then echo bytes back so the relay path can be checked end to end.
final class TestSOCKS5Server: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "test.socks5")
    var port: UInt16 { listener.port!.rawValue }
    let username: String?, password: String?
    /// What the server does with CONNECT: echo or refuse with a SOCKS reply code.
    var connectReply: UInt8 = 0x00
    private(set) var lastTargetHost: String?

    init(username: String? = nil, password: String? = nil) throws {
        self.username = username; self.password = password
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        ready.wait()
    }

    func stop() { listener.cancel() }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        Task {
            do {
                let greet = try await c.receiveExactly(2)
                let methods = try await c.receiveExactly(Int(greet[1]))
                if username != nil {
                    guard methods.contains(0x02) else { try await c.sendAsync(Data([5, 0xFF])); c.cancel(); return }
                    try await c.sendAsync(Data([5, 2]))
                    let h = try await c.receiveExactly(2)
                    let u = try await c.receiveExactly(Int(h[1]))
                    let pl = try await c.receiveExactly(1)
                    let p = try await c.receiveExactly(Int(pl[0]))
                    let ok = String(decoding: u, as: UTF8.self) == username && String(decoding: p, as: UTF8.self) == password
                    try await c.sendAsync(Data([1, ok ? 0 : 1]))
                    if !ok { c.cancel(); return }
                } else {
                    try await c.sendAsync(Data([5, 0]))
                }
                let head = try await c.receiveExactly(4)
                let target = try await SOCKS5.readAddress(type: head[3], on: c)
                lastTargetHost = target.host
                try await c.sendAsync(Data([5, connectReply, 0, 1, 127, 0, 0, 1, 0, 0]))
                if connectReply != 0 { c.cancel(); return }
                while let d = try await c.receiveSome() { try await c.sendAsync(d) }
                c.cancel()
            } catch { c.cancel() }
        }
    }
}

/// Minimal HTTP CONNECT server that echoes after a 200.
final class TestHTTPProxyServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "test.http")
    var port: UInt16 { listener.port!.rawValue }
    var status = "200 Connection established"
    let expectedAuth: String?

    init(username: String? = nil, password: String? = nil) throws {
        expectedAuth = username.map { Data("\($0):\(password ?? "")".utf8).base64EncodedString() }
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        ready.wait()
    }
    func stop() { listener.cancel() }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        Task {
            do {
                var buf = Data()
                while buf.range(of: Data("\r\n\r\n".utf8)) == nil, let d = try await c.receiveSome() { buf.append(d) }
                let req = String(decoding: buf, as: UTF8.self)
                var reply = status
                if let expectedAuth, !req.contains("Proxy-Authorization: Basic \(expectedAuth)") { reply = "407 Proxy Authentication Required" }
                try await c.sendAsync(Data("HTTP/1.1 \(reply)\r\n\r\n".utf8))
                if !reply.hasPrefix("200") { c.cancel(); return }
                while let d = try await c.receiveSome() { try await c.sendAsync(d) }
                c.cancel()
            } catch { c.cancel() }
        }
    }
}
