import SwiftUI
import AppKit
import Translation
import UniformTypeIdentifiers

@main
struct KotobaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var library: Library
    @StateObject private var recorder: Recorder

    init() {
        let library = Library()
        _library = StateObject(wrappedValue: library)
        _recorder = StateObject(wrappedValue: Recorder(library: library))
    }
    var body: some Scene {
        WindowGroup("言录 · Kotoba") {
            ContentView(library: library, recorder: recorder)
                .onAppear { delegate.recorder = recorder }
        }
        .defaultSize(width: 1120, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recorder: Recorder?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder?.busy == true {
            let alert = NSAlert()
            alert.messageText = "请先停止录音或等待转写完成"
            alert.informativeText = "完成保存后即可退出言录。"
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @ObservedObject var library: Library
    @ObservedObject var recorder: Recorder
    @State private var search = ""
    @State private var translationStatus = "正在准备日中翻译…"
    @State private var translationReady = false
    @State private var configuration: TranslationSession.Configuration = {
        if #available(macOS 26.4, *) {
            return .init(source: .init(identifier: "ja"), target: .init(identifier: "zh-Hans"), preferredStrategy: .lowLatency)
        }
        return .init(source: .init(identifier: "ja"), target: .init(identifier: "zh-Hans"))
    }()
    @State private var player: AVAudioPlayer?
    @State private var follow = true
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.48, green: 0.77, blue: 0.67) : Color(red: 0.17, green: 0.39, blue: 0.35)
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 34)).foregroundStyle(accent)
                    VStack(alignment: .leading) { Text("言录").font(.title2.bold()); Text("KOTOBA · LOCAL").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary) }
                }.padding(.top, 15)
                TextField("搜索课堂与原文", text: $search).textFieldStyle(.roundedBorder)
                HStack { Text("录音资料库").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Text("\(library.recordings.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                List(selection: $library.selection) {
                    ForEach(library.recordings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.segments.contains { $0.japanese.localizedCaseInsensitiveContains(search) || $0.chinese.localizedCaseInsensitiveContains(search) } }) { row in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            Text("\(row.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Recording.clock(row.duration))").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.vertical, 7).tag(row.id)
                    }
                }.listStyle(.sidebar)
                Button { importAudio() } label: { Label("导入已有录音", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }.disabled(recorder.busy)
                Label("录音与文字保存在这台 Mac", systemImage: "lock.shield").font(.caption2).foregroundStyle(.secondary)
            }.padding(18).background(Color(nsColor: .controlBackgroundColor))
            .navigationSplitViewColumnWidth(min: 235, ideal: 270, max: 340)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                if let row = library.selected { transcript(row) }
                else { emptyState }
                Divider()
                controls
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .tint(accent)
        .frame(minWidth: 900, minHeight: 620)
        .translationTask(configuration) { session in
            await translateContinuously(session)
        }
        .alert("言录提示", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("知道了") { library.message = nil }
        } message: { Text(library.message ?? "") }
        .onChange(of: library.selection) { _, _ in player?.stop(); player = nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("日语 → 简体中文", systemImage: "character.bubble").font(.caption.weight(.medium)).foregroundStyle(accent)
                Spacer()
                Menu { ForEach(ExportFormat.allCases, id: \.self) { format in Button("导出 \(format.rawValue.uppercased()) 全文") { library.export(format) } } }
                label: { Label("导出全文", systemImage: "square.and.arrow.up") }
                .disabled(library.selected == nil)
            }
            if let row = library.selected {
                TextField("录音标题", text: Binding(get: { library.selected?.title ?? "" }, set: { title in library.update(row.id) { $0.title = title } }))
                    .textFieldStyle(.plain).font(.system(size: 26, weight: .semibold))
                HStack(spacing: 14) {
                    Text(row.createdAt.formatted(date: .long, time: .shortened))
                    Text("\(row.segments.count) 段")
                    Text("\(row.segments.filter { !$0.chinese.isEmpty }.count) 段已翻译")
                    Spacer()
                    Toggle("跟随最新", isOn: $follow).toggleStyle(.checkbox)
                }.font(.caption).foregroundStyle(.secondary)
            } else {
                Text("把课堂，留在文字里。").font(.system(size: 27, weight: .semibold))
            }
        }.padding(28)
    }

    private func transcript(_ row: Recording) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if row.segments.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: recorder.busy ? "waveform" : "text.bubble").font(.largeTitle).foregroundStyle(accent)
                            Text(recorder.busy ? "正在聆听日语…" : "这段录音还没有转写内容").font(.headline)
                            Text("原文随讲话更新，中文在每段确认后自动出现。").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 90)
                    }
                    ForEach(row.segments) { segment in
                        HStack(alignment: .top, spacing: 18) {
                            Text(Recording.clock(segment.start)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 68).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text("日本語").font(.caption2.bold()).foregroundStyle(.secondary); if !segment.isFinal { Text("识别中").font(.caption2).foregroundStyle(accent) } }
                                Text(segment.japanese).font(.system(size: 17)).lineSpacing(6).textSelection(.enabled)
                                Text(segment.chinese.isEmpty ? (segment.isFinal ? "等待中文翻译…" : "这一段确认后显示翻译") : segment.chinese)
                                    .font(.system(size: 16)).lineSpacing(6).foregroundStyle(segment.chinese.isEmpty ? Color.secondary : accent).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(20).background(accent.opacity(segment.isFinal ? 0.035 : 0.075), in: RoundedRectangle(cornerRadius: 14))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(28)
            }.onChange(of: row.segments) { _, _ in if follow { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 26) {
            Image(systemName: "waveform.and.mic").font(.system(size: 52)).foregroundStyle(accent)
            Text("专心听课，\n其余交给言录。").font(.system(size: 36, weight: .medium)).lineSpacing(8)
            Text("日语实时转写 · 逐段中文翻译 · 全文导出").font(.title3).foregroundStyle(.secondary)
            Text("每次录音独立保存。可随时回听、搜索，或导出带时间戳的双语记录。首次使用需联网下载系统语言资源。").font(.body).foregroundStyle(.secondary).lineSpacing(7).frame(maxWidth: 470, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(55)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Button {
                    player?.stop(); player = nil
                    Task { if recorder.isRecording { await recorder.stop() } else { await recorder.start() } }
                } label: { Label(recorder.isRecording ? "停止并保存" : "开始录音", systemImage: recorder.isRecording ? "stop.fill" : "mic.fill").padding(.horizontal, 16).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent).disabled(recorder.busy && !recorder.isRecording)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recorder.status).font(.system(size: 12, weight: .medium))
                    if recorder.busy { Text(Recording.clock(recorder.elapsed)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { playAudio() } label: { Label(player?.isPlaying == true ? "停止回听" : "回听录音", systemImage: "play.circle") }.disabled(recorder.busy || library.selected == nil)
                Button { if let id = library.selection { NSWorkspace.shared.open(library.directory(id)) } } label: { Image(systemName: "folder") }.help("打开本地录音文件夹").disabled(library.selected == nil)
            }
            HStack {
                Circle().fill(translationReady ? accent : .orange).frame(width: 6, height: 6)
                Text(translationStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if !translationReady { Button("重试翻译") { configuration.invalidate() }.font(.caption2) }
            }
        }.padding(24)
    }

    @MainActor private func translateContinuously(_ session: TranslationSession) async {
        translationReady = false
        translationStatus = "正在准备本地日中翻译，首次使用请允许下载语言资源…"
        do {
            try await session.prepareTranslation()
            translationReady = true
            while !Task.isCancelled {
                if let (recordingID, segment) = library.nextTranslation() {
                    translationStatus = "正在翻译最新段落…"
                    let response = try await session.translate(segment.japanese)
                    library.update(recordingID) { row in
                        if let index = row.segments.firstIndex(where: { $0.id == segment.id && $0.japanese == segment.japanese }) { row.segments[index].chinese = response.targetText }
                    }
                } else {
                    translationStatus = "本地日中翻译已就绪 · 原文确认后自动翻译"
                    try await Task.sleep(for: .milliseconds(400))
                }
            }
        } catch is CancellationError { }
        catch { translationReady = false; translationStatus = "翻译未就绪：\(error.localizedDescription)。日语转写仍会保存，可点击重试。" }
    }
    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await recorder.importAudio(url) }
    }
    private func playAudio() {
        if player?.isPlaying == true { player?.stop(); player = nil; return }
        guard let id = library.selection, let url = library.audio(id) else { return }
        do { player = try AVAudioPlayer(contentsOf: url); player?.play() }
        catch { library.message = "无法播放录音：\(error.localizedDescription)" }
    }
}

import AVFoundation
