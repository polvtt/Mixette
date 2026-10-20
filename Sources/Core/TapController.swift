import CoreAudio
import Foundation
import os

enum Log {
    static let core = Logger(subsystem: "com.polat.mixette", category: "core")
    static let tap = Logger(subsystem: "com.polat.mixette", category: "tap")
}

/// Paramètres partagés avec le thread temps réel : écrits par le main, lus par l'IOProc.
/// Champs de 32 bits alignés → lectures/écritures atomiques sur arm64, aucun verrou dans le rendu.
struct RenderState {
    var target: Float32 = 1     // gain visé
    var current: Float32 = 1    // gain courant (rampe exponentielle vers target)
    var coef: Float32 = 0.003   // 1 − e^(−1/(τ·fs)), τ ≈ 15 ms
    var limiter: UInt32 = 0     // limiteur doux actif (boost > ×1)
    var peak: Float32 = 0       // crête du dernier cycle, pour l'affichage
    var inPeak: Float32 = 0     // crête du tap avant gain (diagnostic)
    var inBuffers: UInt32 = 0   // tampons d'entrée reçus au dernier cycle (diagnostic)
    var cycles: UInt32 = 0      // nombre de cycles IO (diagnostic)
}

/// Capture le son d'UNE app (process tap muet) et le rejoue, gain appliqué, sur un ou
/// plusieurs appareils via un agrégat privé :
///
///   processus de l'app ─► tap (mutedWhenTapped) ─► entrée de l'agrégat
///                                                     │  IOProc : × gain, limiteur
///                                  sortie(s) de l'agrégat ◄┘ = appareil(s) choisi(s)
///
/// Si Mixette s'arrête ou plante, tap et agrégat privés disparaissent avec le processus et
/// l'app retrouve son son d'origine : rien ne reste « coincé ».
final class TapController {
    let appID: String
    let name: String
    private(set) var processes: [AudioObjectID]
    let deviceUIDs: [String]

    private var tapDescription: CATapDescription?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let state = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
    /// 3 entiers par tampon de sortie : canal recevant L (−1 : aucun), canal recevant R, mono.
    private var outMap = UnsafeMutablePointer<Int32>.allocate(capacity: 3)
    private var outCount = 0
    private(set) var running = false

    init(appID: String, name: String, processes: [AudioObjectID], deviceUIDs: [String], gain: Float, limiter: Bool, startGain: Float) {
        self.appID = appID
        self.name = name
        self.processes = processes
        self.deviceUIDs = deviceUIDs
        state.initialize(to: RenderState(target: gain, current: startGain, limiter: limiter ? 1 : 0))
    }

    deinit {
        stop()
        state.deallocate()
        outMap.deallocate()
    }

    var peak: Float { state.pointee.peak }
    var diagnostics: String {
        let s = state.pointee
        return "cycles=\(s.cycles) entrées=\(s.inBuffers) crête-tap=\(s.inPeak) crête-sortie=\(s.peak) gain=\(s.current)→\(s.target) sorties=\(outCount)"
    }

    func setGain(_ gain: Float, limiter: Bool) {
        state.pointee.limiter = limiter ? 1 : 0
        state.pointee.target = gain
    }

    // MARK: Cycle de vie

    func start() throws {
        do { try build() } catch { stop(); throw error }
    }

