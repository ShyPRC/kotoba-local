import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class Library: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var selection: UUID?
    @Published var message: String?
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "KotobaLocal/Recordings", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            for directory in try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) where directory.hasDirectoryPath {
                do {
                    let data = try Data(contentsOf: directory.appending(path: "transcript.json"))
                    recordings.append(try JSONDecoder().decode(Recording.self, from: data))
                } catch { message = "有记录无法读取，原文件已保留：\(error.localizedDescription)" }
            }
            recordings.sort { $0.createdAt > $1.createdAt }
            selection = recordings.first?.id
        } catch { message = "无法读取记录目录：\(error.localizedDescription)" }
    }
    var selected: Recording? { recordings.first { $0.id == selection } }
    func directory(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func audio(_ id: UUID) -> URL? {
        guard let row = recordings.first(where: { $0.id == id }) else { return nil }
        return directory(id).appending(path: row.audioName)
    }
    @discardableResult func create(audioName: String = "audio.caf") throws -> UUID {
        let row = Recording(title: "课堂录音 \(Date().formatted(date: .abbreviated, time: .shortened))", audioName: audioName)
        try FileManager.default.createDirectory(at: directory(row.id), withIntermediateDirectories: true)
        try write(row)
        recordings.insert(row, at: 0)
        selection = row.id
        return row.id
    }
    func write(_ row: Recording) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(row).write(to: directory(row.id).appending(path: "transcript.json"), options: .atomic)
    }
    func update(_ id: UUID, _ action: (inout Recording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        action(&recordings[index])
        do { try write(recordings[index]) }
        catch { message = "保存失败，请检查磁盘空间：\(error.localizedDescription)" }
    }
    func nextTranslation() -> (UUID, Segment)? {
        for row in recordings {
            if let segment = row.segments.first(where: { $0.isFinal && $0.chinese.isEmpty && !$0.japanese.isEmpty }) { return (row.id, segment) }
        }
        return nil
    }
    func export(_ format: ExportFormat) {
        guard let row = selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        panel.nameFieldStringValue = row.title.replacingOccurrences(of: "/", with: "-") + "." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try row.exported(format).write(to: url, atomically: true, encoding: .utf8) }
        catch { message = "导出失败：\(error.localizedDescription)" }
    }
}
