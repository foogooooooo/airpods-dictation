// AirPods 按键探针: 只做一件事 —— 记录 AirPods 按柄能给 App 发出哪些事件。
// 两种模式:
//   默认      : 注册成 "正在播放" 的 App, 监听媒体遥控命令 (单捏/双捏/三捏)
//   --mic     : 额外打开 AirPods 麦克风, 监听通话静音手势 (AVAudioApplication)
// 日志写到 build/probe.log

import AppKit
import AVFoundation
import CoreAudio
import MediaPlayer

// MARK: - 日志

let logURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("probe.log")
let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func log(_ s: String) {
    let line = "[\(timeFmt.string(from: Date()))] \(s)\n"
    print(line, terminator: "")
    if let data = line.data(using: .utf8) {
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - CoreAudio 设备工具

func globalAddr(_ sel: AudioObjectPropertySelector,
                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioDeviceID] {
    var addr = globalAddr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = globalAddr(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
    return (name?.takeRetainedValue() as String?) ?? "?"
}

func inputChannels(_ id: AudioDeviceID) -> Int {
    var addr = globalAddr(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

// MARK: - 探针

final class Probe: NSObject, NSApplicationDelegate {
    let micMode = CommandLine.arguments.contains("--mic")
    var statusItem: NSStatusItem!
    let outEngine = AVAudioEngine()
    let inEngine = AVAudioEngine()
    var rmsAccum: Float = 0
    var rmsCount = 0
    var lastRmsLog = Date()

    func applicationDidFinishLaunching(_ n: Notification) {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        log("=== AirPods 探针启动, 模式: \(micMode ? "媒体命令 + 麦克风静音手势" : "仅媒体命令") ===")
        setupStatusItem()
        listDevices()
        startSilentOutput()
        setupRemoteCommands()
        setupMediaKeyMonitor()
        if micMode { setupMic() }
        log("准备好了, 现在去按 AirPods: 单捏 / 双捏 / 三捏 / 长按, 每种间隔几秒")
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = micMode ? "Probe·MIC" : "Probe"
        let menu = NSMenu()
        menu.addItem(withTitle: "退出探针", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func listDevices() {
        for id in allDevices() {
            log("音频设备 #\(id): \(deviceName(id))  输入声道=\(inputChannels(id))")
        }
    }

    // 播放静音音频, 让系统把我们当成 "正在播放" 的 App
    func startSilentOutput() {
        let src = AVAudioSourceNode { _, _, _, abl in
            for b in UnsafeMutableAudioBufferListPointer(abl) {
                if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) }
            }
            return noErr
        }
        outEngine.attach(src)
        outEngine.connect(src, to: outEngine.mainMixerNode, format: nil)
        do {
            try outEngine.start()
            log("静音输出已启动")
        } catch {
            log("静音输出启动失败: \(error)")
        }
    }

    func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        let center = MPNowPlayingInfoCenter.default()

        func reg(_ cmd: MPRemoteCommand, _ name: String, _ after: (() -> Void)? = nil) {
            cmd.isEnabled = true
            cmd.addTarget { _ in
                log(">>> 媒体命令: \(name)")
                after?()
                return .success
            }
        }
        reg(cc.togglePlayPauseCommand, "togglePlayPause") {
            center.playbackState = center.playbackState == .playing ? .paused : .playing
        }
        reg(cc.playCommand, "play") { center.playbackState = .playing }
        reg(cc.pauseCommand, "pause") { center.playbackState = .paused }
        reg(cc.stopCommand, "stop")
        reg(cc.nextTrackCommand, "nextTrack")
        reg(cc.previousTrackCommand, "previousTrack")
        reg(cc.skipForwardCommand, "skipForward")
        reg(cc.skipBackwardCommand, "skipBackward")
        reg(cc.seekForwardCommand, "seekForward")
        reg(cc.seekBackwardCommand, "seekBackward")

        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "AirPods Probe",
            MPMediaItemPropertyArtist: "快捷录音",
            MPMediaItemPropertyPlaybackDuration: 3600.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        center.playbackState = .playing
        log("已注册为 Now Playing App")
    }

    // 兜底: 键盘媒体键 (F7/F8/F9) 走的是 systemDefined 事件, 看看 AirPods 会不会也走这里
    func setupMediaKeyMonitor() {
        let handler: (NSEvent) -> Void = { e in
            guard e.subtype.rawValue == 8 else { return }
            let code = (e.data1 & 0xFFFF0000) >> 16
            let down = ((e.data1 & 0xFF00) >> 8) == 0xA
            if down { log(">>> systemDefined 媒体键 code=\(code)") }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: handler)
        NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { handler($0); return $0 }
    }

    func setupMic() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                log("麦克风权限: \(ok ? "已允许" : "被拒绝")")
                if ok { self.startMic() }
            }
        }
    }

    func startMic() {
        // 优先用 AirPods 做输入
        let input = inEngine.inputNode
        if let air = allDevices().first(where: { deviceName($0).localizedCaseInsensitiveContains("AirPods") && inputChannels($0) > 0 }),
           let au = input.audioUnit {
            var dev = air
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            log("输入设备切到 \(deviceName(air)) (status=\(st))")
        } else {
            log("没找到 AirPods 输入设备, 使用系统默认输入")
        }

        // 静音手势回调 (macOS 14+)
        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { muted in
                log(">>> 静音手势: \(muted ? "静音" : "取消静音")")
                return true
            }
            log("已注册 AVAudioApplication 静音手势回调")
        } catch {
            log("注册静音手势回调失败: \(error)")
        }
        NotificationCenter.default.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification,
                                               object: nil, queue: .main) { n in
            log(">>> 静音状态通知: \(n.userInfo ?? [:])")
        }

        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: inEngine, queue: .main) { [weak self] _ in
            guard let self else { return }
            log("音频配置变化, 重装 tap")
            self.inEngine.stop()
            self.inEngine.inputNode.removeTap(onBus: 0)
            self.installTapAndStart()
        }
        installTapAndStart()
    }

    func installTapAndStart() {
        let input = inEngine.inputNode
        // 用硬件侧格式: AirPods 开麦后会切到通话模式, 采样率会变
        let fmt = input.inputFormat(forBus: 0)
        log("输入格式(硬件): \(fmt)  输出格式: \(input.outputFormat(forBus: 0))")
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            log("输入格式无效, 1 秒后重试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.installTapAndStart() }
            return
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(buf.frameLength, 1)))
            DispatchQueue.main.async {
                self.rmsAccum += rms
                self.rmsCount += 1
                if Date().timeIntervalSince(self.lastRmsLog) > 3 {
                    log("麦克风电平(3s 平均): \(String(format: "%.4f", self.rmsAccum / Float(max(self.rmsCount, 1))))")
                    self.rmsAccum = 0; self.rmsCount = 0; self.lastRmsLog = Date()
                }
            }
        }
        do {
            try inEngine.start()
            log("麦克风已开始采集")
        } catch {
            log("麦克风启动失败: \(error)")
        }
    }
}

let app = NSApplication.shared
let delegate = Probe()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
