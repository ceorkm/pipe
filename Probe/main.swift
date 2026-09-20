// PipeProbe: runs inside a routed .app identity and reports, per protocol, whether a connection
// succeeded and which public IP the other end saw. Output is JSON lines for Scripts/leaktest.sh.
import Foundation
import Network

struct Result: Encodable { let check: String; let ok: Bool; let ip: String?; let detail: String }
let encoder = JSONEncoder()
func emit(_ r: Result) { print(String(decoding: try! encoder.encode(r), as: UTF8.self)); fflush(stdout) }

func fetch(_ url: String, http3: Bool = false) async -> (String?, String, String?) {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 20
    var req = URLRequest(url: URL(string: url)!)
    req.assumesHTTP3Capable = http3
    let session = URLSession(configuration: cfg)
    let recorder = MetricsRecorder()
    let task = Task { try await session.data(for: req, delegate: recorder) }
    do {
        let (data, _) = try await task.value
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, "ok", recorder.protocolName)
    } catch {
        return (nil, (error as NSError).localizedDescription, nil)
    }
}

final class MetricsRecorder: NSObject, URLSessionTaskDelegate {
    var protocolName: String?
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        protocolName = metrics.transactionMetrics.last?.networkProtocolName
    }
}

func udpDNS(server: String, name: String) async -> Result {
    // Minimal DNS A query, no dependencies.
    var q = Data([0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
    for label in name.split(separator: ".") { q.append(UInt8(label.count)); q.append(contentsOf: Array(label.utf8)) }
    q.append(contentsOf: [0, 0, 1, 0, 1])
    let conn = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
    conn.start(queue: .global())
    return await withCheckedContinuation { cont in
        let done = NSLock(); var finished = false
        func finish(_ r: Result) { done.lock(); defer { done.unlock() }; if !finished { finished = true; conn.cancel(); cont.resume(returning: r) } }
        conn.send(content: q, completion: .contentProcessed { e in if let e { finish(Result(check: "udp_dns", ok: false, ip: nil, detail: "send: \(e)")) } })
        conn.receiveMessage { data, _, _, e in
            if let data, data.count > 12 { finish(Result(check: "udp_dns", ok: true, ip: nil, detail: "answer \(data.count) bytes from \(server)")) }
            else { finish(Result(check: "udp_dns", ok: false, ip: nil, detail: e.map { "\($0)" } ?? "empty")) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(Result(check: "udp_dns", ok: false, ip: nil, detail: "timeout (blocked or dropped)")) }
    }
}

func websocket() async -> Result {
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: URL(string: "wss://echo.websocket.org")!)
    task.resume()
    do {
        try await task.send(.string("pipe-probe"))
        // echo.websocket.org sends a greeting first, then echoes.
        for _ in 0..<3 {
            if case .string(let s) = try await task.receive(), s == "pipe-probe" {
                task.cancel(with: .normalClosure, reason: nil)
                return Result(check: "websocket", ok: true, ip: nil, detail: "echo received")
            }
        }
        return Result(check: "websocket", ok: false, ip: nil, detail: "no echo")
    } catch {
        return Result(check: "websocket", ok: false, ip: nil, detail: (error as NSError).localizedDescription)
    }
}

func systemDNS(_ name: String) -> Result {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(name, nil, &hints, &res)
    defer { if res != nil { freeaddrinfo(res) } }
    // The name does not exist; NXDOMAIN (EAI_NONAME) still means the query was sent and answered.
    let answered = rc == 0 || rc == EAI_NONAME
    return Result(check: "system_dns", ok: answered, ip: nil, detail: answered ? "system resolver answered; tcpdump shows where the query went" : String(cString: gai_strerror(rc)))
}

func runHelper(_ name: String, check: String) -> Result {
    let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name).app/Contents/MacOS/\(name)")
    let p = Process(); p.executableURL = url; p.arguments = ["--ip-only"]
    let pipe = Pipe(); p.standardOutput = pipe
    do { try p.run() } catch { return Result(check: check, ok: false, ip: nil, detail: "spawn failed: \(error)") }
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let ok = p.terminationStatus == 0 && !out.isEmpty && !out.hasPrefix("error")
    return Result(check: check, ok: ok, ip: ok ? out : nil, detail: ok ? "helper saw \(out)" : out)
}

let sem = DispatchSemaphore(value: 0)
Task {
    if CommandLine.arguments.contains("--ip-only") {
        let (ip, detail, _) = await fetch("https://api64.ipify.org")
        print(ip ?? "error: \(detail)")
        exit(ip == nil ? 1 : 0)
    }
    let (ip4, d4, _) = await fetch("https://api4.ipify.org"); emit(Result(check: "ipv4_tcp", ok: ip4 != nil, ip: ip4, detail: d4))
    let (ip6, d6, _) = await fetch("https://api6.ipify.org"); emit(Result(check: "ipv6_tcp", ok: ip6 != nil, ip: ip6, detail: d6))
    let (ipAny, dAny, _) = await fetch("https://api64.ipify.org"); emit(Result(check: "tcp_any", ok: ipAny != nil, ip: ipAny, detail: dAny))
    emit(await udpDNS(server: "1.1.1.1", name: "example.com"))
    let (_, dq, proto) = await fetch("https://cloudflare-quic.com/", http3: true)
    emit(Result(check: "quic", ok: proto == "h3", ip: nil, detail: proto.map { "negotiated \($0)" } ?? dq))
    emit(await websocket())
    emit(systemDNS("probe-\(UUID().uuidString.prefix(8).lowercased()).example.com"))
    emit(runHelper("PipeProbe Helper", check: "helper_prefix_match"))
    emit(runHelper("Unrelated Helper", check: "helper_path_match"))
    sem.signal()
}
sem.wait()
