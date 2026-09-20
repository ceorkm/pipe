import Foundation
import PipeCore

/// Persists PipeConfig as JSON in Application Support. No secrets ever land here.
struct ConfigStore {
    let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pipe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
    }

    func load() -> PipeConfig {
        guard let data = try? Data(contentsOf: url) else { return PipeConfig() }
        do {
            return try JSONDecoder().decode(PipeConfig.self, from: data)
        } catch {
            Log.app.error("config.json unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return PipeConfig()
        }
    }

    func save(_ config: PipeConfig) {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(config).write(to: url, options: .atomic)
        } catch {
            Log.app.error("config save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
