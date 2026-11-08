import Foundation
import Combine

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let text: String
    let audioPath: String
    let duration: Double
    let language: String
}

final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private let url: URL

    init(url: URL) {self.url=url;load()}

    func append(text: String, audioURL: URL, duration: Double, language: String) {
        let entry = HistoryEntry(id: UUID(),
                                 date: Date(),
                                 text: text,
                                 audioPath: audioURL.path,
                                 duration: duration,
                                 language: language)
        entries.insert(entry, at: 0)
        if entries.count > 500 { entries.removeLast(entries.count - 500) }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder.iso.decode([HistoryEntry].self, from: data) else { return }
        entries = list
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso.encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]; return e }() }
extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }
