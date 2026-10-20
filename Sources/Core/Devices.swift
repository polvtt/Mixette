import CoreAudio
import Foundation

enum Direction { case output, input
    var scope: AudioObjectPropertyScope { self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput }
}

struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    var volume: Float?          // nil : pas de réglage de volume matériel
    var muted: Bool?
    var canSetVolume = false
    var canMute = false

    var symbol: String {
        let n = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return n.contains("micro") || n.contains("mic") ? "mic.fill" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if n.contains("airpods max") { return "airpodsmax" }
            if n.contains("airpods pro") { return "airpodspro" }
            if n.contains("airpods") { return "airpods" }
            if n.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeThunderbolt: return "bolt.horizontal"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iphone"
        case kAudioDeviceTransportTypeAggregate: return "rectangle.stack.fill"
        case kAudioDeviceTransportTypeVirtual: return "waveform"
        default: return "speaker.wave.2.fill"
        }
    }
}

/// Liste des appareils, appareil par défaut, volume/mute matériels, avec écouteurs.
@MainActor
final class DeviceMonitor {
    nonisolated static let privatePrefix = "Mixette-"

    private(set) var outputs: [AudioDevice] = []
    private(set) var inputs: [AudioDevice] = []
    private(set) var defaultOutputUID: String?
    private(set) var defaultInputUID: String?
    var onChange: (() -> Void)?
    /// Appelé quand la LISTE ou l'appareil par défaut change (pas pour un simple volume).
    var onTopologyChange: (() -> Void)?

    private var systemListeners: [CAListener] = []
    private var deviceListeners: [AudioObjectID: [CAListener]] = [:]
    private var pending = false

    func start() {
        let sys = CA.system
        systemListeners = [
            CAListener(sys, CA.address(kAudioHardwarePropertyDevices)) { [weak self] in self?.schedule(topology: true) },
            CAListener(sys, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in self?.schedule(topology: true) },
            CAListener(sys, CA.address(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in self?.schedule(topology: true) },
        ]
        reload(topology: true)
    }

    private var pendingTopology = false
    private func schedule(topology: Bool) {
        pendingTopology = pendingTopology || topology
        guard !pending else { return }
        pending = true
        // Les changements arrivent en rafale (branchement Bluetooth) : on regroupe.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.pending = false
            let t = self.pendingTopology
            self.pendingTopology = false
            self.reload(topology: t)
        }
    }

    private func reload(topology: Bool) {
        if !topology, !outputs.isEmpty || !inputs.isEmpty {
            // Simple changement de volume/mute : ne relire que ces deux propriétés.
            for i in outputs.indices { fillVolume(&outputs[i], .output) }
            for i in inputs.indices { fillVolume(&inputs[i], .input) }
            onChange?()
            return
        }
        let ids = CA.readIDs(CA.system, CA.address(kAudioHardwarePropertyDevices))
        var outs: [AudioDevice] = [], ins: [AudioDevice] = []
        for id in ids {
            guard let uid = CA.readString(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix(Self.privatePrefix) else { continue }
            if CA.read(id, CA.address(kAudioDevicePropertyIsHidden), as: UInt32.self) == 1 { continue }
            let name = CA.readString(id, kAudioObjectPropertyName) ?? uid
            let transport = CA.read(id, CA.address(kAudioDevicePropertyTransportType), as: UInt32.self) ?? 0
            for dir in [Direction.output, .input] where !CA.streamChannels(id, dir.scope).isEmpty {
                var d = AudioDevice(id: id, uid: uid, name: name, transport: transport)
                fillVolume(&d, dir)
                if dir == .output { outs.append(d) } else { ins.append(d) }
            }
            if deviceListeners[id] == nil { installListeners(id) }
        }
        for gone in Set(deviceListeners.keys).subtracting(ids) { deviceListeners[gone] = nil }
        let byName: (AudioDevice, AudioDevice) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        outputs = outs.sorted(by: byName)
        inputs = ins.sorted(by: byName)
        defaultOutputUID = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        defaultInputUID = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        onChange?()                         // d'abord publier les appareils…
        if topology { onTopologyChange?() } // …puis réconcilier les taps avec cet état
    }

    private func defaultDevice(_ sel: AudioObjectPropertySelector) -> String? {
        guard let id = CA.read(CA.system, CA.address(sel), as: AudioObjectID.self), id != 0 else { return nil }
        return CA.readString(id, kAudioDevicePropertyDeviceUID)
    }

    private func installListeners(_ id: AudioObjectID) {
        var ls: [CAListener] = []
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
            for a in Self.volumeAddresses(scope) + [CA.address(kAudioDevicePropertyMute, scope)] where CA.has(id, a) {
                ls.append(CAListener(id, a) { [weak self] in self?.schedule(topology: false) })
            }
        }
        deviceListeners[id] = ls
    }

