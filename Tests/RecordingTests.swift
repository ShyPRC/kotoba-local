import XCTest
import AVFoundation
import Speech
@testable import KotobaLocal

final class RecordingTests: XCTestCase {
    func testExportPreservesBothLanguagesAndPendingTranslation() {
        let row = Recording(title: "日本語の授業", duration: 71, segments: [
            Segment(start: 1.234, end: 4.567, japanese: "今日は日本語を勉強します。", chinese: "今天学习日语。", isFinal: true),
            Segment(start: 60, end: 65, japanese: "次のページです。", isFinal: false)
        ])
        for format in ExportFormat.allCases {
            let text = row.exported(format)
            XCTAssertTrue(text.contains("今日は日本語を勉強します。"))
            XCTAssertTrue(text.contains("今天学习日语。"))
            XCTAssertTrue(text.contains("次のページです。"))
            XCTAssertTrue(text.contains("[翻译待完成]"))
        }
        XCTAssertTrue(row.exported(.srt).contains("00:00:01,234 --> 00:00:04,567"))
        XCTAssertTrue(row.exported(.txt).contains("[未定稿]"))
        XCTAssertTrue(row.exported(.markdown).hasPrefix("# 日本語の授業"))
    }

    func testTimeFormattingSurvivesInvalidValuesAndLongLectures() {
        XCTAssertEqual(Recording.clock(3661), "01:01:01")
        XCTAssertEqual(Recording.clock(.nan), "00:00:00")
        XCTAssertEqual(Recording.srtTime(-2), "00:00:00,000")
    }

    func testLiveAudioPipelineWritesOriginalAndResamplesForRecognition() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800))
        buffer.frameLength = 4800
        for index in 0..<4800 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.1) * 0.05) }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        var pipe: AudioPipe? = try AudioPipe(url: url, input: source, target: target, continuation: continuation) { message in XCTFail(message) }
        pipe?.receive(buffer)
        pipe?.finish()
        pipe = nil
        continuation.finish()
        var frames: AVAudioFrameCount = 0
        for await input in stream {
            XCTAssertEqual(input.buffer.format.sampleRate, 16000)
            frames += input.buffer.frameLength
        }
        XCTAssertGreaterThan(frames, 1400)
        XCTAssertLessThanOrEqual(frames, 1600)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 4800)
    }

    @MainActor func testLibraryReloadAndTranslationResume() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let id = try library.create()
        let segment = Segment(start: 0, end: 3, japanese: "こんにちは。", isFinal: true)
        library.update(id) { $0.title = "保存テスト"; $0.segments = [segment] }
        let reloaded = Library(root: root)
        XCTAssertNil(reloaded.message)
        XCTAssertEqual(reloaded.selected?.title, "保存テスト")
        XCTAssertEqual(reloaded.nextTranslation()?.1.id, segment.id)
        reloaded.update(id) { $0.segments[0].chinese = "你好。" }
        XCTAssertNil(Library(root: root).nextTranslation())
    }
}
