import AppKit
import AVFoundation
import MediaPlayer

/// 持续播放静音 + 声明 Now Playing, 让 AirPods 的单捏/双捏/三捏发给我们.
/// 录音期间也必须保持运行: 停掉的话系统认为没人接按键, 单捏会弹 "Cannot Control Mic".
/// 提示音也从这个引擎播放, 保证和当前蓝牙通道一致 (不依赖系统音效设置).
///
/// 副作用: 只要在播 (哪怕是静音), coreaudiod 就会阻止 Mac 空闲睡眠. 所以只在
/// "默认输出是蓝牙耳机 且 屏幕没睡" 时播放, 其余时间停掉.
enum Cue { case ready, stop, send, error }

final class NowPlayingKeeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var lastCue: (AVAudioPCMBuffer, Date)?

    private var wanted = false      // 条件满足: 蓝牙输出 + 屏幕亮
    private var displayAsleep = false

    func start() {
        let src = AVAudioSourceNode { _, _, _, abl in
            for b in UnsafeMutableAudioBufferListPointer(abl) {
                if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(src)
        engine.attach(player)
        engine.connect(src, to: engine.mainMixerNode, format: nil)
        engine.connect(player, to: engine.mainMixerNode, format: toneFormat)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            log("静音输出: 音频配置变化")
            self.evaluate(force: true)
        }
        // 默认输出设备变化 (连上/断开 AirPods)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            self?.evaluate(force: true)
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displayAsleep = true
            self?.evaluate()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displayAsleep = false
            self?.evaluate()
        }
        evaluate(force: true)
        claim()
    }

    /// 根据条件开/关静音输出
    private func evaluate(force: Bool = false) {
        let should = !displayAsleep && defaultOutputIsBluetooth()
        guard force || should != wanted else { return }
        if should != wanted || !engine.isRunning == should {
            log("静音输出: \(should ? "开启 (蓝牙耳机输出)" : "关闭 (非蓝牙输出或屏幕睡眠, 允许 Mac 睡眠)")")
        }
        wanted = should
        if should { restart(); claim() } else { engine.stop() }
    }

    private func restart() {
        engine.stop()
        do { try engine.start() } catch { log("静音输出启动失败: \(error)"); return }
        // 蓝牙切换导致的重启会吞掉刚排队的提示音, 补播一次
        if let (buf, at) = lastCue, Date().timeIntervalSince(at) < 1.0 {
            lastCue = nil
            player.scheduleBuffer(buf, at: nil, options: [])
            player.play()
        }
    }

    /// 重新声明自己是正在播放的 App
    func claim() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "快捷录音",
            MPMediaItemPropertyArtist: "单捏录音 · 双捏发送",
            MPMediaItemPropertyPlaybackDuration: 3600.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        center.playbackState = .playing
    }

    func cue(_ c: Cue) {
        // (频率 Hz, 时长 s) 序列
        let notes: [(Double, Double)] = switch c {
        case .ready: [(880, 0.07), (0, 0.03), (1320, 0.09)]   // 升调: 可以说话了
        case .stop: [(1320, 0.07), (0, 0.03), (880, 0.09)]    // 降调: 录完了
        case .send: [(1047, 0.06)]                           // 短促一声: 已发送
        case .error: [(220, 0.25)]                           // 低音: 出错
        }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        let buf = tone(notes)
        lastCue = (buf, Date())
        player.scheduleBuffer(buf, at: nil, options: [])
        player.play()
    }

    private func tone(_ notes: [(Double, Double)]) -> AVAudioPCMBuffer {
        let sr = toneFormat.sampleRate
        let total = notes.reduce(0) { $0 + Int($1.1 * sr) }
        let buf = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        let p = buf.floatChannelData![0]
        var i = 0
        for (freq, dur) in notes {
            let n = Int(dur * sr)
            for k in 0..<n {
                let env = min(1, Double(k) / 200, Double(n - k) / 200)  // 淡入淡出, 防爆音
                p[i] = freq == 0 ? 0 : Float(sin(2 * .pi * freq * Double(k) / sr) * 0.35 * env)
                i += 1
            }
        }
        return buf
    }
}

enum MicSource: String { case mac, airpods }

