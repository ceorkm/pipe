import Foundation
import Network
import NetworkExtension
import PipeCore

/// Where a flow wants to go, as the proxy should see it. Hostname when the app connected by
/// name (so the proxy resolves it and the app never depends on a local DNS answer), IP otherwise.
struct FlowDestination {
    let host: Network.NWEndpoint.Host
    let port: UInt16
    let hostname: String?

    init?(_ endpoint: Network.NWEndpoint?, hostname: String?) {
        guard case .hostPort(let host, let port)? = endpoint else { return nil }
        self.host = host
        self.port = port.rawValue
        self.hostname = hostname?.isEmpty == false ? hostname : nil
    }

    var proxyTarget: ProxyTarget {
        ProxyTarget(host: hostname ?? hostString, port: port)
    }

    var hostString: String {
        switch host {
        case .ipv4(let a): return a.debugDescription
        case .ipv6(let a): return a.debugDescription
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }
}

extension NEAppProxyTCPFlow {
    /// readData has no compiler-generated async form (NS_SWIFT_DISABLE_ASYNC). Empty data = EOF.
    func readDataAsync() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            self.readData { data, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: data ?? Data()) }
            }
        }
    }
}

enum FlowClose {
    /// Refuse a flow. The app sees the connection fail at once; nothing goes out.
    /// The flow has to be opened first: closing a never-opened TCP flow leaves the app waiting
    /// until its own timeout (measured: 20 s per request), while UDP fails immediately either way.
    static func block(_ flow: NEAppProxyFlow) {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH), userInfo: nil)
        flow.open(withLocalFlowEndpoint: nil) { _ in
            flow.closeReadWithError(err)
            flow.closeWriteWithError(err)
        }
    }
}

// MARK: - TCP

