import Foundation

struct SessionFile: Codable {
    var windows: [SessionWindow]
}

struct SessionWindow: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var activeDocumentIndex: Int?
    var tabs: [SessionTab]
}

struct SessionTab: Codable {
    var path: String?
    var displayName: String
    var text: String?
    var encoding: String
    var lineEnding: String
    var cursor: Int
    var scrollX: Double
    var scrollY: Double
    var modified: Bool
}

enum SessionStore {
    private static let queue = DispatchQueue(label: "com.frank.taccuino.session", qos: .utility)

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Taccuino", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("session.json")
    }

    static func load() -> SessionFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionFile.self, from: data)
    }

    static func save(_ session: SessionFile) {
        guard let encoder = try? JSONEncoder().encode(session) else { return }
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoder.write(to: fileURL, options: .atomic)
            } catch {
                // Il salvataggio della sessione non deve mai bloccare l'editor.
            }
        }
    }

    static func saveSynchronously(_ session: SessionFile) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Ignora: al prossimo avvio si partirà da una sessione vuota.
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