/// 录音: Mac 内置麦或 AirPods 麦, 统一转成 16kHz 单声道 16bit WAV
final class Recorder {
    var source: MicSource = .mac
    /// 真正开始收到声音 (蓝牙已切到通话模式并稳定) 时回调, 主线程
    var onReady: (() -> Void)?
    /// 录音设备设置好、引擎启动前回调 (AirPods 麦模式在这里注册静音手势)
    var onInputConfigured: (() -> Void)?
    /// 说过话之后安静了 silenceTimeout 秒 (nil = 关闭自动结束)
    var onSilence: (() -> Void)?
    var silenceTimeout: Double? = 2.5

    private var engine: AVAudioEngine?
    /// 录音块 (16kHz, 每块约 40ms) + 该块是否在说话; 停止时裁剪长静音再写 WAV
    private var chunks: [(samples: [Float], voiced: Bool)] = []
    private var observer: NSObjectProtocol?
    private var watchdog: Timer?
    private(set) var url: URL?
    private(set) var isReady = false
    var heardSpeech: Bool {
        lock.lock(); defer { lock.unlock() }
        return heardSpeech_
    }
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                       channels: 1, interleaved: false)!

    // 诊断计数 (lock 保护)
    private var callbacks = 0
    private var convertErrors = 0
    private var lastBufferAt = Date.distantPast
    private var tapInstalledAt = Date.distantPast
    private var restarts = 0
    // 语音活动检测 (VAD)
    private var noiseFloor: Float = 0.002
    private var heardSpeech_ = false
    private var lastVoiceAt = Date.distantPast
    private var startedAt = Date.distantPast

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickvoice-\(Int(Date().timeIntervalSince1970)).wav")
        self.url = url
        lock.lock()
        chunks = []
        callbacks = 0; convertErrors = 0; restarts = 0
        noiseFloor = 0.002; heardSpeech_ = false; lastVoiceAt = .distantPast; startedAt = Date()
        lastBufferAt = Date()
        lock.unlock()
        isReady = false

        buildEngineAndStart()

        // 看门狗: 超过 1 秒没收到声音就重建录音引擎
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.engine != nil else { return }
            self.lock.lock()
            let silentFor = Date().timeIntervalSince(self.lastBufferAt)
            let sinceInstall = Date().timeIntervalSince(self.tapInstalledAt)
            self.lock.unlock()
            self.lock.lock()
            let heard = self.heardSpeech_
            let quietFor = Date().timeIntervalSince(self.lastVoiceAt)
            self.lock.unlock()
            if let timeout = self.silenceTimeout, heard, quietFor > timeout, self.isReady {
                log(String(format: "停顿 %.1fs, 自动结束", quietFor))
                self.onSilence?()
                return
            }
            if sinceInstall > 1.5 && silentFor > 1.0 {
                self.restarts += 1
                log("录音: \(String(format: "%.1f", silentFor))s 没收到声音, 重建引擎 (第 \(self.restarts) 次)")
                self.teardownEngine()
                self.buildEngineAndStart()
            }
        }
    }

    private func buildEngineAndStart() {
        let engine = AVAudioEngine()
        let wanted = source == .airpods ? airPodsInput() : builtInInput()
        if let dev0 = wanted, let au = engine.inputNode.audioUnit {
            var dev = dev0
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            log("录音设备: \(deviceName(dev0))")
        } else {
            log("没找到 \(source == .airpods ? "AirPods" : "内置") 麦克风, 用系统默认输入")
        }
        onInputConfigured?()
        self.engine = engine
        // AirPods 开麦会切到通话模式 (48k -> 24k), 引擎会发配置变化, 要重装 tap
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            log("录音: 音频配置变化, 重装 tap")
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.installTapAndStart(engine)
        }
        installTapAndStart(engine)
    }

    /// 停掉的引擎先留 3 秒再释放: 系统的 IO 属性回调可能还在队列里, 立刻释放会访问野指针崩溃
    /// (2026-11-06 录音中看门狗重建引擎时崩过一次, 栈在 AVAudioIOUnit::IOUnitPropertyListener)
    private var retired: [AVAudioEngine] = []

    private func teardownEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let old = engine else { return }
        engine = nil
        old.inputNode.removeTap(onBus: 0)
        old.stop()
        retired.append(old)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.retired.removeAll { $0 === old }
        }
    }

    private func installTapAndStart(_ engine: AVAudioEngine, retry: Int = 0) {
        let input = engine.inputNode
        let hw = input.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0,
              let converter = AVAudioConverter(from: hw, to: target) else {
            if retry < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.engine === engine else { return }
                    self.installTapAndStart(engine, retry: retry + 1)
                }
            } else {
                log("录音: 输入格式无效 \(hw)")
            }
            return
        }
        log("录音格式: \(Int(hw.sampleRate))Hz \(hw.channelCount)ch")
        lock.lock()
        tapInstalledAt = Date()
        lock.unlock()
        let target = self.target
        let installedAt = Date()
        input.installTap(onBus: 0, bufferSize: 2048, format: hw) { [weak self] buf, _ in
            guard let self else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / hw.sampleRate + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            self.lock.lock()
            self.callbacks += 1
            self.lastBufferAt = Date()
            if err != nil { self.convertErrors += 1 }
            if out.frameLength > 0 {
                // VAD: 电平超过 噪声底 x3 (至少 0.004) 算在说话
                let p = out.floatChannelData![0]
                var sum: Float = 0
                for i in 0..<Int(out.frameLength) { sum += p[i] * p[i] }
                let rms = sqrt(sum / Float(out.frameLength))
                let threshold = max(0.004, self.noiseFloor * 3)
                let voiced = rms > threshold
                self.chunks.append((Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength))), voiced))
                if voiced {
                    if !self.heardSpeech_ { log(String(format: "检测到说话 (电平 %.4f, 阈值 %.4f)", rms, threshold)) }
                    self.heardSpeech_ = true
                    self.lastVoiceAt = Date()
                } else {
                    self.noiseFloor = self.noiseFloor * 0.95 + rms * 0.05
                }
            }
            self.lock.unlock()
            // 同一个 tap 稳定出声 0.3 秒以上, 才算蓝牙切换完成
            if Date().timeIntervalSince(installedAt) > 0.3 {
                DispatchQueue.main.async {
                    guard !self.isReady, self.engine === engine else { return }
                    self.isReady = true
                    self.onReady?()
                }
            }
        }
        do { try engine.start() } catch { log("录音启动失败: \(error)") }
    }

    /// 停止录音, 写出 WAV, 返回文件和原始时长 (秒)
    func stop() -> (URL, Double)? {
        watchdog?.invalidate()
        watchdog = nil
        teardownEngine()
        lock.lock()
        let chunks = self.chunks
        let heard = heardSpeech_
        self.chunks = []
        log("录音统计: 回调 \(callbacks) 次, 转换错误 \(convertErrors), 引擎重建 \(restarts) 次")
        lock.unlock()
        isReady = false
        guard let url else { return nil }
        let sr = target.sampleRate
        let total = chunks.reduce(0) { $0 + $1.samples.count }
        // 说过话才裁剪; 没检测到说话 (可能声音太小) 就原样交给识别
        let samples = heard ? Self.trimSilence(chunks, sampleRate: sr) : chunks.flatMap(\.samples)
        log(String(format: "裁剪静音: %.1fs -> %.1fs", Double(total) / sr, Double(samples.count) / sr))
        do {
            try writeWav(samples, to: url)
        } catch {
            log("写录音文件失败: \(error)")
            return nil
        }
        return (url, Double(total) / sr)
    }

    /// Whisper 遇到长静音容易 "脑补" 出 "谢谢大家" "谢谢观看" 之类. 去掉首尾静音,
    /// 中间超过 1.5 秒的停顿压缩到 1 秒. 说话块前后各保留 0.5 秒, 避免切掉轻声的字.
    static func trimSilence(_ chunks: [(samples: [Float], voiced: Bool)], sampleRate sr: Double) -> [Float] {
        guard let first = chunks.firstIndex(where: \.voiced),
              let last = chunks.lastIndex(where: \.voiced) else { return chunks.flatMap(\.samples) }
        let pad = Int(0.5 * sr)
        var out: [Float] = []
        // 开头: 第一个说话块之前最多 0.5 秒
        let lead = chunks[..<first].flatMap(\.samples)
        out += lead.suffix(pad)
        var gap: [Float] = []
        for c in chunks[first...last] {
            if c.voiced {
                if gap.count > 3 * pad {
                    out += gap.prefix(pad)
                    out += gap.suffix(pad)
                } else {
                    out += gap
                }
                gap = []
                out += c.samples
            } else {
                gap += c.samples
            }
        }
        // 结尾: 最后一个说话块之后最多 0.5 秒
        out += chunks[(last + 1)...].flatMap(\.samples).prefix(pad)
        return out
    }

    private func writeWav(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: target.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
    }
}
