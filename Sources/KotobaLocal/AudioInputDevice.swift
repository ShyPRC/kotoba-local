import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID

    static func available() throws -> [AudioInputDevice] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            throw AppFailure.message("无法读取录音设备列表，请检查系统声音设置后刷新。")
        }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !deviceIDs.isEmpty else { return [] }
        let result = deviceIDs.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else {
            throw AppFailure.message("录音设备列表发生变化，请刷新后重试。")
        }
        return deviceIDs.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).compactMap { deviceID in
            var streams = propertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var streamSize: UInt32 = 0
            var alive = propertyAddress(kAudioDevicePropertyDeviceIsAlive)
            var isAlive: UInt32 = 0
            var aliveSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyDataSize(deviceID, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  AudioObjectGetPropertyData(deviceID, &alive, 0, nil, &aliveSize, &isAlive) == noErr, isAlive == 1,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID),
                  let name = stringProperty(kAudioObjectPropertyName, deviceID: deviceID) else { return nil }
            return AudioInputDevice(id: uid, name: name, deviceID: deviceID)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultDeviceID() -> AudioDeviceID {
        var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        return deviceID
    }

    static func propertyAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
