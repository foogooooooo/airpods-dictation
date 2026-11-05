import AVFoundation
import Speech

/// Apple 本地语音识别 (SpeechAnalyzer, macOS 26+)
final class Transcriber {
    private(set) var locale: Locale?
    private(set) var ready = false

    func prepare(preferred: String = "zh-CN") async {
        let supported = await SpeechTranscriber.supportedLocales
        log("SpeechTranscriber 支持的语言: \(supported.map(\.identifier).sorted().joined(separator: ", "))")
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: preferred)) else {
            log("不支持 \(preferred)")
            return
        }
        locale = loc
        let installed = await SpeechTranscriber.installedLocales
        log("识别语言: \(loc.identifier), 已安装: \(installed.contains { $0.identifier == loc.identifier })")
        do {
            let module = SpeechTranscriber(locale: loc, preset: .transcription)
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                log("正在下载系统语音模型 (\(loc.identifier))...")
                try await req.downloadAndInstall()
                log("语音模型安装完成")
            }
            ready = true
            log("识别器就绪")
        } catch {
            log("语音模型准备失败: \(error)")
        }
    }

    func transcribe(_ url: URL) async throws -> String {
        guard let locale, ready else { throw NSError(domain: "QuickVoice", code: 1,
                                                     userInfo: [NSLocalizedDescriptionKey: "识别器还没就绪"]) }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module])
        let context = AnalysisContext()
        context.contextualStrings[.general] = Vocabulary.terms
        try await analyzer.setContext(context)
        let file = try AVAudioFile(forReading: url)

        let collect = Task { () throws -> String in
            var text = ""
            for try await r in module.results where r.isFinal {
                text += String(r.text.characters)
            }
            return text
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// vibecoding 常用术语, 提示识别器优先识别成这些写法
enum Vocabulary {
    static let terms = [
        "Claude", "Claude Code", "Cursor", "Codex", "vibecoding", "prompt", "token", "context",
        "worktree", "commit", "push", "pull", "pull request", "PR", "branch", "merge", "rebase",
        "Git", "GitHub", "README", "diff", "repo",
        "npm", "pnpm", "yarn", "Node", "React", "Vue", "Next.js", "Vite", "Tailwind", "TypeScript",
        "JavaScript", "Python", "Swift", "SwiftUI", "Xcode", "component", "props", "state", "hook",
        "API", "JSON", "CSS", "HTML", "frontend", "backend", "database", "cache", "deploy",
        "bug", "debug", "refactor", "lint", "test", "build", "terminal", "localhost", "venv",
        "AirPods", "Mac", "iPhone",
    ]
}
