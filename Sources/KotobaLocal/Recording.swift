import Foundation

struct Segment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var japanese: String
    var chinese = ""
    var isFinal = false
}

struct Recording: Codable, Identifiable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var duration: Double = 0
    var audioName = "audio.caf"
    var segments: [Segment] = []

    func exported(_ format: ExportFormat) -> String {
        let rows = segments.filter { !$0.japanese.isEmpty }
        switch format {
        case .srt:
            return rows.enumerated().map { index, row in
                "\(index + 1)\n\(Self.srtTime(row.start)) --> \(Self.srtTime(max(row.end, row.start + 0.1)))\n\(row.japanese)\n\(row.chinese.isEmpty ? "[翻译待完成]" : row.chinese)\n"
            }.joined(separator: "\n")
        case .txt, .markdown:
            let heading = format == .markdown ? "# " : ""
            let body = rows.map { row in
                "[\(Self.clock(row.start))]\(row.isFinal ? "" : " [未定稿]")\n日语：\(row.japanese)\n中文：\(row.chinese.isEmpty ? "[翻译待完成]" : row.chinese)"
            }.joined(separator: "\n\n")
            return "\(heading)\(title)\n\(createdAt.formatted(date: .numeric, time: .shortened)) · \(Self.clock(duration))\n\n\(body)\n"
        }
    }

    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    static func srtTime(_ seconds: Double) -> String {
        let ms = max(0, Int((seconds.isFinite ? seconds : 0) * 1000))
        return String(format: "%02d:%02d:%02d,%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

enum ExportFormat: String, CaseIterable { case txt, markdown = "md", srt }
