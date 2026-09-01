import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    /// The CoreAudio device UID — stable across reboots and reconnects, unlike the
    /// numeric AudioDeviceID, so this is what gets stored in preferences.
    let id: String
    let name: String
}

/// Enumerating devices via CoreAudio, so a specific microphone can be picked instead of
/// whatever macOS currently calls the default — and so the process tap can be anchored to
/// a concrete output device rather than "the default one".
enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs()
            .filter { channelCount($0, scope: kAudioObjectPropertyScopeInput) > 0 }
            .compactMap { id in
                guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                      let name = string(id, kAudioObjectPropertyName)
                else { return nil }
                return AudioInputDevice(id: uid, name: name)
            }
    }

    /// Every device that can play audio, for anchoring a tap's aggregate device.
    ///
    /// Returns the numeric id alongside the UID so the caller can ask about transport type
    /// without going back through `deviceID(forUID:)`, which re-enumerates every device in
    /// the system for each lookup.
    static func outputDevices() -> [(id: AudioDeviceID, uid: String)] {
        allDeviceIDs()
            .filter { channelCount($0, scope: kAudioObjectPropertyScopeOutput) > 0 }
            .compactMap { id in
                string(id, kAudioDevicePropertyDeviceUID).map { (id, $0) }
            }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static var defaultInputDeviceID: AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    static var defaultOutputDeviceID: AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = propertyAddress(selector)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static func name(forDeviceID id: AudioDeviceID) -> String? {
        string(id, kAudioObjectPropertyName)
    }

    static func uid(forDeviceID id: AudioDeviceID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    /// Whether a device is a Bluetooth headset.
    ///
    /// Worth knowing before recording from one: a Bluetooth headset cannot carry
    /// high-quality playback and a microphone at the same time. Opening its mic switches
    /// the whole device from A2DP to HFP, and whatever you were listening to collapses
    /// from stereo at 44.1 kHz to mono at 16 kHz until the recording stops.
    ///
    /// This matters far more here than in a dictation app. A dictation is fifteen
    /// seconds; a meeting is an hour, and the other people's voices are *the recording* —
    /// so a headset flipped into HFP degrades the thing you are trying to capture for the
    /// entire call, not just what you happen to be listening to.
    static func isBluetooth(deviceID id: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func isBluetooth(uid: String) -> Bool {
        guard let id = deviceID(forUID: uid) else { return false }
        return isBluetooth(deviceID: id)
    }

    /// True when "System Default" would open a Bluetooth microphone.
    static var defaultInputIsBluetooth: Bool {
        guard let id = defaultInputDeviceID else { return false }
        return isBluetooth(deviceID: id)
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let lists = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(lists).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Property plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        let text = value as String
        return text.isEmpty ? nil : text
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
