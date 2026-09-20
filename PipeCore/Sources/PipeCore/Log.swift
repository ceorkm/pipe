import Foundation
import os

/// Structured logging. Everything is public-redaction-safe by construction: callers never pass
/// credentials, headers or payloads, only hostnames, ports, bundle ids and error descriptions.
public enum Log {
    public static let subsystem = PipeIdentifiers.appBundleID
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let proxy = Logger(subsystem: subsystem, category: "proxy")
    public static let flow = Logger(subsystem: subsystem, category: "flow")
    public static let ext = Logger(subsystem: subsystem, category: "extension")
}
