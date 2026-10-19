import Foundation
import os

/// Diagnostics written to ~/Library/Logs/Vocab/vocab.log and the unified log (subsystem io.github.vangie.vocab).
public enum VocabLog {
    static let logger = Logger(subsystem: "io.github.vangie.vocab", category: "app")
    static let queue = DispatchQueue(label: "vocab.log")
    public static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Vocab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocab.log")
    }()
    static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

    public static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
        let line = "\(fmt.string(from: Date())) \(message)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
