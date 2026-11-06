import Foundation

/// AirPods 麦模式下的按柄检测.
///
/// AirPods 开麦 (蓝牙通话模式) 后, 按柄不再发媒体键, 而是发 "静音" 控制命令. 系统本该把它交给
/// 注册了 AVAudioApplication 静音回调的 App, 但在 macOS 27 上这一步对第三方 App 基本都被拒
/// (audioaccessoryd 日志: toggleInputMute 失败 -> "Cannot Control Mic with AirPods").
/// 不过 bluetoothd 每次都会先写一条日志 "Received Software Mute (control cmd 0x27)",
/// 所以这里用 `log stream` 盯着这条日志, 当作 "按柄" 信号. 思路来自 github.com/vinimlo/meetpods
///
/// 顺带把系统处理静音手势的几条日志转进我们的日志, 方便排查官方 API 为什么被拒.
final class StemLogWatcher {
    /// 主线程回调
    var onPress: (() -> Void)?

    static let pressText = "Received Software Mute"
    private static let predicate = """
        (process == "bluetoothd" AND eventMessage CONTAINS "\(pressText)") \
        OR (process == "audioaccessoryd" AND eventMessage CONTAINS "Mute Control") \
        OR (process == "audiomxd" AND eventMessage CONTAINS[c] "mute")
        """

    private var process: Process?
    private var wanted = false
    private var backoff: Double = 1
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    var running: Bool { process != nil }

    func start() {
        wanted = true
        guard process == nil else { return }
        spawn()
    }

    func stop() {
        wanted = false
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        p.terminate()
        log("按柄监听: 已停止")
    }

    private func spawn() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--info", "--predicate", Self.predicate]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var pending = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            pending.append(d)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<nl])
                pending.removeSubrange(pending.startIndex...nl)
                self?.handle(line)
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.exited(p) }
        }
        do {
            try p.run()
            process = p
            log("按柄监听: 已启动 (log stream pid \(p.processIdentifier))")
        } catch {
            log("按柄监听: 启动失败 \(error)")
            scheduleRestart()
        }
    }

    /// 后台线程 (不是 private: 方便离线测试喂假数据)
    func handle(_ line: Data) {
        // 第一行 "Filtering the log data using ..." 不是 JSON, 而且里面也含 pressText, 必须跳过
        guard line.first == UInt8(ascii: "{"),
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let msg = obj["eventMessage"] as? String else { return }
        let proc = ((obj["processImagePath"] as? String) ?? "?").split(separator: "/").last.map(String.init) ?? "?"
        guard proc == "bluetoothd", msg.contains(Self.pressText) else {
            log("系统[\(proc)]: \(msg.replacingOccurrences(of: "\n", with: " ").prefix(220))")
            return
        }
        var delay = ""
        if let ts = obj["timestamp"] as? String, let t = Self.timeFormat.date(from: ts) {
            delay = String(format: " (延迟 %.0fms)", Date().timeIntervalSince(t) * 1000)
        }
        DispatchQueue.main.async {
            self.backoff = 1
            log("按柄(系统日志)\(delay)")
            self.onPress?()
        }
    }

    private func exited(_ p: Process) {
        guard process === p else { return }
        process = nil
        log("按柄监听: log stream 退出 (status \(p.terminationStatus))")
        if wanted { scheduleRestart() }
    }

    private func scheduleRestart() {
        let wait = backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.wanted, self.process == nil else { return }
            self.spawn()
        }
    }
}
