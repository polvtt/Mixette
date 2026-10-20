import CoreAudio
import Foundation

// Petits accès typés aux propriétés Core Audio (AudioObjectGet/SetPropertyData).

struct CAError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    var description: String { "\(what) : OSStatus \(status) (\(fourCC(UInt32(bitPattern: status))))" }
}

func fourCC(_ v: UInt32) -> String {
    let bytes = withUnsafeBytes(of: v.bigEndian, Array.init)
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(Int32(bitPattern: v)) }
    return "'" + String(decoding: bytes, as: UTF8.self) + "'"
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` ('vmvc'), déclaré dans
    /// AudioToolbox/AudioServices.h : le volume « maître » que montre la barre de menus.
    static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        return AudioObjectHasProperty(obj, &a)
    }

    static func settable(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        var s: DarwinBoolean = false
        return AudioObjectHasProperty(obj, &a) && AudioObjectIsPropertySettable(obj, &a, &s) == noErr && s.boolValue
    }

    static func read<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, as _: T.Type) -> T? {
        var a = a
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, p) == noErr else { return nil }
        return p.load(as: T.self)
    }

    static func readIDs(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var a = a
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func readString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var s: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr, let s else { return nil }
        return s.takeRetainedValue() as String
    }

    static func write<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: T, _ what: String) throws -> Void {
        var a = a
        var v = value
        let st = AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
        if st != noErr { throw CAError(status: st, what: what) }
    }

    static func check(_ st: OSStatus, _ what: String) throws {
        if st != noErr { throw CAError(status: st, what: what) }
    }

    /// UID → AudioDeviceID (kAudioHardwarePropertyTranslateUIDToDevice).
    static func device(forUID uid: String) -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// PID → objet processus Core Audio (kAudioHardwarePropertyTranslatePIDToProcessObject).
    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &id)
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Nombre de canaux par flux dans une portée (via les formats virtuels des flux).
    static func streamChannels(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int] {
        readIDs(device, address(kAudioDevicePropertyStreams, scope)).map {
            Int(read($0, address(kAudioStreamPropertyVirtualFormat), as: AudioStreamBasicDescription.self)?.mChannelsPerFrame ?? 0)
        }
    }
}

/// Écouteur de propriété retiré automatiquement à la libération.
final class CAListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private(set) var installed = false

    init(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, queue: DispatchQueue = .main, _ handler: @escaping () -> Void) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        installed = AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block) == noErr
    }
    private let queue: DispatchQueue

    deinit {
        if installed { AudioObjectRemovePropertyListenerBlock(object, &address, queue, block) }
    }
}
