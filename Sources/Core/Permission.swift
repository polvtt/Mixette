import AppKit

/// Autorisation « Enregistrement audio du système » (kTCCServiceAudioCapture).
/// Pas d'API publique pour la lire : on passe par le SPI de TCC.framework
/// chargé dynamiquement, avec repli sur « inconnu » s'il manque.
enum AudioPermission {
    enum Status: String { case granted, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @convention(block) @escaping (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static func symbol<T>(_ name: String, _: T.Type) -> T? {
        guard let tcc, let p = dlsym(tcc, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    nonisolated(unsafe) private static var lastRaw: Int32 = -99

    static func status() -> Status {
        guard let f = symbol("TCCAccessPreflight", Preflight.self) else { return .unknown }
        let raw = f(service, nil)
        if raw != lastRaw { lastRaw = raw; Log.core.notice("TCCAccessPreflight(AudioCapture) = \(raw)") }
        switch raw {          // 0 accordé, 1 refusé, autre : jamais demandé
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let f = symbol("TCCAccessRequest", Request.self) else { Task { @MainActor in done(false) }; return }
        f(service, nil) { granted in Task { @MainActor in done(granted) } }
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