enum TCPRelay {
    static func run(flow: NEAppProxyTCPFlow, route: Route, engine: RouteEngine) async {
        guard let dest = FlowDestination(flow.remoteFlowEndpoint, hostname: flow.remoteHostname) else {
            FlowClose.block(flow); return
        }
        engine.flowStarted(route.id)
        defer { engine.flowEnded(route.id) }

        let upstream: NWConnection
        let decision = engine.decide(for: route)
        Log.flow.info("\(route.appBundleID, privacy: .public) -> \(dest.hostString, privacy: .public):\(dest.port) \(decision.label, privacy: .public)")
        switch decision {
        case .block(_, let reason):
            Log.flow.info("blocked \(route.appBundleID, privacy: .public) -> \(dest.hostString, privacy: .public):\(dest.port) (\(reason, privacy: .public))")
            FlowClose.block(flow); return
        case .direct:
            guard let conn = await connectDirect(dest, engine: engine) else { FlowClose.block(flow); return }
            upstream = conn
        case .proxy(_, let endpoint):
            do {
                upstream = try await ProxyConnector.connectTCP(through: endpoint, to: dest.proxyTarget, queue: engine.queue)
                engine.reportProxySuccess(proxyID: endpoint.id, routeID: route.id)
            } catch let error as ProxyError {
                engine.reportProxyFailure(error, proxyID: endpoint.id, routeID: route.id)
                // The failure may have just marked the proxy down; re-decide so kill-switch-off
                // routes fall back immediately instead of failing this one connection.
                if case .direct = engine.decide(for: route), let conn = await connectDirect(dest, engine: engine) {
                    Log.flow.info("\(route.appBundleID, privacy: .public) -> \(dest.hostString, privacy: .public):\(dest.port) direct after proxy failure")
                    upstream = conn
                } else {
                    Log.flow.error("proxy connect failed for \(route.appBundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    FlowClose.block(flow); return
                }
            } catch {
                FlowClose.block(flow); return
            }
        }

        do {
            try await flow.open(withLocalFlowEndpoint: nil)
        } catch {
            upstream.cancel(); return
        }
        await pump(flow: flow, upstream: upstream, routeID: route.id, engine: engine)
    }

    /// Direct connection made by the extension on the app's behalf (kill switch off, proxy down).
    private static func connectDirect(_ dest: FlowDestination, engine: RouteEngine) async -> NWConnection? {
        let endpoint: Network.NWEndpoint = dest.hostname.map { .hostPort(host: .name($0, nil), port: NWEndpoint.Port(rawValue: dest.port)!) }
            ?? .hostPort(host: dest.host, port: NWEndpoint.Port(rawValue: dest.port)!)
        let conn = NWConnection(to: endpoint, using: .tcp)
        do {
            try await conn.startAndWaitReady(queue: engine.queue, timeout: ProxyConnector.handshakeTimeout)
            return conn
        } catch {
            conn.cancel(); return nil
        }
    }

    private static func pump(flow: NEAppProxyTCPFlow, upstream: NWConnection, routeID: UUID, engine: RouteEngine) async {
        await withTaskGroup(of: Void.self) { group in
            // app -> proxy
            group.addTask {
                do {
                    while true {
                        let data = try await flow.readDataAsync()
                        if data.isEmpty { break } // app closed its write side
                        engine.addBytes(routeID, up: data.count)
                        try await upstream.sendAsync(data)
                    }
                    upstream.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                } catch {
                    upstream.cancel()
                    flow.closeReadWithError(nil)
                }
            }
            // proxy -> app
            group.addTask {
                do {
                    while let data = try await upstream.receiveSome() {
                        if data.isEmpty { continue }
                        engine.addBytes(routeID, down: data.count)
                        try await flow.write(data)
                    }
                    flow.closeWriteWithError(nil)
                } catch {
                    flow.closeWriteWithError(error)
                    flow.closeReadWithError(nil)
                    upstream.cancel()
                }
            }
            await group.waitForAll()
        }
        upstream.cancel()
    }
}

// MARK: - UDP

enum UDPRelay {
    static func run(flow: NEAppProxyUDPFlow, route: Route, engine: RouteEngine) async {
        engine.flowStarted(route.id)
        defer { engine.flowEnded(route.id) }

        let decision = engine.decide(for: route)
        Log.flow.info("\(route.appBundleID, privacy: .public) UDP flow \(decision.label, privacy: .public)")
        switch decision {
        case .block(_, let reason):
            Log.flow.info("blocked UDP \(route.appBundleID, privacy: .public) (\(reason, privacy: .public))")
            FlowClose.block(flow)
        case .direct:
            await runDirect(flow: flow, routeID: route.id, engine: engine)
        case .proxy(_, let endpoint):
            guard endpoint.profile.proto.supportsUDP else {
                // Policy: UDP the proxy cannot carry is blocked, never sent direct. Apps fall back
                // to TCP (Chromium drops QUIC for HTTP/2 when UDP is blocked).
                Log.flow.info("blocked UDP \(route.appBundleID, privacy: .public): \(endpoint.profile.proto.displayName, privacy: .public) proxy cannot carry UDP")
                FlowClose.block(flow); return
            }
            do {
                let assoc = try await ProxyConnector.associateUDP(through: endpoint, queue: engine.queue)
                engine.reportProxySuccess(proxyID: endpoint.id, routeID: route.id)
                try await flow.open(withLocalFlowEndpoint: nil)
                await pump(flow: flow, assoc: assoc, routeID: route.id, engine: engine)
            } catch let error as ProxyError {
                engine.reportProxyFailure(error, proxyID: endpoint.id, routeID: route.id)
                if case .direct = engine.decide(for: route) {
                    await runDirect(flow: flow, routeID: route.id, engine: engine)
                } else {
                    Log.flow.error("UDP associate failed for \(route.appBundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    FlowClose.block(flow)
                }
            } catch {
                FlowClose.block(flow)
            }
        }
    }

    private static func pump(flow: NEAppProxyUDPFlow, assoc: UDPAssociation, routeID: UUID, engine: RouteEngine) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    while true {
                        let (datagrams, error) = await flow.readDatagrams()
                        if let error { throw error }
                        guard let datagrams, !datagrams.isEmpty else { break }
                        for (d, e) in datagrams {
                            guard case .hostPort(let host, let port) = e else { continue }
                            let target = ProxyTarget(host: FlowDestination(e, hostname: nil)?.hostString ?? "\(host)", port: port.rawValue)
                            engine.addBytes(routeID, up: d.count)
                            try await assoc.send(d, to: target)
                        }
                    }
                } catch {}
                assoc.cancel()
                flow.closeReadWithError(nil)
            }
            group.addTask {
                do {
                    while let (payload, origin) = try await assoc.receive() {
                        guard let host = origin.nwHost, let port = NWEndpoint.Port(rawValue: origin.port) else { continue }
                        engine.addBytes(routeID, down: payload.count)
                        try await flow.writeDatagrams([(payload, .hostPort(host: host, port: port))])
                    }
                } catch {}
                flow.closeWriteWithError(nil)
                assoc.cancel()
            }
            await group.waitForAll()
        }
    }

    /// Kill switch off and proxy down: relay datagrams directly, one socket per flow.
    private static func runDirect(flow: NEAppProxyUDPFlow, routeID: UUID, engine: RouteEngine) async {
        // ponytail: one NWConnection per peer instead of a raw unconnected socket. Fine for the
        // handful of peers a fallback flow talks to; swap for a BSD socket if a flow fans out widely.
        var peers: [Network.NWEndpoint: NWConnection] = [:]
        do {
            try await flow.open(withLocalFlowEndpoint: nil)
            while true {
                let (datagrams, error) = await flow.readDatagrams()
                if let error { throw error }
                guard let datagrams, !datagrams.isEmpty else { break }
                for (d, e) in datagrams {
                    let conn: NWConnection
                    if let existing = peers[e] {
                        conn = existing
                    } else {
                        conn = NWConnection(to: e, using: .udp)
                        peers[e] = conn
                        try await conn.startAndWaitReady(queue: engine.queue, timeout: ProxyConnector.handshakeTimeout)
                        Task {
                            while let reply = try? await conn.receiveDatagram() {
                                if reply.isEmpty { continue }
                                engine.addBytes(routeID, down: reply.count)
                                try? await flow.writeDatagrams([(reply, e)])
                            }
                        }
                    }
                    engine.addBytes(routeID, up: d.count)
                    try await conn.sendAsync(d)
                }
            }
        } catch {}
        peers.values.forEach { $0.cancel() }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
}