    private func build() throws {
        guard let mainUID = deviceUIDs.first else { throw CAError(status: -1, what: "aucun appareil de sortie") }

        // 1. Tap : mixage stéréo de tous les processus de l'app, muet tant qu'on le lit.
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.name = "Mixette – \(name)"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        try CA.check(AudioHardwareCreateProcessTap(desc, &tapID), "création du tap")
        tapDescription = desc

        // 2. Agrégat privé : appareil(s) cible(s) en sortie + le tap en entrée.
        let subs: [[String: Any]] = deviceUIDs.enumerated().map { i, uid in
            [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: i > 0]
        }
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixette – \(name)",
            kAudioAggregateDeviceUIDKey: DeviceMonitor.privatePrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: mainUID,
            kAudioAggregateDeviceSubDeviceListKey: subs,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        try CA.check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID), "création de l'agrégat")

        // L'agrégat publie ses flux de façon asynchrone : attendre (≤ 0,5 s) qu'ils existent.
        var outStreams: [Int] = []
        for _ in 0..<50 {
            outStreams = CA.streamChannels(aggregateID, kAudioObjectPropertyScopeOutput)
            if !outStreams.isEmpty, !CA.streamChannels(aggregateID, kAudioObjectPropertyScopeInput).isEmpty { break }
            usleep(10_000)
        }
        guard !outStreams.isEmpty else { throw CAError(status: -1, what: "agrégat sans flux de sortie (appareil pas prêt)") }

        let rate = CA.read(aggregateID, CA.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self) ?? 48_000
        state.pointee.coef = Float32(1 - exp(-1 / (0.015 * rate)))
        buildOutputMap(aggregateStreams: outStreams)

        // 3. IOProc sur le thread temps réel du HAL (queue nil : pas de saut de file).
        let st = state, map = outMap, n = outCount
        let block: AudioDeviceIOBlock = { _, inInput, _, outOutput, _ in
            TapController.render(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput)),
                                 UnsafeMutableAudioBufferListPointer(outOutput), st, map, n)
        }
        try CA.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, block), "création de l'IOProc")
        restrictInputsToTap()
        try CA.check(AudioDeviceStart(aggregateID, procID), "démarrage de l'agrégat")
        running = true
        Log.tap.notice("tap actif pour \(self.name, privacy: .public) → \(self.deviceUIDs.count) appareil(s) à \(rate) Hz")
    }

    /// Répartition L/R sur les flux de sortie de l'agrégat : les flux arrivent dans l'ordre
    /// des sous-appareils ; L et R vont sur les 2 premiers canaux de CHAQUE sous-appareil.
    private func buildOutputMap(aggregateStreams: [Int]) {
        var entries: [Int32] = []
        for uid in deviceUIDs {
            guard let dev = CA.device(forUID: uid) else { continue }
            let chans = CA.streamChannels(dev, kAudioObjectPropertyScopeOutput)
            let total = chans.reduce(0, +)
            var c0 = 0
            for ch in chans {
                let l = (c0..<(c0 + ch)).contains(0) ? Int32(0 - c0) : -1
                let r = total > 1 && (c0..<(c0 + ch)).contains(1) ? Int32(1 - c0) : -1
                entries += [l, r, total == 1 ? 1 : 0]
                c0 += ch
            }
        }
        if entries.count / 3 != aggregateStreams.count {
            Log.tap.error("flux inattendus (\(aggregateStreams.count) vs \(entries.count / 3)) : sortie sur le 1er flux seulement")
            let ch = aggregateStreams[0]
            entries = [0, ch > 1 ? 1 : -1, ch == 1 ? 1 : 0]
        }
        outMap.deallocate()
        outMap = UnsafeMutablePointer<Int32>.allocate(capacity: entries.count)
        outMap.initialize(from: entries, count: entries.count)
        outCount = entries.count / 3
    }

    /// Les flux d'entrée des sous-appareils précèdent celui du tap (vérifié par sonde).
    /// Les couper évite d'ouvrir un micro inutilement, ce qui ferait passer un casque
    /// Bluetooth en profil « appel » (HFP) de basse qualité.
    private func restrictInputsToTap() {
        guard let procID else { return }
        let n = CA.readIDs(aggregateID, CA.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)).count
        guard n > 1 else { return }
        var a = CA.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &a, 0, nil, &size) == noErr, size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateID, &a, 0, nil, &size, raw) == noErr else { return }
        let count = Int(raw.load(fromByteOffset: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams)!, as: UInt32.self))
        let flags = raw.advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).assumingMemoryBound(to: UInt32.self)
        for i in 0..<count { flags[i] = i == count - 1 ? 1 : 0 }
        let st = AudioObjectSetPropertyData(aggregateID, &a, 0, nil, size, raw)
        if st != noErr { Log.tap.error("stream usage : \(st)") }
    }

    /// Nouveaux processus (un onglet Safari qui démarre un helper…) : mise à jour en place.
    func updateProcesses(_ objects: [AudioObjectID]) -> Bool {
        guard let desc = tapDescription, tapID != kAudioObjectUnknown else { return false }
        desc.processes = objects
        var a = CA.address(kAudioTapPropertyDescription)
        var ref = Unmanaged.passUnretained(desc).toOpaque()
        let st = AudioObjectSetPropertyData(tapID, &a, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &ref)
        if st == noErr { processes = objects; return true }
        Log.tap.error("mise à jour du tap refusée : \(st)")
        return false
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                if running { AudioDeviceStop(aggregateID, procID) }
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapDescription = nil
        running = false
    }

    // MARK: Rendu temps réel — ni allocation, ni verrou, ni appel Objective-C.

    private static func render(_ ins: UnsafeMutableAudioBufferListPointer, _ outs: UnsafeMutableAudioBufferListPointer,
                               _ st: UnsafeMutablePointer<RenderState>, _ map: UnsafeMutablePointer<Int32>, _ mapCount: Int) {
        for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        st.pointee.cycles &+= 1
        st.pointee.inBuffers = UInt32(ins.count)
        guard ins.count > 0 else { return }
        let src = ins[ins.count - 1]            // le tap est le dernier flux d'entrée
        guard let sp = src.mData?.assumingMemoryBound(to: Float32.self) else { return }
        let inCh = max(1, Int(src.mNumberChannels))
        let frames = Int(src.mDataByteSize) / (4 * inCh)

        let target = st.pointee.target, k = st.pointee.coef, limit = st.pointee.limiter != 0
        var g = st.pointee.current
        if target == 0, g < 1e-5 { st.pointee.current = 0; st.pointee.peak = 0; return }

        let n = min(outs.count, mapCount)
        var peak: Float32 = 0, inPeak: Float32 = 0
        for f in 0..<frames { inPeak = max(inPeak, abs(sp[f * inCh])) }
        st.pointee.inPeak = inPeak
        for f in 0..<frames {
            g += (target - g) * k
            var l = sp[f * inCh] * g
            var r = (inCh > 1 ? sp[f * inCh + 1] : sp[f * inCh]) * g
            if limit { l = softClip(l); r = softClip(r) }
            peak = max(peak, max(abs(l), abs(r)))
            for i in 0..<n {
                let b = outs[i]
                guard let d = b.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                let ch = Int(b.mNumberChannels)
                guard ch > 0, f < Int(b.mDataByteSize) / (4 * ch) else { continue }
                let li = Int(map[i * 3]), ri = Int(map[i * 3 + 1])
                if map[i * 3 + 2] != 0 {
                    if li >= 0 { d[f * ch + li] = (l + r) * 0.5 }
                } else {
                    if li >= 0 { d[f * ch + li] = l }
                    if ri >= 0 { d[f * ch + ri] = r }
                }
            }
        }
        st.pointee.current = g
        st.pointee.peak = peak
    }

    /// Linéaire jusqu'à −1,4 dBFS, puis genou en tanh qui tend vers 1 : le boost ne sature jamais.
    @inline(__always) private static func softClip(_ x: Float32) -> Float32 {
        let a = abs(x)
        guard a > 0.85 else { return x }
        let y = 0.85 + 0.15 * tanhf((a - 0.85) / 0.15)
        return x < 0 ? -y : y
    }
}