    // Trois stratégies, dans l'ordre : volume virtuel « maître », scalaire maître, scalaire canal 1.
    nonisolated static func volumeAddresses(_ scope: AudioObjectPropertyScope) -> [AudioObjectPropertyAddress] {
        [CA.address(CA.virtualMainVolume, scope),
         CA.address(kAudioDevicePropertyVolumeScalar, scope),
         CA.address(kAudioDevicePropertyVolumeScalar, scope, 1)]
    }

    private func volumeAddress(_ id: AudioObjectID, _ dir: Direction) -> AudioObjectPropertyAddress? {
        Self.volumeAddresses(dir.scope).first { CA.has(id, $0) }
    }

    private func fillVolume(_ d: inout AudioDevice, _ dir: Direction) {
        if let a = volumeAddress(d.id, dir) {
            d.volume = CA.read(d.id, a, as: Float32.self)
            d.canSetVolume = CA.settable(d.id, a)
        }
        let m = CA.address(kAudioDevicePropertyMute, dir.scope)
        if CA.has(d.id, m) {
            d.muted = CA.read(d.id, m, as: UInt32.self).map { $0 != 0 }
            d.canMute = CA.settable(d.id, m)
        }
    }

    // MARK: Actions

    func setDefault(_ uid: String, _ dir: Direction) {
        guard let id = CA.device(forUID: uid) else { return }
        let sel = dir == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        do {
            try CA.write(CA.system, CA.address(sel), id, "défaut")
            // Les sons système suivent la sortie par défaut, comme le fait le panneau Son.
            if dir == .output { try? CA.write(CA.system, CA.address(kAudioHardwarePropertyDefaultSystemOutputDevice), id, "système") }
        } catch { Log.core.error("setDefault: \(String(describing: error), privacy: .public)") }
    }

    private let writer = VolumeWriter()

    /// Écriture coalescée hors du fil principal : un glissement de curseur produit des
    /// dizaines de valeurs par seconde, seule la plus récente part vers le matériel.
    func setVolume(_ uid: String, _ dir: Direction, _ v: Float) {
        let v = max(0, min(1, v))
        // Monter le volume d'un appareil coupé le réactive (comportement du système).
        let unmute = v > 0 && muted(uid, dir) == true
        writer.submit(uid: uid, scope: dir.scope, value: v, unmute: unmute)
    }

    func setMuted(_ uid: String, _ dir: Direction, _ m: Bool) {
        guard let id = CA.device(forUID: uid) else { return }
        try? CA.write(id, CA.address(kAudioDevicePropertyMute, dir.scope), UInt32(m ? 1 : 0), "mute")
    }

    private func muted(_ uid: String, _ dir: Direction) -> Bool? {
        (dir == .output ? outputs : inputs).first { $0.uid == uid }?.muted
    }
}

/// File d'écriture des volumes matériels : au plus une écriture en cours par appareil,
/// la valeur en attente est remplacée par la plus récente (les écritures Bluetooth peuvent
/// prendre plusieurs dizaines de ms et bloqueraient l'interface).
final class VolumeWriter: @unchecked Sendable {
    private struct Job { var value: Float; var unmute: Bool }
    private let queue = DispatchQueue(label: "com.polat.mixette.volume", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [String: Job] = [:]
    private var busy: Set<String> = []

    func submit(uid: String, scope: AudioObjectPropertyScope, value: Float, unmute: Bool) {
        let key = "\(scope):\(uid)"
        lock.lock()
        let wasUnmute = pending[key]?.unmute ?? false
        pending[key] = Job(value: value, unmute: unmute || wasUnmute)
        let start = busy.insert(key).inserted
        lock.unlock()
        if start { queue.async { self.drain(key, uid, scope) } }
    }

    private func drain(_ key: String, _ uid: String, _ scope: AudioObjectPropertyScope) {
        while true {
            lock.lock()
            guard let job = pending.removeValue(forKey: key) else { busy.remove(key); lock.unlock(); return }
            lock.unlock()
            Self.write(uid, scope, job.value)
            if job.unmute, let id = CA.device(forUID: uid) {
                try? CA.write(id, CA.address(kAudioDevicePropertyMute, scope), UInt32(0), "mute")
            }
        }
    }

    private static func write(_ uid: String, _ scope: AudioObjectPropertyScope, _ v: Float) {
        guard let id = CA.device(forUID: uid),
              let a = DeviceMonitor.volumeAddresses(scope).first(where: { CA.has(id, $0) }), CA.settable(id, a) else { return }
        try? CA.write(id, a, Float32(v), "volume")
        // Le scalaire « canal 1 » ne règle qu'un côté : appliquer aussi au canal 2.
        if a.mElement == 1 { try? CA.write(id, CA.address(kAudioDevicePropertyVolumeScalar, scope, 2), Float32(v), "volume") }
    }
}
