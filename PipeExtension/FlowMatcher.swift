import Foundation
import NetworkExtension
import Network
import Security
import PipeCore

@_silgen_name("proc_pidpath") private func proc_pidpath(_ pid: pid_t, _ buffer: UnsafeMutablePointer<CChar>, _ size: UInt32) -> Int32

/// Decides which route (if any) a flow belongs to. Called synchronously from handleNewFlow,
/// so it is lock-based, not an actor.
final class FlowMatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [Route] = []
    /// audit token -> executable path. An audit token embeds pid + pid generation, so it is
    /// unique per process incarnation and safe to cache on (a reused pid gets a new token).
    private var pathCache: [Data: String] = [:]

    func update(routes: [Route]) {
        lock.lock(); defer { lock.unlock() }
        self.routes = routes.filter { $0.isEnabled }
        pathCache.removeAll()
    }

    func route(for flow: NEAppProxyFlow) -> Route? {
        lock.lock(); defer { lock.unlock() }
        if routes.isEmpty { return nil }
        let meta = flow.metaData
        let signingID = meta.sourceAppSigningIdentifier
        // 1. Exact bundle id, or a helper whose signing id is namespaced under it
        //    (Electron: com.hnc.Discord.helper.Renderer, Chromium: com.google.Chrome.helper).
        for route in routes where signingID == route.appBundleID || signingID.hasPrefix(route.appBundleID + ".") {
            return route
        }
        // 2. Helper signed with an unrelated identifier but living inside the chosen .app bundle.
        guard let token = meta.sourceAppAuditToken, let path = executablePath(auditToken: token) else { return nil }
        for route in routes where path.hasPrefix(route.appPath + "/") {
            return route
        }
        return nil
    }

    private func executablePath(auditToken: Data) -> String? {
        if let cached = pathCache[auditToken] { return cached }
        guard let path = pathViaSecCode(auditToken) ?? pathViaLibproc(auditToken) else {
            Log.flow.error("could not resolve executable path for a flow's audit token")
            return nil
        }
        if pathCache.count > 512 { pathCache.removeAll() }
        pathCache[auditToken] = path
        return path
    }

    private func pathViaSecCode(_ auditToken: Data) -> String? {
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        let s1 = SecCodeCopyGuestWithAttributes(nil, attrs, [], &code)
        guard s1 == errSecSuccess, let code else { Log.flow.debug("SecCodeCopyGuestWithAttributes: \(s1)"); return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        let s3 = SecCodeCopyPath(staticCode, [], &url)
        guard s3 == errSecSuccess, let path = (url as URL?)?.path else { Log.flow.debug("SecCodeCopyPath: \(s3)"); return nil }
        return path
    }

    /// Fallback: pid from the audit token, then the kernel's record of the executable path.
    /// The token's pid generation makes a recycled pid harmless for the cache above.
    private func pathViaLibproc(_ auditToken: Data) -> String? {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return nil }
        let token = auditToken.withUnsafeBytes { $0.load(as: audit_token_t.self) }
        let pid = pid_t(token.val.5) // audit_token_t layout: val[5] is the pid
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { Log.flow.debug("proc_pidpath failed for pid \(pid)"); return nil }
        return String(cString: buf)
    }
}

/// Destination classification. Local destinations never go to a remote proxy: a remote proxy
/// cannot reach 127.0.0.1 or 192.168.x.x on this Mac's network anyway.
enum Destination {
    static func isLoopback(_ host: Network.NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback
        case .name(let n, _): return n == "localhost" || n.hasSuffix(".localhost")
        @unknown default: return false
        }
    }

    static func isPrivateNetwork(_ host: Network.NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || a.isLinkLocal
        case .ipv6(let a):
            return a.isLinkLocal || a.isUniqueLocal
        default:
            return false
        }
    }
}
