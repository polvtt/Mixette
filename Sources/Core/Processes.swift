import AppKit
import CoreAudio

/// Une application audible = l'app « responsable » + tous ses processus audio
/// (Safari joue depuis com.apple.WebKit.GPU, Discord depuis ses helpers…).
struct AudioApp: Identifiable, Equatable {
    let id: String              // clé de persistance : bundle ID de l'app responsable, sinon nom
    let pid: pid_t              // PID responsable
    let name: String
    let bundleID: String?
    var processObjects: [AudioObjectID]
    var isPlaying: Bool

    var icon: NSImage {
        if let app = NSRunningApplication(processIdentifier: pid), let i = app.icon { return i }
        return NSWorkspace.shared.icon(for: .application)
    }
}

@MainActor
final class ProcessMonitor {
    private(set) var apps: [AudioApp] = []
    var onChange: (() -> Void)?

    /// Apps vues en train de jouer pendant cette session : elles restent listées en pause.
    private var seen: Set<String> = []
    /// Apps à garder visibles même silencieuses (réglage personnalisé).
    var pinned: Set<String> = [] { didSet { if pinned != oldValue { reload() } } }

    private var listListener: CAListener?
    private var perProcess: [AudioObjectID: [CAListener]] = [:]
    private var safetyNet: Timer?
    private var pending = false
    private let ownPID = getpid()

    // Démons et services système qui ouvrent une sortie audio sans intérêt pour l'utilisateur.
    private static let systemBundles: Set<String> = [
        "systemsoundserverd", "com.apple.mediaremoted", "com.apple.audiomxd", "com.apple.controlcenter",
        "com.apple.universalaccessd", "com.apple.CoreSpeech", "com.apple.corespeech", "com.apple.accessibility.heard",
        "com.apple.hearingd", "com.apple.assistantd", "com.apple.assistant", "com.apple.Siri", "com.apple.siri",
        "com.apple.SiriNCService", "com.apple.PowerChime", "com.apple.TelephonyUtilities", "com.apple.avconferenced",
        "com.apple.cmio.ContinuityCaptureAgent", "com.apple.cloudpaird", "com.apple.voicebankingd",
        "com.apple.notificationcenterui", "com.apple.UserNotificationCenter", "com.apple.dictation",
        "com.apple.SpeechRecognitionCore", "com.apple.speech.speechsynthesisd", "com.apple.VoiceControl",
    ]

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    /// SPI libsystem : PID du processus « responsable » (l'app qui a lancé ce helper).
    private static let responsible: ResponsibleFn? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(p, to: ResponsibleFn.self)
    }()

    func start() {
        listListener = CAListener(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in self?.schedule() }
        // Filet de sécurité : le passage « en lecture » d'un processus
        // n'est pas toujours notifié. Musique, lancée sans jouer puis mise en lecture,
        // restait invisible. Relevé léger (quelques dizaines de propriétés) toutes les 2 s.
        safetyNet = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pending = false
            self?.reload()
        }
    }

    func reload() {
        let objects = CA.readIDs(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList))
        for o in objects where perProcess[o] == nil {
            perProcess[o] = [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunning].map {
                CAListener(o, CA.address($0)) { [weak self] in self?.schedule() }
            }
        }
        for gone in Set(perProcess.keys).subtracting(objects) { perProcess[gone] = nil }

        var groups: [pid_t: AudioApp] = [:]
        for o in objects {
            guard let pid = CA.read(o, CA.address(kAudioProcessPropertyPID), as: pid_t.self), pid > 0, pid != ownPID else { continue }
            let bundle = CA.readString(o, kAudioProcessPropertyBundleID) ?? ""
            let playing = CA.read(o, CA.address(kAudioProcessPropertyIsRunningOutput), as: UInt32.self) == 1
            let r = Self.responsible?(pid) ?? pid
            let rpid = r > 0 ? r : pid
            if rpid == ownPID { continue }

            if var g = groups[rpid] {
                g.processObjects.append(o)
                g.isPlaying = g.isPlaying || playing
                groups[rpid] = g
                continue
            }
            let app = NSRunningApplication(processIdentifier: rpid)
            let appBundle = app?.bundleIdentifier ?? bundle
            if Self.systemBundles.contains(appBundle) || Self.systemBundles.contains(bundle) { continue }
            let regular = app?.activationPolicy == .regular
            // Processus sans app visible (outil en ligne de commande, agent) : seulement s'il joue.
            if !regular && !playing && app == nil { continue }
            let name = app?.localizedName ?? Self.processName(pid) ?? (bundle.isEmpty ? "PID \(pid)" : bundle)
            groups[rpid] = AudioApp(id: appBundle.isEmpty ? name : appBundle, pid: rpid, name: name,
                                    bundleID: appBundle.isEmpty ? nil : appBundle,
                                    processObjects: [o], isPlaying: playing)
        }

        for g in groups.values where g.isPlaying { seen.insert(g.id) }
        let list = groups.values
            .filter { $0.isPlaying || seen.contains($0.id) || pinned.contains($0.id) }
            // Tri par nom seulement : une ligne ne doit pas sauter quand l'app se met en pause.
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Deux instances d'une même app (rare) partageraient la même clé : on garde la première.
        var ids = Set<String>()
        let unique = list.filter { ids.insert($0.id).inserted }
        if unique != apps {
            if unique.map(\.id) != apps.map(\.id) {
                Log.core.notice("apps : \(unique.map { $0.name + ($0.isPlaying ? "▶︎" : "") }.joined(separator: ", "), privacy: .public)")
            }
            apps = unique
            onChange?()
        }
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}
