# 言录 · Kotoba Local

一个面向日语课堂的原生 Mac App：麦克风录音、日语实时转写、逐段简体中文翻译和每次录音的完整双语导出。

A native macOS app for Japanese lecture recording, live Japanese transcription, Simplified Chinese translation, and full bilingual transcript export. Powered by Apple's on-device Speech and Translation frameworks, with no third-party dependencies or API keys.

## 从源码构建

需要 Apple 芯片 Mac、macOS 26 或更新版本，以及包含 macOS 26 SDK 的 Xcode 26 或更新版本。先打开 Xcode，完成其首次启动设置。

```sh
git clone https://github.com/ShyPRC/kotoba-local.git
cd kotoba-local
./scripts/build.sh
open dist/言录.app
```

如果系统当前只选中了 Command Line Tools，请先将命令行开发目录切换到完整的 Xcode 安装，例如默认位置：

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

本仓库发布源码；构建脚本会在你的 Mac 上生成并本机签名应用。Apple 的语言模型由系统单独下载，不随仓库分发。

## 打开应用

构建后的应用位于 `dist/言录.app`，双击即可打开。需要 Apple 芯片 Mac、macOS 26 或更新版本。当前版本在本机签名，未做 Apple 公证。

1. 首次打开时，按系统提示下载日语／简体中文翻译资源。
2. 点击「开始录音」，允许麦克风访问。首次转写会下载系统日语识别模型；准备期间还没有开始录音，请等待底部显示「正在录音」。
3. 日语原文实时更新，段落确认后自动翻译成中文。具体延迟取决于语速、停顿与设备速度。
4. 点击「停止并保存」，等待最后一段转写收尾。中文翻译仍会继续，建议等「已翻译」数量与段落数量一致后再导出。
5. 点击「导出全文」，选择 TXT、Markdown 或双语 SRT。每份导出包含当前所选录音的全部文字。

也可以导入系统支持的音频文件进行本地转写，或通过「回听录音」播放原始音频。点击文件夹按钮可直接查看原始录音和 JSON 记录。

## 数据与离线使用

- 每次录音独立保存在 `~/Library/Application Support/KotobaLocal/Recordings/<UUID>/`。
- `audio.caf` 是麦克风原始录音；导入文件保留原扩展名。
- `transcript.json` 包含标题、时间、日语原文、中文翻译和段落时间戳，使用原子写入保存。
- 应用使用系统 SpeechAnalyzer 与 Translation 框架处理音频／文字，没有配置云端服务或 API Key。首次下载语言资源需要网络；语言资源就绪后可本地处理。
- 翻译失败时日语记录仍会保存，点击「重试翻译」恢复。再次打开应用会继续处理已定稿但尚未翻译的段落。
- 导出时尚未完成的中文会明确标为「翻译待完成」，TXT／Markdown 会标注未定稿的日语。

## 当前范围

- 录制系统当前默认麦克风；暂不支持直接采集系统内部声音或说话人区分。
- 中文按确认后的段落更新，不是逐字同声传译。
- 不同课堂的距离、噪声、专业词汇会影响识别和翻译效果；重要内容可回听核对。
- 原始音频持续写入磁盘，意外退出后通常可以在录音目录中找回；未定稿文字或未写完的音频尾部可能不完整。可重新导入原音频转写。
- 支持逐次全文导出，暂不支持多次录音一键批量导出。
- 长时间连续录音能力使用系统 SpeechAnalyzer 实现，尚未完成整堂课时长的实录验证。

## 开发与验证

```sh
./scripts/build.sh
swift test
```

使用 Swift Package 管理代码，构建脚本生成带权限说明的 `.app` 包并做本机签名。无需第三方依赖。用 Xcode 打开 `Package.swift` 可以查看源码；需要从生成的 App 包启动以使用完整权限说明。

测试覆盖双语全文导出、SRT 时间戳、长录音时间格式、音频落盘与重采样、记录持久化与待译段落恢复。另已在本机通过合成日语音频验证导入、日语识别、中文翻译和界面全文导出。真实麦克风和课堂场景仍需要在目标设备上验证。

框架参考：[Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)、[Apple TranslationSession](https://developer.apple.com/documentation/translation/translationsession)。

## 许可证

本项目源码使用 [MIT License](LICENSE)。Apple 系统框架及语言资源遵循其各自适用的条款。
