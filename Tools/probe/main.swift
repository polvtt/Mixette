import CoreAudio
import AppKit

func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ def: T) -> T {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = def; var sz = UInt32(MemoryLayout<T>.size)
    let st = AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v)
    return st == noErr ? v : def
}
func arr(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &out); return out
}
func str(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: Unmanaged<CFString>? ; var sz = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &s) == noErr, let s else { return "" }
    return s.takeRetainedValue() as String
}
typealias RespFn = @convention(c) (pid_t) -> pid_t
let resp = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: RespFn.self) }
print("responsibility fn:", resp != nil)
let sys = AudioObjectID(kAudioObjectSystemObject)
print("== processes")
for p in arr(sys, kAudioHardwarePropertyProcessObjectList) {
    let pid: pid_t = get(p, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, -1)
    let out: UInt32 = get(p, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, 0)
    let r = resp?(pid) ?? pid
    let app = NSRunningApplication(processIdentifier: r)
    print(p, pid, "resp", r, out == 1 ? "OUT" : "   ", str(p, kAudioProcessPropertyBundleID), "→", app?.localizedName ?? "-")
}
print("== devices")
for d in arr(sys, kAudioHardwarePropertyDevices) {
    let tr: UInt32 = get(d, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0)
    let tc = String(bytes: withUnsafeBytes(of: tr.bigEndian, Array.init), encoding: .ascii) ?? "?"
    print(d, str(d, kAudioObjectPropertyName), "|", str(d, kAudioDevicePropertyDeviceUID), tc,
          "in", arr(d, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count,
          "out", arr(d, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).count)
}
let defOut: AudioObjectID = get(sys, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0)
let defIn: AudioObjectID = get(sys, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, 0)
print("default out", defOut, "in", defIn)

// Aggregate ordering test: subdevices = default input + default output, + a tap on nothing-ish (own process)
if CommandLine.arguments.contains("--agg") {
    let me: AudioObjectID = {
        var pid = getpid(); var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var o = AudioObjectID(0); var sz = UInt32(4)
        AudioObjectGetPropertyData(sys, &a, 4, &pid, &sz, &o); return o }()
    let desc = CATapDescription(stereoMixdownOfProcesses: [])
    desc.isPrivate = true; desc.muteBehavior = .unmuted
    var tap = AudioObjectID(0)
    print("create tap:", AudioHardwareCreateProcessTap(desc, &tap), tap, "me", me)
    let tapUID = desc.uuid.uuidString
    let outUID = str(defOut, kAudioDevicePropertyDeviceUID), inUID = str(defIn, kAudioDevicePropertyDeviceUID)
    let d: [String: Any] = [kAudioAggregateDeviceNameKey: "Mixette-probe", kAudioAggregateDeviceUIDKey: "Mixette-probe-\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceMainSubDeviceKey: outUID,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: inUID], [kAudioSubDeviceUIDKey: outUID]],
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        kAudioAggregateDeviceTapAutoStartKey: true]
    var agg = AudioObjectID(0)
    print("create agg:", AudioHardwareCreateAggregateDevice(d as CFDictionary, &agg), agg)
    for s in arr(agg, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput) {
        var f: AudioStreamBasicDescription = get(s, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
        let start: UInt32 = get(s, kAudioStreamPropertyStartingChannel, kAudioObjectPropertyScopeGlobal, 0)
        print(" in stream", s, "ch", f.mChannelsPerFrame, "sr", f.mSampleRate, "start", start, "class", str(s, kAudioObjectPropertyName))
        _ = f
    }
    for s in arr(agg, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput) {
        let f: AudioStreamBasicDescription = get(s, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
        print(" out stream", s, "ch", f.mChannelsPerFrame, "interleaved", f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
    }
    let tf: AudioStreamBasicDescription = get(tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
    print("tap format ch", tf.mChannelsPerFrame, "sr", tf.mSampleRate)
    print("active subtaps", arr(agg, kAudioAggregateDevicePropertyTapList), "subdevs", arr(agg, kAudioAggregateDevicePropertyActiveSubDeviceList))
    AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tap)
}
