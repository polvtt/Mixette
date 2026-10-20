import AppKit
import CoreAudio
import ServiceManagement

/// Modèle de l'app : appareils + apps audibles + réglages, et réconciliation des taps.
///
/// Règle centrale : on ne pose un tap QUE sur une app dont le réglage
/// diffère du comportement système (volume ≠ 100 %, muet, boost, sortie imposée). Les autres
/// apps ne passent pas par Mixette : zéro latence ajoutée, zéro risque.
@MainActor
final class Mixer: ObservableObject {
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var defaultInputUID: String?
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var settings: [String: AppSettings] = [:]
    @Published private(set) var permission: AudioPermission.Status = .unknown
    @Published private(set) var failures: [String: String] = [:]     // app → dernière erreur de tap
    @Published private(set) var peaks: [String: Float] = [:]          // app tapée → crête récente
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let devices = DeviceMonitor()
    private let processes = ProcessMonitor()
    private let store = SettingsStore()
    private var taps: [String: TapController] = [:]
    private var retiring: [TapController] = []
    private var retryAfter: [String: Date] = [:]     // après un échec, pas de nouvel essai avant 3 s
    private var permissionTimer: Timer?
    private var meterTimer: Timer?
    var panelVisible = false { didSet { updateMeterTimer() } }

    init() {
        settings = store.load().apps
        permission = AudioPermission.status()
        devices.onChange = { [weak self] in self?.pullDevices() }
        devices.onTopologyChange = { [weak self] in self?.reconcile() }
        processes.onChange = { [weak self] in self?.pullApps() }
        processes.pinned = Set(settings.filter { !$0.value.isDefault }.keys)
        devices.start()
        processes.start()
        if permission != .granted {
            // Des réglages enregistrés attendent d'être appliqués : demander tout de suite.
            if permission == .unknown, !settings.isEmpty, !Self.dryRun { requestPermission() }
            watchPermission()
        }
        reconcile()
    }

    private func pullDevices() {
        // N'assigner que ce qui change : chaque assignation @Published redessine le panneau.
        if outputs != devices.outputs { outputs = devices.outputs }
        if inputs != devices.inputs { inputs = devices.inputs }
        if defaultOutputUID != devices.defaultOutputUID { defaultOutputUID = devices.defaultOutputUID }
        if defaultInputUID != devices.defaultInputUID { defaultInputUID = devices.defaultInputUID }
    }

    private func pullApps() {
        apps = processes.apps
        reconcile()
    }

    // MARK: Réglages par app

    func settings(for app: AudioApp) -> AppSettings { settings[app.id] ?? AppSettings() }

    func update(_ app: AudioApp, _ change: (inout AppSettings) -> Void) {
        var s = settings(for: app)
        change(&s)
        settings[app.id] = s.isDefault ? nil : s
        processes.pinned = Set(settings.keys)
        store.save(PersistedSettings(apps: settings))
        if !s.isDefault, permission != .granted { requestPermission() }
        reconcile()
    }

    func setVolume(_ app: AudioApp, _ v: Float) {
        update(app) { s in
            s.volume = max(0, min(1, v))
            if v > 0 { s.muted = false }   // bouger le curseur réactive le son
        }
    }
    func toggleMute(_ app: AudioApp) { update(app) { $0.muted.toggle() } }
    func cycleBoost(_ app: AudioApp) { update(app) { $0.boost = $0.boost >= AppSettings.maxBoost ? 1 : $0.boost + 1 } }
    func followDefault(_ app: AudioApp) { update(app) { $0.outputs = [] } }
    func setOutput(_ app: AudioApp, only uid: String) { update(app) { $0.outputs = [uid] } }
    /// Ajoute/retire une sortie (envoi simultané sur plusieurs appareils).
    func toggleOutput(_ app: AudioApp, _ uid: String) {
        update(app) { s in
            if s.outputs.isEmpty, let d = defaultOutputUID { s.outputs = [d] }
            if let i = s.outputs.firstIndex(of: uid) { if s.outputs.count > 1 { s.outputs.remove(at: i) } }
            else { s.outputs.append(uid) }
        }
    }
    /// 100 % : volume plein, son réactivé, boost retiré (la sortie choisie est conservée).
    func setMax(_ app: AudioApp) { update(app) { $0.volume = 1; $0.muted = false; $0.boost = 1 } }
    func reset(_ app: AudioApp) { update(app) { $0 = AppSettings() } }

    /// Sorties effectivement utilisées par l'app (absentes filtrées, repli sur le défaut).
    func resolvedOutputs(_ s: AppSettings) -> [String] {
        let present = Set(outputs.map(\.uid))
        let chosen = s.outputs.filter(present.contains)
        if !chosen.isEmpty { return chosen }
        return defaultOutputUID.map { [$0] } ?? []
    }

    // MARK: Appareils

    func setDefault(_ d: AudioDevice, _ dir: Direction) { devices.setDefault(d.uid, dir) }
    /// Valeur affichée pendant un glissement : la position du curseur, pas celle que
    /// l'appareil renvoie (en retard, parfois arrondie), sinon le curseur « sautille ».
    @Published private(set) var deviceDrag: [String: Float] = [:]
    private var dragRelease: [String: DispatchWorkItem] = [:]
    private func dragKey(_ d: AudioDevice, _ dir: Direction) -> String { (dir == .output ? "out:" : "in:") + d.uid }

    func displayedVolume(_ d: AudioDevice, _ dir: Direction) -> Float? { deviceDrag[dragKey(d, dir)] ?? d.volume }

    func setVolume(_ d: AudioDevice, _ dir: Direction, _ v: Float) {
        let k = dragKey(d, dir)
        dragRelease[k]?.cancel()
        dragRelease[k] = nil
        deviceDrag[k] = v
        devices.setVolume(d.uid, dir, v)
    }

