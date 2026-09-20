import XCTest
import Network
@testable import PipeCore

final class ProxyConnectorTests: XCTestCase {
    let queue = DispatchQueue(label: "test.client")

    func endpoint(_ proto: ProxyProtocol, port: UInt16, user: String? = nil, pass: String? = nil) -> ProxyEndpoint {
        ProxyEndpoint(profile: ProxyProfile(name: "t", host: "127.0.0.1", port: port, proto: proto, username: user), password: pass)
    }

    func testSOCKS5NoAuthConnectAndEcho() async throws {
        let server = try TestSOCKS5Server(); defer { server.stop() }
        let conn = try await ProxyConnector.connectTCP(through: endpoint(.socks5, port: server.port), to: ProxyTarget(host: "example.com", port: 443), queue: queue)
        defer { conn.cancel() }
        XCTAssertEqual(server.lastTargetHost, "example.com", "hostname must reach the proxy unresolved")
        try await conn.sendAsync(Data("hello".utf8))
        let echoed = try await conn.receiveExactly(5)
        XCTAssertEqual(String(decoding: echoed, as: UTF8.self), "hello")
    }

    func testSOCKS5PasswordAuth() async throws {
        let server = try TestSOCKS5Server(username: "u", password: "p"); defer { server.stop() }
        let conn = try await ProxyConnector.connectTCP(through: endpoint(.socks5, port: server.port, user: "u", pass: "p"), to: ProxyTarget(host: "1.2.3.4", port: 80), queue: queue)
        conn.cancel()
        XCTAssertEqual(server.lastTargetHost, "1.2.3.4")
    }

    func testSOCKS5WrongPassword() async throws {
        let server = try TestSOCKS5Server(username: "u", password: "p"); defer { server.stop() }
        await XCTAssertThrowsErrorAsync(try await ProxyConnector.connectTCP(through: self.endpoint(.socks5, port: server.port, user: "u", pass: "wrong"), to: ProxyTarget(host: "1.2.3.4", port: 80), queue: self.queue)) { error in
            XCTAssertEqual(error as? ProxyError, .invalidCredentials)
        }
    }

    func testSOCKS5AuthRequiredButNoneGiven() async throws {
        let server = try TestSOCKS5Server(username: "u", password: "p"); defer { server.stop() }
        await XCTAssertThrowsErrorAsync(try await ProxyConnector.connectTCP(through: self.endpoint(.socks5, port: server.port), to: ProxyTarget(host: "1.2.3.4", port: 80), queue: self.queue)) { error in
            XCTAssertEqual(error as? ProxyError, .authenticationRequired)
        }
    }

    func testSOCKS5RefusedByRuleset() async throws {
        let server = try TestSOCKS5Server(); server.connectReply = 0x02; defer { server.stop() }
        await XCTAssertThrowsErrorAsync(try await ProxyConnector.connectTCP(through: self.endpoint(.socks5, port: server.port), to: ProxyTarget(host: "1.2.3.4", port: 80), queue: self.queue)) { error in
            XCTAssertEqual(error as? ProxyError, .refusedByProxy("connection not allowed by ruleset"))
        }
    }

    func testProxyUnreachable() async throws {
        // Port 1 on localhost: nothing listens there.
        await XCTAssertThrowsErrorAsync(try await ProxyConnector.connectTCP(through: self.endpoint(.socks5, port: 1), to: ProxyTarget(host: "1.2.3.4", port: 80), queue: self.queue)) { error in
            XCTAssertEqual(error as? ProxyError, .unreachable("connection refused"))
        }
    }

    func testHTTPConnectEcho() async throws {
        let server = try TestHTTPProxyServer(); defer { server.stop() }
        let conn = try await ProxyConnector.connectTCP(through: endpoint(.http, port: server.port), to: ProxyTarget(host: "example.com", port: 443), queue: queue)
        defer { conn.cancel() }
        try await conn.sendAsync(Data("ping".utf8))
        let back = try await conn.receiveExactly(4)
        XCTAssertEqual(String(decoding: back, as: UTF8.self), "ping")
    }

    func testHTTPConnect407() async throws {
        let server = try TestHTTPProxyServer(username: "a", password: "b"); defer { server.stop() }
        await XCTAssertThrowsErrorAsync(try await ProxyConnector.connectTCP(through: self.endpoint(.http, port: server.port, user: "a", pass: "nope"), to: ProxyTarget(host: "x", port: 1), queue: self.queue)) { error in
            XCTAssertEqual(error as? ProxyError, .invalidCredentials)
        }
        await XCTAssertThrowsErrorAsync(try await ProxyConnector.connectTCP(through: self.endpoint(.http, port: server.port), to: ProxyTarget(host: "x", port: 1), queue: self.queue)) { error in
            XCTAssertEqual(error as? ProxyError, .authenticationRequired)
        }
    }

    func testUDPHeaderRoundTrip() {
        for host in ["8.8.8.8", "2001:db8::1", "dns.example"] {
            let hdr = SOCKS5.encodeUDPHeader(target: ProxyTarget(host: host, port: 53))
            let parsed = SOCKS5.decodeUDPHeader(hdr + Data([1, 2, 3]))
            XCTAssertEqual(parsed?.1.host, host)
            XCTAssertEqual(parsed?.1.port, 53)
            XCTAssertEqual(parsed?.0, Data([1, 2, 3]))
        }
        XCTAssertNil(SOCKS5.decodeUDPHeader(Data([0, 0, 1, 1, 0, 0, 0, 0, 0, 0])), "fragmented datagrams are rejected")
    }

    func testMessagesRoundTrip() throws {
        let cfg = ExtensionConfig(proxies: [ProxyEndpoint(profile: ProxyProfile(name: "n", host: "h", port: 1, proto: .socks5, username: "u"), password: "p")],
                                  routes: [Route(appBundleID: "a.b", appName: "A", appPath: "/Applications/A.app", proxyID: UUID())])
        let data = try MessageCodec.encode(AppMessage.applyConfig(cfg))
        guard case .applyConfig(let back) = try MessageCodec.decode(AppMessage.self, from: data) else { return XCTFail() }
        XCTAssertEqual(back.proxies, cfg.proxies)
        XCTAssertEqual(back.routes, cfg.routes)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ check: (Error) -> Void) async {
    do { _ = try await expression(); XCTFail("expected an error") } catch { check(error) }
}

final class TimeoutTests: XCTestCase {
    func testHandshakeTimeoutActuallyFires() async {
        // 10.255.255.1 is a blackhole on any normal network: SYNs go unanswered.
        let ep = ProxyEndpoint(profile: ProxyProfile(name: "t", host: "10.255.255.1", port: 1080, proto: .socks5), password: nil)
        let conn = ProxyConnector.makeProxyConnection(ep.profile)
        let start = Date()
        await XCTAssertThrowsErrorAsync(try await conn.startAndWaitReady(queue: DispatchQueue(label: "t"), timeout: 2)) { error in
            XCTAssertEqual(ProxyError.fromTransport(error as! NWError, proxyHost: "x"), .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "timeout must return promptly, not hang")
    }
}
