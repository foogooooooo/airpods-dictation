import Foundation

/// 本地 Whisper: 启动 vendor/whisper.cpp 编译出来的 whisper-server (模型常驻内存), 通过 HTTP 转写
final class WhisperServer {
    /// 项目根目录 = build/QuickVoice.app 往上两级
    let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    var binary: URL { root.appendingPathComponent("vendor/whisper.cpp/build/bin/whisper-server") }
    var model: URL { root.appendingPathComponent("models/ggml-large-v3-turbo.bin") }
    let port = 8178
    private var process: Process?
    private(set) var ready = false

    var installed: Bool {
        FileManager.default.isExecutableFile(atPath: binary.path)
            && FileManager.default.fileExists(atPath: model.path)
    }

    /// 给 Whisper 的提示文本: 示范 "普通话夹英文术语 + 简体中文 + 标点" 的写法
    static let prompt = "以下是普通话口述，夹杂英文技术词，用简体中文和标点输出：帮我在 worktree 里跑一下 npm test，然后 commit 并 push 到 GitHub；Hey Claude，用 Claude Code 改一下 React component 的 props 和 state，再看看 API 返回的 JSON。"

    func start() async {
        guard installed else {
            log("Whisper 未安装 (需要 \(binary.path) 和 \(model.path))")
            return
        }
        if await ping() {
            ready = true
            log("Whisper: 复用已在运行的 whisper-server (端口 \(port))")
            return
        }
        let p = Process()
        p.executableURL = binary
        p.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", "\(port)",
                       "-l", "zh", "-t", "8", "-nt"]
        let serverLog = root.appendingPathComponent("build/whisper-server.log")
        FileManager.default.createFile(atPath: serverLog.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: serverLog) {
            p.standardOutput = h
            p.standardError = h
        }
        do {
            try p.run()
            process = p
            log("Whisper: 启动 whisper-server (pid \(p.processIdentifier)), 加载模型中…")
        } catch {
            log("Whisper: 启动失败 \(error)")
            return
        }
        let t0 = Date()
        for _ in 0..<120 {
            if await ping() {
                ready = true
                log(String(format: "Whisper: 就绪 (加载 %.1fs)", Date().timeIntervalSince(t0)))
                return
            }
            if !p.isRunning {
                log("Whisper: whisper-server 退出了, 看 build/whisper-server.log")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        log("Whisper: 60 秒内没就绪")
    }

    func stop() {
        process?.terminate()
        process = nil
        ready = false
    }

    private func ping() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func transcribe(_ audio: URL) async throws -> String {
        guard ready else { throw NSError(domain: "QuickVoice", code: 2,
                                         userInfo: [NSLocalizedDescriptionKey: "Whisper 还没就绪"]) }
        let boundary = "qv-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "json")
        field("language", "zh")
        field("temperature", "0.0")
        field("prompt", Self.prompt)
        field("suppress_nst", "true")
        field("no_speech_thold", "0.6")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: audio))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw NSError(domain: "QuickVoice", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Whisper 返回异常: \(String(data: data, encoding: .utf8) ?? "?")"])
        }
        // whisper 偶尔把中文标点的 UTF-8 字节切坏, 变成 U+FFFD
        let cleaned = text
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\u{FFFD}", with: "，")
        return Self.dropHallucinations(Self.normalizePunctuation(cleaned))
    }

    /// Whisper 用大量视频字幕训练, 静音处常编出这些话. 一句话去掉这些词后什么都不剩, 才删掉整句
    static let hallucinations = ["请不吝点赞订阅转发打赏支持明镜与点点栏目", "字幕由Amara.org社区提供",
                                 "谢谢大家", "谢谢观看", "感谢观看", "谢谢收看", "感谢收看", "谢谢",
                                 "请订阅", "点赞", "订阅", "转发", "明镜与点点", "YoYo Television"]

    static func dropHallucinations(_ s: String) -> String {
        var sentences: [String] = []
        var cur = ""
        for c in s {
            cur.append(c)
            if "。！？!?".contains(c) { sentences.append(cur); cur = "" }
        }
        if !cur.isEmpty { sentences.append(cur) }
        let kept = sentences.filter { sentence in
            var rest = sentence.filter { !$0.isWhitespace && !$0.isPunctuation }
            for h in hallucinations { rest = rest.replacingOccurrences(of: h, with: "") }
            let bogus = rest.isEmpty && sentence.contains { !$0.isWhitespace && !$0.isPunctuation }
            if bogus { log("丢掉疑似幻觉句: \(sentence)") }
            return !bogus
        }
        return kept.joined().trimmingCharacters(in: .whitespaces)
    }

    /// 中文句子里的半角 , ? ! 换成全角, 结尾的逗号换成句号
    static func normalizePunctuation(_ s: String) -> String {
        let isCJK: (Character?) -> Bool = { c in
            guard let v = c?.unicodeScalars.first?.value else { return false }
            return (0x4E00...0x9FFF).contains(v) || (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v)
        }
        let map: [Character: Character] = [",": "，", "?": "？", "!": "！"]
        let chars = Array(s.trimmingCharacters(in: .whitespacesAndNewlines))
        var out = ""
        for (i, c) in chars.enumerated() {
            if let full = map[c], isCJK(i > 0 ? chars[i - 1] : nil) || isCJK(i + 1 < chars.count ? chars[i + 1] : nil) {
                out.append(full)
            } else {
                out.append(c)
            }
        }
        if out.hasSuffix("，") { out = String(out.dropLast()) + "。" }
        return out
    }
}