    /// Fin du geste : garder la valeur du curseur le temps que l'appareil la confirme.
    func endVolumeDrag(_ d: AudioDevice, _ dir: Direction) {
        let k = dragKey(d, dir)
        let item = DispatchWorkItem { [weak self] in
            self?.deviceDrag[k] = nil
            self?.dragRelease[k] = nil
        }
        dragRelease[k] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }
    func toggleMute(_ d: AudioDevice, _ dir: Direction) { devices.setMuted(d.uid, dir, !(d.muted ?? false)) }

    // MARK: Réconciliation

    /// Mode --snapshot : afficher sans jamais poser de tap.
    static let dryRun = CommandLine.arguments.contains("--snapshot")

    func reconcile() {
        if Self.dryRun { return }
        guard permission == .granted else {
            // Sans autorisation, un tap rendrait du silence : l'app serait coupée. Rien ne passe par nous.
            for t in taps.values { t.stop() }
            taps.removeAll()
            return
        }
        var wanted = Set<String>()
        for app in apps where !app.processObjects.isEmpty {
            let s = settings(for: app)
            let targets = resolvedOutputs(s)
            guard !targets.isEmpty else { continue }
            let needsTap = !s.isUnityGain || targets != [defaultOutputUID ?? ""]
            guard needsTap else { continue }
            wanted.insert(app.id)

            if let t = taps[app.id] {
                if t.deviceUIDs != targets {
                    handoff(app, from: t, to: targets, s)
                } else {
                    if t.processes != app.processObjects {
                        if t.updateProcesses(app.processObjects) {
                            Log.tap.notice("\(t.name, privacy: .public) : tap mis à jour, \(app.processObjects.count) processus")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak t] in
                                guard let t, t.running else { return }
                                Log.tap.notice("\(t.name, privacy: .public) : après mise à jour : \(t.diagnostics, privacy: .public)")
                            }
                        } else {
                            handoff(app, from: t, to: targets, s)
                        }
                        t.setGain(s.gain, limiter: s.boost > 1)
                    } else {
                        t.setGain(s.gain, limiter: s.boost > 1)
                    }
                }
            } else if (retryAfter[app.id] ?? .distantPast) <= Date() {
                // Sans tap, l'app jouait à 100 % : partir de là évite un trou.
                start(app, targets, s, startGain: 1)
            }
        }
        for (id, t) in taps where !wanted.contains(id) {
            t.stop()
            taps[id] = nil
            Log.core.notice("tap retiré pour \(t.name, privacy: .public) — réglages par défaut")
        }
        failures = failures.filter { wanted.contains($0.key) }
    }

    @discardableResult
    private func start(_ app: AudioApp, _ targets: [String], _ s: AppSettings, startGain: Float) -> TapController? {
        let t = TapController(appID: app.id, name: app.name, processes: app.processObjects, deviceUIDs: targets,
                              gain: s.gain, limiter: s.boost > 1, startGain: startGain)
        do {
            try t.start()
            taps[app.id] = t
            failures[app.id] = nil
            retryAfter[app.id] = nil
            // Diagnostic : une crête nulle alors que l'app joue = le tap ne reçoit rien (autorisation ?).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak t] in
                guard let t, t.running else { return }
                Log.tap.notice("\(t.name, privacy: .public) : après 2 s : \(t.diagnostics, privacy: .public)")
            }
            return t
        } catch {
            Log.core.error("tap \(app.name, privacy: .public) : \(String(describing: error), privacy: .public)")
            failures[app.id] = String(describing: error)
            retryAfter[app.id] = Date().addingTimeInterval(3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.reconcile() }
            return nil
        }
    }

    /// Changement de sortie sans coupure : le nouveau tap monte pendant que l'ancien descend
    /// (fondu enchaîné de ~120 ms), puis l'ancien est détruit.
    private func handoff(_ app: AudioApp, from old: TapController, to targets: [String], _ s: AppSettings) {
        taps[app.id] = nil
        guard start(app, targets, s, startGain: 0) != nil else {
            taps[app.id] = old          // échec : on garde l'ancien chemin
            old.setGain(s.gain, limiter: s.boost > 1)
            return
        }
        old.setGain(0, limiter: false)
        retiring.append(old)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            old.stop()
            self?.retiring.removeAll { $0 === old }
        }
    }

    func shutdown() {
        for t in taps.values + retiring { t.stop() }
        taps.removeAll()
        retiring.removeAll()
    }

    // MARK: Autorisation

    func requestPermission() {
        if permission == .denied { AudioPermission.openSettings(); watchPermission(); return }
        AudioPermission.request { [weak self] granted in
            guard let self else { return }
            self.permission = granted ? .granted : AudioPermission.status()
            if granted { self.reconcile() } else { self.watchPermission() }
        }
    }

    /// L'autorisation peut être accordée dans Réglages pendant que l'app tourne.
    private func watchPermission() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let s = AudioPermission.status()
                guard s != self.permission else { return }
                self.permission = s
                if s == .granted {
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                }
                self.reconcile()
            }
        }
    }

    // MARK: VU-mètres (seulement panneau ouvert, seulement les apps tapées)

    private func updateMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        guard panelVisible else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                var p: [String: Float] = [:]
                for (id, t) in self.taps { p[id] = max(t.peak, (self.peaks[id] ?? 0) * 0.82) }
                if p != self.peaks { self.peaks = p }
            }
        }
    }

    // MARK: Ouverture à la connexion

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { Log.core.error("SMAppService : \(error.localizedDescription, privacy: .public)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
