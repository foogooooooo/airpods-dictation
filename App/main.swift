// 快捷录音: 用 AirPods 按柄做 vibecoding 的语音输入
//   空闲时  单捏 = 开始录音   双捏 = 发送 (回车)   三捏 = 暂未绑定
//   录音中  单捏 = 结束录音 -> 本地转文字 (Whisper / Apple) -> 粘贴到光标处
//
// 两种麦克风:
//   Mac 内置麦 (默认): AirPods 只当遥控器, 一直是普通媒体键, 按柄开始/结束都可用
//   AirPods 麦       : 开麦后 AirPods 切通话模式, 按柄变成系统 "静音手势", macOS 27 不交给我们.
//                      改为监听 bluetoothd 的系统日志来发现按柄 (StemLog.swift);
//                      "停顿 2.5 秒自动结束" 作兜底; 提示音只能在开麦前播

import AppKit
import AVFoundation
import MediaPlayer
import ServiceManagement

enum State: String { case idle = "空闲", recording = "录音中", transcribing = "识别中" }
enum EngineChoice: String { case whisper, apple }

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var stateMenuItem: NSMenuItem!
    private var micItems: [MicSource: NSMenuItem] = [:]
    private var engineItems: [EngineChoice: NSMenuItem] = [:]
    private var autoStopItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private let keeper = NowPlayingKeeper()
    private let recorder = Recorder()
    private let apple = Transcriber()
    private let whisper = WhisperServer()
    private let playback = MPNowPlayingInfoCenter.default()
    private var lastSingleAt = Date.distantPast
    private var muteRegistered = false
    private let stemLog = StemLogWatcher()
    /// 上次录音结束的时间: 结束后 AirPods 还会在通话模式停留几秒, 这时的按柄也走系统日志
    private var lastStopAt = Date.distantPast
    /// 单段录音上限: 忘了结束 (或者按柄检测失效) 时不会一直录下去
    private let maxRecordingSeconds: Double = 300
    private var maxLengthTimer: Timer?

    // MARK: 设置 (UserDefaults)

    private var mic: MicSource {
        get { MicSource(rawValue: UserDefaults.standard.string(forKey: "mic") ?? "") ?? .mac }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mic"); applySettings() }
    }
    private var engine: EngineChoice {
        get { EngineChoice(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .whisper }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "engine"); applySettings() }
    }
    /// 停顿自动结束: 只在 AirPods 麦模式可选, 默认关. 按柄已经能结束; 自动结束没有提示音
    /// (通话模式下 App 的声音听不到), 还会在想事情停顿时把话打断
    private var autoStop: Bool {
        get { UserDefaults.standard.object(forKey: "autoStop") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "autoStop"); applySettings() }
    }

    private var state: State = .idle {
        didSet {
            log("状态: \(oldValue.rawValue) -> \(state.rawValue)")
            refreshIcon()
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        log("=== 快捷录音启动 ===")
        setupStatusItem()
        keeper.start()
        setupRemoteCommands()
        recorder.onInputConfigured = { [weak self] in
            guard self?.mic == .airpods else { return }
            self?.registerMuteGestureOnce()
        }
        stemLog.onPress = { [weak self] in self?.stemPressFromLog() }
        recorder.onSilence = { [weak self] in
            guard self?.state == .recording else { return }
            self?.stopRecording()
        }
        applySettings()
        AVCaptureDevice.requestAccess(for: .audio) { ok in log("麦克风权限: \(ok ? "已允许" : "被拒绝")") }
        log("辅助功能权限: \(accessibilityTrusted(prompt: true) ? "已允许" : "未允许 (粘贴/回车不会生效)")")
        setupLoginItemOnFirstRun()
        Task { await apple.prepare() }
        Task { await whisper.start() }
    }

    func applicationWillTerminate(_ n: Notification) {
        stemLog.stop()
        whisper.stop()
    }

    private func applySettings() {
        recorder.source = mic
        recorder.silenceTimeout = (mic == .airpods && autoStop) ? 2.5 : nil
        if mic == .airpods { stemLog.start() } else { stemLog.stop() }
        guard statusItem != nil else { return }
        for (k, item) in micItems { item.state = k == mic ? .on : .off }
        for (k, item) in engineItems { item.state = k == engine ? .on : .off }
        autoStopItem.state = autoStop ? .on : .off
        autoStopItem.isEnabled = mic == .airpods
        log("设置: 麦克风=\(mic.rawValue) 引擎=\(engine.rawValue) 自动结束=\(recorder.silenceTimeout != nil)")
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        stateMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        menu.addItem(.separator())
        menu.addItem(item("开始 / 结束录音 (单捏)", #selector(menuToggle)))
        menu.addItem(item("发送回车 (双捏)", #selector(menuSend)))

        menu.addItem(.separator())
        menu.addItem(header("麦克风"))
        micItems[.mac] = item("Mac 内置麦 (音质好, 要在 Mac 旁边)", #selector(pickMacMic))
        micItems[.airpods] = item("AirPods 麦 (可以离开 Mac 走动着说)", #selector(pickAirPodsMic))
        micItems.values.sorted { $0.title < $1.title }.forEach(menu.addItem)
        autoStopItem = item("    停顿 2.5 秒自动结束", #selector(toggleAutoStop))
        menu.addItem(autoStopItem)

        menu.addItem(.separator())
        menu.addItem(header("识别引擎"))
        engineItems[.whisper] = item("Whisper large-v3-turbo (本地)", #selector(pickWhisper))
        engineItems[.apple] = item("Apple 系统识别 (本地)", #selector(pickApple))
        menu.addItem(engineItems[.whisper]!)
        menu.addItem(engineItems[.apple]!)

        menu.addItem(.separator())
        loginItem = item("开机自启", #selector(toggleLoginItem))
        menu.addItem(loginItem)
        menu.addItem(item("打开日志", #selector(openLog)))
        menu.addItem(item("辅助功能权限设置…", #selector(openAXSettings)))
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        refreshIcon()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func header(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func refreshIcon() {
        let preparing = state == .recording && !recorder.isReady
        let (symbol, tint): (String, NSColor?) = switch state {
        case .idle: ("mic", nil)
        case .recording: ("mic.fill", preparing ? .systemYellow : .systemRed)
        case .transcribing: ("waveform", .systemOrange)
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.rawValue)
        statusItem.button?.contentTintColor = tint
        stateMenuItem.title = "状态: \(preparing ? "准备中 (等麦克风打开)" : state.rawValue)"
    }

    @objc private func menuToggle() { singlePress(source: "菜单") }
    @objc private func menuSend() { doublePress(source: "菜单") }
    @objc private func pickMacMic() { mic = .mac }
    @objc private func pickAirPodsMic() { mic = .airpods }
    @objc private func pickWhisper() { engine = .whisper }
    @objc private func pickApple() { engine = .apple }
    @objc private func toggleAutoStop() { autoStop.toggle() }
    // MARK: 开机自启

    /// 第一次运行默认打开开机自启, 之后以用户在菜单里的选择为准
    private func setupLoginItemOnFirstRun() {
        if !UserDefaults.standard.bool(forKey: "loginItemSetupDone") {
            UserDefaults.standard.set(true, forKey: "loginItemSetupDone")
            setLoginItem(true)
        }
        refreshLoginItem()
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log("开机自启: \(on ? "已开启" : "已关闭")")
        } catch {
            log("开机自启设置失败: \(error)")
        }
    }

    private func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : .off
        if status == .requiresApproval { loginItem.title = "开机自启 (需在系统设置 → 登录项里允许)" }
    }

    @objc private func toggleLoginItem() {
        setLoginItem(SMAppService.mainApp.status != .enabled)
        refreshLoginItem()
    }

    @objc private func openLog() { NSWorkspace.shared.open(logURL) }
    @objc private func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: AirPods 事件

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ name: String, _ action: @escaping () -> Void) {
            cmd.isEnabled = true
            cmd.addTarget { _ in
                log("AirPods: \(name)")
                action()
                return .success
            }
        }
        // AirPods 单捏发的是 play / pause 交替, 都当成单捏
        on(cc.togglePlayPauseCommand, "togglePlayPause") { self.remoteSingle() }
        on(cc.playCommand, "play") { self.playback.playbackState = .playing; self.remoteSingle() }
        on(cc.pauseCommand, "pause") { self.playback.playbackState = .paused; self.remoteSingle() }
        on(cc.nextTrackCommand, "nextTrack") { self.doublePress(source: "双捏") }
        on(cc.previousTrackCommand, "previousTrack") { log("三捏: 暂未绑定") }
    }

    /// 媒体键的单捏. 摘下耳机 / 耳机断开时系统也会发一个 "暂停", 和单捏一模一样;
    /// 能区分的线索是此时输出已经不在蓝牙耳机上了, 所以空闲时遇到这种情况不开始录音.
    /// (录音中照常结束: 耳机都摘了, 结束并转写是合理的)
    private func remoteSingle() {
        if state == .idle && !defaultOutputIsBluetooth() {
            log("单捏 忽略: 输出不在蓝牙耳机上, 多半是摘下耳机或断开")
            return
        }
        singlePress(source: "单捏")
    }

    /// AirPods 麦模式下按柄 (通话模式的 "静音" 命令), 来自 bluetoothd 系统日志
    private func stemPressFromLog() {
        switch state {
        case .recording:
            singlePress(source: "按柄(系统日志)")
        case .idle where Date().timeIntervalSince(lastStopAt) < 10:
            // 刚录完, AirPods 还停在通话模式, 这时按柄也当单捏 (开始下一段)
            singlePress(source: "按柄(系统日志, 录完不久)")
        default:
            // 别的 App (会议等) 在用 AirPods 麦时的按柄, 不归我们
            log("按柄(系统日志) 忽略, 当前: \(state.rawValue)")
        }
    }

    /// 官方静音手势 API. macOS 27 上系统基本都会拒绝交给我们, 按柄改由系统日志检测.
    /// 这里只记录, 不触发动作: 开麦时系统也会同步调用一次 (取消静音), 当成按柄会误结束.
    /// 返回 true 是为了万一系统接受了, 能少弹一次 "Cannot Control Mic".
    private func registerMuteGestureOnce() {
        guard !muteRegistered else { return }
        muteRegistered = true
        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { muted in
                log("官方静音手势回调: \(muted ? "静音" : "取消静音") (只记录)")
                if muted {
                    // 系统接受时会记一个静音状态, 每按一次切一次, 提示音和横幅也跟着交替 (听着像开了又关).
                    // 每次被切成静音就改回来, 让每次按柄听到的系统提示音都一样.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        do { try AVAudioApplication.shared.setInputMuted(false); log("官方静音状态: 已复位为取消静音") }
                        catch { log("官方静音状态复位失败: \(error)") }
                    }
                }
                return true
            }
            NotificationCenter.default.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification,
                                                   object: nil, queue: .main) { n in
                log("官方静音状态通知: \(n.userInfo ?? [:])")
            }
        } catch {
            log("注册静音手势失败: \(error)")
        }
    }

    // MARK: 动作

    private func singlePress(source: String) {
        // 一次单捏有时会同时发两个事件, 1 秒内去重
        if Date().timeIntervalSince(lastSingleAt) < 1.0 {
            log("单捏 [\(source)] 1 秒内重复, 忽略")
            return
        }
        lastSingleAt = Date()
        log("单捏 [\(source)] 当前: \(state.rawValue)")
        switch state {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .transcribing: log("识别中, 忽略")
        }
    }

    private func doublePress(source: String) {
        log("双捏 [\(source)] 当前: \(state.rawValue)")
        guard state == .idle else { log("非空闲, 忽略发送"); return }
        pressKey(Key.enter)
        keeper.cue(.send)
    }

    private func startRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            log("没有麦克风权限")
            keeper.cue(.error)
            return
        }
        let airpods = mic == .airpods
        recorder.onReady = { [weak self] in
            guard let self, self.state == .recording else { return }
            log("录音就绪, 可以说话了")
            self.refreshIcon()  // 图标从 "准备中" (黄) 变成 "录音中" (红)
            // Mac 麦: 麦克风开好再响. AirPods 麦不响: 通话模式下 App 放的声音听不到 (2026-11-06 实测),
            // 开麦前响又经常被蓝牙切换截掉; 看菜单栏图标变红 (或等 2 到 3 秒) 再说话
            if !airpods { self.keeper.cue(.ready) }
        }
        state = .recording
        maxLengthTimer?.invalidate()
        maxLengthTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingSeconds, repeats: false) { [weak self] _ in
            guard let self, self.state == .recording else { return }
            log(String(format: "录音满 %.0f 分钟, 自动结束", self.maxRecordingSeconds / 60))
            self.stopRecording()
        }
        beginRecorder()
    }

    private func beginRecorder() {
        guard state == .recording else { return }
        do {
            try recorder.start()
        } catch {
            log("录音失败: \(error)")
            _ = recorder.stop()
            keeper.cue(.error)
            state = .idle
        }
    }

    private func stopRecording() {
        let heard = recorder.heardSpeech
        let result = recorder.stop()
        maxLengthTimer?.invalidate()
        maxLengthTimer = nil
        lastStopAt = Date()
        keeper.claim()
        guard let (url, seconds) = result else { state = .idle; return }
        log(String(format: "录音结束, %.1f 秒", seconds))
        keeper.cue(.stop)
        // 只丢弃 "5 秒内且没检测到说话" 的录音; 长录音即使电平低也送去识别, 宁可多识别不丢话
        guard seconds > 0.3, heard || seconds >= 5 else {
            // 没说话就别送去识别, 否则识别器会凭空编出 "you" / "谢谢观看" 之类
            log(heard ? "太短, 丢弃" : "没检测到说话, 丢弃")
            try? FileManager.default.removeItem(at: url)
            state = .idle
            return
        }
        state = .transcribing
        let useWhisper = engine == .whisper && whisper.ready
        if engine == .whisper && !whisper.ready { log("Whisper 没就绪, 这次用 Apple 识别") }
        Task {
            let started = Date()
            var raw = ""
            do {
                raw = useWhisper ? try await whisper.transcribe(url) : try await apple.transcribe(url)
            } catch {
                log("识别失败 (\(useWhisper ? "Whisper" : "Apple")): \(error)")
            }
            let cost = Date().timeIntervalSince(started)
            let text = raw
            await MainActor.run {
                log(String(format: "识别结果 [%@ %.2fs]: %@", useWhisper ? "Whisper" : "Apple", cost, text))
                if text.isEmpty {
                    self.keeper.cue(.error)
                } else {
                    pasteText(text)
                }
                self.state = .idle
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
