import Foundation

struct AppSettings: Codable, Equatable {
    var volume: Float = 1          // position du curseur, 0…1
    var muted = false
    var boost = 1                  // ×1 … ×4
    var outputs: [String] = []     // UID des sorties choisies ; vide = suit la sortie par défaut

    static let maxBoost = 4

    /// Courbe perceptive : le curseur suit à peu près l'oreille (½ ≈ −12 dB).
    var gain: Float { muted ? 0 : volume * volume * Float(boost) }
    var isUnityGain: Bool { !muted && volume >= 0.999 && boost == 1 }
    var isDefault: Bool { isUnityGain && outputs.isEmpty }
}

struct PersistedSettings: Codable {
    var schemaVersion = 1
    var apps: [String: AppSettings] = [:]
}

/// ~/Library/Application Support/Mixette/settings.json, écrit avec un délai (rafales du curseur).
@MainActor
final class SettingsStore {
    private let url: URL
    private var writeTask: DispatchWorkItem?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mixette", isDirectory: true)
        url = dir.appendingPathComponent("settings.json")
    }

    func load() -> PersistedSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(PersistedSettings.self, from: data) else { return PersistedSettings() }
        return s
    }

    func save(_ s: PersistedSettings) {
        writeTask?.cancel()
        let url = self.url
        let item = DispatchWorkItem {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(s).write(to: url, options: .atomic)
            } catch { Log.core.error("sauvegarde des réglages : \(error.localizedDescription, privacy: .public)") }
        }
        writeTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}
