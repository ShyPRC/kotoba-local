import AVFoundation
import Speech
import SwiftUI

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

// The audio callback owns this pipeline; conversion and disk writes run serially on it.
final class AudioPipe: @unchecked Sendable {
    let file: AVAudioFile
    let converter: AVAudioConverter
    let target: AVAudioFormat
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let onError: @Sendable (String) -> Void
    private var failed = false

    init(url: URL, input: AVAudioFormat, target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, onError: @escaping @Sendable (String) -> Void) throws {
        file = try AVAudioFile(forWriting: url, settings: input.settings)
        guard let converter = AVAudioConverter(from: input, to: target) else { throw AppFailure.message("无法转换麦克风音频格式。") }
        self.converter = converter
        self.target = target
        self.continuation = continuation
        self.onError = onError
    }
    func receive(_ input: AVAudioPCMBuffer) {
        guard !failed else { return }
        do {
            try file.write(from: input)
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate)) + 256
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw AppFailure.message("音频缓冲区分配失败。") }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return input
            }
            if status == .error { throw conversionError ?? AppFailure.message("音频转换失败。") as NSError }
            if output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
        } catch {
            failed = true
            onError(error.localizedDescription)
        }
    }
    // Resampling buffers a short tail; feed end-of-stream before closing recognition.
    func finish() {
        guard !failed else { return }
        while let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                state.pointee = .endOfStream
                return nil
            }
            if status == .error {
                failed = true
                onError(conversionError?.localizedDescription ?? "音频收尾转换失败。")
                break
            }
            if output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
    }
}

@MainActor
final class Recorder: ObservableObject {
    @Published var busy = false
    @Published var isRecording = false
    @Published var status = "准备就绪"
    @Published var elapsed: Double = 0
    var activeID: UUID?
    private let library: Library
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pipe: AudioPipe?
    private var pendingID: UUID?
    private var timer: Timer?
    private var startDate: Date?

    init(library: Library) { self.library = library }

    private func prepare() async throws -> (SpeechTranscriber, SpeechAnalyzer) {
        status = "检查本地日语识别模型…"
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
            throw AppFailure.message("这台 Mac 暂不支持本地日语识别。需要 Apple 芯片和 macOS 26 或更新版本。")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status = "正在下载日语识别模型，首次使用需要联网…"
            try await request.downloadAndInstall()
        }
        return (transcriber, SpeechAnalyzer(modules: [transcriber]))
    }

    private func listen(_ transcriber: SpeechTranscriber, id: UUID) {
        pendingID = nil
        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let segmentID = pendingID ?? UUID()
                    let row = Segment(id: segmentID, start: max(0, result.range.start.seconds), end: max(0, result.range.end.seconds), japanese: text, isFinal: result.isFinal)
                    library.update(id) { recording in
                        if let index = recording.segments.firstIndex(where: { $0.id == segmentID }) { recording.segments[index] = row }
                        else { recording.segments.append(row) }
                    }
                    pendingID = result.isFinal ? nil : segmentID
                }
            } catch {
                library.message = "转写中断，原始录音已保留：\(error.localizedDescription)"
                if isRecording { Task { await self.stop() } }
            }
        }
    }

    func start() async {
        guard !busy else { return }
        busy = true
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw AppFailure.message("请在“系统设置 → 隐私与安全性 → 麦克风”中允许「言录」使用麦克风。")
            }
            let (transcriber, analyzer) = try await prepare()
            self.analyzer = analyzer
            let engine = AVAudioEngine()
            let input = engine.inputNode.outputFormat(forBus: 0)
            guard input.sampleRate > 0, input.channelCount > 0,
                  let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: input) else {
                throw AppFailure.message("找不到可用的麦克风，请检查输入设备。")
            }
            try await analyzer.prepareToAnalyze(in: target)
            let id = try library.create()
            activeID = id
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            self.continuation = continuation
            let pipe = try AudioPipe(url: library.audio(id)!, input: input, target: target, continuation: continuation) { [weak self] text in
                Task { @MainActor in
                    self?.library.message = "录音保存或处理失败：\(text)"
                    await self?.stop()
                }
            }
            self.pipe = pipe
            self.engine = engine
            listen(transcriber, id: id)
            try await analyzer.start(inputSequence: stream)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: input) { buffer, _ in pipe.receive(buffer) }
            engine.prepare()
            try engine.start()
            isRecording = true
            startDate = Date()
            elapsed = 0
            status = "正在录音 · 日语实时转写"
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let date = self.startDate else { return }
                    self.elapsed = Date().timeIntervalSince(date)
                }
            }
        } catch {
            library.message = error.localizedDescription
            await cleanup()
            busy = false
            status = "未开始录音"
        }
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil
        if let date = startDate { elapsed = Date().timeIntervalSince(date) }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        pipe?.finish()
        pipe = nil // closes the audio file after the tap has stopped
        continuation?.finish()
        continuation = nil
        status = "正在完成最后一段转写…"
        if let id = activeID { library.update(id) { $0.duration = elapsed } }
        do { try await analyzer?.finalizeAndFinishThroughEndOfInput() }
        catch { library.message = "收尾转写失败，录音已保存：\(error.localizedDescription)" }
        await resultTask?.value
        resultTask = nil
        analyzer = nil
        activeID = nil
        busy = false
        status = "已保存 · 中文翻译会继续完成"
    }

    private func cleanup() async {
        timer?.invalidate()
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
        pipe = nil
        continuation?.finish()
        continuation = nil
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel()
        resultTask = nil
        analyzer = nil
        isRecording = false
        activeID = nil
    }

    func importAudio(_ url: URL) async {
        guard !busy else { return }
        busy = true
        do {
            let (transcriber, analyzer) = try await prepare()
            self.analyzer = analyzer
            let id = try library.create(audioName: "audio." + url.pathExtension)
            activeID = id
            let localURL = library.audio(id)!
            try FileManager.default.copyItem(at: url, to: localURL)
            let file = try AVAudioFile(forReading: localURL)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            library.update(id) { $0.title = url.deletingPathExtension().lastPathComponent; $0.duration = duration }
            status = "正在转写导入的录音…"
            listen(transcriber, id: id)
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            await resultTask?.value
            status = "导入转写完成 · 中文翻译会继续完成"
        } catch { library.message = "导入失败：\(error.localizedDescription)"; status = "导入未完成" }
        await cleanup()
        busy = false
    }
}
