import Foundation
import CornucopiaCore

/// Persists the mock tag library, mirroring ImpossiBLE's `MockStore` pattern.
public final class TagStore: ObservableObject {
    @Published public var tags: [MockTag] = []

    private let logger = Cornucopia.Core.Logger()
    private let url: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("NFCromancer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("tags.json")
        load()
        if tags.isEmpty {
            tags = Self.stock
            save()
        }
    }

    public func add(_ tag: MockTag) {
        tags.append(tag)
        save()
    }

    public func update(_ tag: MockTag) {
        guard let i = tags.firstIndex(where: { $0.id == tag.id }) else { return }
        tags[i] = tag
        save()
    }

    public func delete(id: UUID) {
        tags.removeAll { $0.id == id }
        save()
    }

    public func save() {
        do {
            try JSONEncoder().encode(tags).write(to: url)
        } catch {
            logger.error("Failed to save tags: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([MockTag].self, from: data) else { return }
        tags = decoded
    }

    /// Recognizable starter tags, one of each kind.
    static let stock: [MockTag] = [
        MockTag(name: "Example URL", kind: .uri, value: "https://example.com/tag"),
        MockTag(name: "Hello text", kind: .text, value: "Hello from NFCromancer"),
    ]
}
