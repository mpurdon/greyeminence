import CoreAudio
import Foundation

/// Read-only Core Audio device facts, callable from any isolation. The
/// property reads are synchronous mach round-trips to coreaudiod, so keep
/// callers off the main thread where they can be (the detector's poll
/// already is).
enum AudioDeviceInfo {

    nonisolated static func name(of device: AudioObjectID) -> String? {
        string(of: device, selector: kAudioObjectPropertyName)
    }

    nonisolated static func uid(of device: AudioObjectID) -> String? {
        string(of: device, selector: kAudioDevicePropertyDeviceUID)
    }

    nonisolated static func transportType(of device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    nonisolated static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// A microphone worth recording from: has input streams and is real
    /// hardware. Virtual devices (Teams' and Discord's own loopbacks) and
    /// aggregates are excluded — pointing the recorder at one of those
    /// records silence with no error.
    nonisolated static func isRecordableInput(_ device: AudioObjectID) -> Bool {
        guard hasInputStreams(device), let transport = transportType(of: device) else { return false }
        return transport != kAudioDeviceTransportTypeVirtual
            && transport != kAudioDeviceTransportTypeAggregate
    }

    nonisolated private static func string(of device: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
