import AppKit
import ApplicationServices
import CoreAudio

// MARK: - 日志 (写到 .app 旁边的 quickvoice.log)

let logURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("quickvoice.log")
private let logQueue = DispatchQueue(label: "log")
private let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func log(_ s: String) {
    let line = "[\(timeFmt.string(from: Date()))] \(s)\n"
    logQueue.async {
        print(line, terminator: "")
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - CoreAudio: 找 AirPods 麦克风

private func addr(_ sel: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func audioDevices() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var a = addr(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name)
    return (name?.takeRetainedValue() as String?) ?? "?"
}

func inputChannels(_ id: AudioDeviceID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, buf) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func builtInInput() -> AudioDeviceID? {
    audioDevices().first { id in
        var a = addr(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
        return t == kAudioDeviceTransportTypeBuiltIn && inputChannels(id) > 0
    }
}

func defaultOutputIsBluetooth() -> Bool {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return false }
    var t = addr(kAudioDevicePropertyTransportType)
    var transport: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(dev, &t, 0, nil, &size, &transport)
    return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
}

func airPodsInput() -> AudioDeviceID? {
    audioDevices().first { deviceName($0).localizedCaseInsensitiveContains("AirPods") && inputChannels($0) > 0 }
}

// MARK: - 键盘模拟 (需要辅助功能权限)

@discardableResult
func accessibilityTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

func pressKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }
}

enum Key {
    static let v: CGKeyCode = 9
    static let enter: CGKeyCode = 36
}

/// 把文字粘贴到当前光标处, 1 秒后恢复原剪贴板内容
func pasteText(_ text: String) {
    let pb = NSPasteboard.general
    let old = pb.string(forType: .string)
    pb.clearContents()
    pb.setString(text, forType: .string)
    pressKey(Key.v, flags: .maskCommand)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        guard pb.string(forType: .string) == text else { return }  // 用户期间又复制了别的, 就不动
        pb.clearContents()
        if let old { pb.setString(old, forType: .string) }
    }
}

func playSound(_ name: String) {
    NSSound(named: NSSound.Name(name))?.play()
}
