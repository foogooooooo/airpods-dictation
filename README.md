# airpods-dictation（快捷录音）

**Use your AirPods stem as a push-to-talk key for dictation on macOS.** Squeeze once to start recording, squeeze again to stop. The speech is transcribed locally with Whisper (whisper.cpp + Metal) and pasted at the cursor. Double-squeeze sends Enter. Built for vibecoding: talk to Claude Code / Cursor / ChatGPT without touching the keyboard.

用 AirPods 按柄做 Mac 上的语音输入：捏一下开始说话，再捏一下停止，转好的文字会粘贴到光标处，双捏发送。全部在本地运行，主要给 vibecoding 用。

```bash
./scripts/setup-whisper.sh && ./scripts/build.sh && open build/QuickVoice.app
```

环境要求：Apple Silicon、macOS 26+、Xcode（用 `swiftc` 编译）、python3（只用来在项目 `.venv` 里装 cmake，不往全局装东西）。`setup-whisper.sh` 会下载约 1.6GB 的模型。

第一次运行要允许 **麦克风** 和 **辅助功能**（系统设置 → 隐私与安全性 → 辅助功能 → 快捷录音），开机自启默认打开。

## 按键

| 状态 | 单捏 | 双捏 | 三捏 |
|---|---|---|---|
| 空闲 | 开始录音（升调提示音） | 发送回车（短促一声） | 未绑定 |
| 录音中 | 结束 → 识别 → 粘贴（降调提示音） | — | — |

菜单栏麦克风图标的颜色：灰色是空闲，红色是录音中，橙色是识别中。菜单里也能手动开始、结束、发送，切换麦克风和识别引擎，开关开机自启。

## 为什么默认用 Mac 麦克风，而不是 AirPods 麦克风

这是做这个项目踩到的最大的坑。

AirPods 的按柄平时会发普通媒体键（播放/暂停、下一首），任何 App 都能接到。但只要 **AirPods 的麦克风一打开**，蓝牙就会从音乐模式（A2DP）切到通话模式（HFP），按柄随之变成系统的"通话静音键"。macOS 不会把这个事件交给普通 App，而是弹出 *"Cannot Control Mic with AirPods"*。另外还有这些副作用：

- 开麦要等 1.5 到 3 秒
- 音质降到 24kHz
- App 播放的提示音听不见
- 录音结束后的几秒内按柄会失灵

所以有两种模式，在菜单里切换：

| | Mac 内置麦（默认） | AirPods 麦 |
|---|---|---|
| 按柄开始 | ✅ | ✅（等 1.5 到 3 秒） |
| 按柄结束 | ✅ | ❌ 靠"停顿 2.5 秒自动结束"兜底 |
| 提示音 | 开麦后响 | 只能在开麦前响 |
| 音质 / 识别准确度 | 48kHz，更准 | 24kHz |
| 离开 Mac 走动着说 | ❌ 离 Mac 远了就收不清 | ✅ |

**AirPods 麦模式下让按柄能结束录音**，是这个项目最想解决的问题。有思路的话欢迎提 issue 或 PR。

## 识别引擎

- **Whisper large-v3-turbo（默认）**：App 启动时会在本机 `127.0.0.1:8178` 拉起 `whisper-server`，模型一直留在内存里，一分钟的话大约 1 秒出结果。中英混说的识别效果好，可以在 [App/Whisper.swift](App/Whisper.swift) 的 `prompt` 里加你常用的术语。
- **Apple 系统识别**（SpeechAnalyzer）：不用额外配置，但中英混说识别得差。Whisper 没准备好时会自动改用它。

Whisper 在长时间静音的地方容易编出"谢谢大家""谢谢观看"这类话（它的训练数据有大量视频字幕）。App 做了三层处理：

1. 送去识别之前，先裁掉首尾静音，并把超过 1.5 秒的停顿压缩到 1 秒
2. 请求参数里打开 `suppress_nst` 和 `no_speech_thold`
3. 识别结果里如果有一整句只由这类套话组成，就删掉这一句

## 已知问题 / 路线图

从实际使用场景整理的问题，标了处理状态：

| # | 场景 | 会发生什么 | 状态 |
|---|---|---|---|
| 1 | 用 Music / Spotify / 浏览器放音乐或视频 | 系统把按键交给最后一个在播放的 App，单捏就变成暂停音乐 | 已知限制。录音结束时会重新抢回按键，但从别的 App 手里主动抢回来还没做 |
| 2 | 按键没抢到时 | 单捏可能让别的音乐 App 开始播放 | 同上 |
| 3 | 自动入耳检测：摘下一只耳机 | 系统会发出"暂停"，可能被当成单捏，意外开始录音 | 待验证 |
| 4 | 设备流转：iPhone 来电或开始放视频 | AirPods 自动切到 iPhone，Mac 收不到任何按键 | 已知限制。切回来之后能否自动恢复还待验证 |
| 5 | 正在开 Zoom / FaceTime 会议 | AirPods 处于通话模式，按柄归会议 App 管 | 已知限制 |
| 6 | 识别完成时屏幕上是别的窗口 | 文字会粘贴到当前焦点所在的地方，可能粘错 | 待做：粘贴前切回开始录音时的 App；在菜单里保留最近几条识别结果 |
| 7 | 走动时看不到屏幕 | 不知道识别得对不对就双捏发送了 | 待做：把识别结果念给你听，确认后再发 |
| 8 | 不同输入框里 Enter 的含义 | 有的地方 Enter 是换行，不是发送 | 已知限制 |
| 9 | 剪贴板 | 粘贴时临时占用 1 秒；剪贴板管理工具会记下每一次识别结果 | 已知限制 |
| 10 | Mac 睡眠 | 为了接收按键，App 要一直播放静音，而这会阻止 Mac 自动睡眠 | 已缓解：只在输出是蓝牙耳机且屏幕亮着时播放 |
| 11 | 耗电 | AirPods 一直保持音频连接；Whisper 常驻约 1.6GB 内存 | 待做：空闲一段时间后卸载模型 |
| 12 | 离开 Mac 走动 | 只能用 AirPods 麦模式，按柄结束不可用 | 最高优先级，正在研究 |
| 13 | 分发 | 没有 Developer ID 签名和公证，只能自己编译 | 已知限制 |
| 14 | 语言 | 目前写死为中文，混一些英文术语 | 待做：可配置 |

## 目录

```
App/                Swift 源码（菜单栏 App，不依赖 Xcode 工程，用 swiftc 直接编译）
  main.swift        状态机、菜单、AirPods 事件、开机自启
  Audio.swift       Now Playing 占位和提示音；录音、停顿检测、静音裁剪
  Whisper.swift     whisper-server 的管理和调用，幻觉过滤
  Transcriber.swift Apple SpeechAnalyzer
  Support.swift     日志、音频设备、模拟按键和粘贴
Probe/              最早的 AirPods 按键探针，用来看按柄会发出哪些事件
scripts/build.sh            编译出 build/QuickVoice.app
scripts/setup-whisper.sh    编译 whisper.cpp，下载模型
vendor/ models/ .venv/      本地依赖，不进 git
```

日志在 `build/quickvoice.log` 和 `build/whisper-server.log`。

## License

MIT
