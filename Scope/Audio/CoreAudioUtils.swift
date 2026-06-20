//
//  CoreAudioUtils.swift
//  Thin, typed wrappers over the AudioObjectGetPropertyData C API so the rest
//  of the audio layer reads almost like normal Swift.
//

import CoreAudio
import Foundation

enum CAError: LocalizedError {
    case osStatus(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case let .osStatus(status, what):
            return "\(what) failed (OSStatus \(status) '\(fourCC(status))')"
        }
    }
}

/// Render an OSStatus as its four-char-code when printable (Core Audio errors
/// are usually FourCCs like 'who?' or '!obj').
func fourCC(_ value: OSStatus) -> String {
    let bytes = [UInt8((value >> 24) & 0xff),
                 UInt8((value >> 16) & 0xff),
                 UInt8((value >> 8) & 0xff),
                 UInt8(value & 0xff)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
        return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
    }
    return "\(value)"
}

@inline(__always)
func caCheck(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CAError.osStatus(status, what) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope,
                         _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func has(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var addr = address(selector, scope, element)
        return AudioObjectHasProperty(self, &addr)
    }

    /// Read a fixed-size (trivial) property value.
    func read<T>(_ selector: AudioObjectPropertySelector,
                 as type: T.Type,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 qualifier: UnsafeRawPointer? = nil,
                 qualifierSize: UInt32 = 0) throws -> T {
        var addr = address(selector, scope, element)
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                        alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        try caCheck(AudioObjectGetPropertyData(self, &addr, qualifierSize, qualifier, &size, storage),
                    "read \(fourCC(OSStatus(bitPattern: selector)))")
        return storage.load(as: T.self)
    }

    /// Read a variable-length array property (e.g. the process object list).
    func readArray<T>(_ selector: AudioObjectPropertySelector,
                      as type: T.Type,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> [T] {
        var addr = address(selector, scope, element)
        var size: UInt32 = 0
        try caCheck(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size),
                    "size \(fourCC(OSStatus(bitPattern: selector)))")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        var ioSize = size
        try caCheck(AudioObjectGetPropertyData(self, &addr, 0, nil, &ioSize, buffer.baseAddress!),
                    "data \(fourCC(OSStatus(bitPattern: selector)))")
        return Array(buffer)
    }

    /// Read a CFString property (UID, bundle id, …) as a Swift String.
    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> String {
        var addr = address(selector, scope, element)
        // Core Audio hands back a +1-retained CFString; take ownership via Unmanaged.
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try caCheck(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value),
                    "readString \(fourCC(OSStatus(bitPattern: selector)))")
        return (value?.takeRetainedValue() as String?) ?? ""
    }
}

/// UID of the current default output device — used as the aggregate's main
/// sub-device so the tap follows wherever the user is actually listening.
func defaultOutputDeviceUID() throws -> String {
    let deviceID: AudioDeviceID = try AudioObjectID.system.read(
        kAudioHardwarePropertyDefaultOutputDevice, as: AudioDeviceID.self)
    return try deviceID.readString(kAudioDevicePropertyDeviceUID)
}
