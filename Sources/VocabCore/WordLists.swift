import Foundation
import SQLite3

/// Exam word lists from the bundled ECDICT extract (Resources/Data/wordlists.sqlite, MIT).
public enum ExamList: String, CaseIterable, Codable, Sendable, Identifiable {
    case zk, gk, ky, cet4, cet6, ielts, toefl, gre
    public var id: String { rawValue }
    public var bit: Int { 1 << ExamList.allCases.firstIndex(of: self)! }
    public var title: String {
        switch self {
        case .zk: "中考"; case .gk: "高考"; case .ky: "考研"; case .cet4: "四级"; case .cet6: "六级"
        case .ielts: "雅思"; case .toefl: "托福"; case .gre: "GRE"
        }
    }
    /// Source recorded on words first studied from this list.
    public var sourceApp: String { "词书·\(title)" }
}

public struct ListEntry: Equatable, Sendable {
    public var word: String
    public var tags: Int
    public var bnc: Int
    public var frq: Int
    public var lemma: String?
    public var zh: String
    /// Frequency rank: COCA/current (frq) when known, else BNC.
    public var rank: Int { frq > 0 ? frq : bnc }
    public var lists: [ExamList] { ExamList.allCases.filter { tags & $0.bit != 0 } }
}

public final class WordLists: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    /// The bundled extract: app Resources, else the repo copy (tests, `swift run`).
    public static func bundledURL() -> URL? {
        if let u = Bundle.main.url(forResource: "wordlists", withExtension: "sqlite") { return u }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Data/wordlists.sqlite")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    public static let shared: WordLists? = bundledURL().flatMap { try? WordLists(url: $0) }

    public init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw WordStoreError.open(url.path) }
    }
    deinit { sqlite3_close(db) }

    private func query(_ sql: String, _ binds: [Any] = [], _ row: (OpaquePointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        let tr = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in binds.enumerated() {
            if let s = v as? String { sqlite3_bind_text(st, Int32(i + 1), s, -1, tr) }
            else if let n = v as? Int { sqlite3_bind_int64(st, Int32(i + 1), Int64(n)) }
        }
        while sqlite3_step(st) == SQLITE_ROW { row(st!) }
    }

    private static func entry(_ st: OpaquePointer) -> ListEntry {
        ListEntry(word: String(cString: sqlite3_column_text(st, 0)), tags: Int(sqlite3_column_int64(st, 1)),
                  bnc: Int(sqlite3_column_int64(st, 2)), frq: Int(sqlite3_column_int64(st, 3)),
                  lemma: sqlite3_column_text(st, 4).map { String(cString: $0) },
                  zh: sqlite3_column_text(st, 5).map { String(cString: $0) } ?? "")
    }

    public func entry(_ word: String) -> ListEntry? {
        var out: ListEntry?
        query("SELECT word, tags, bnc, frq, lemma, zh FROM words WHERE word = ?", [word.lowercased()]) { out = Self.entry($0) }
        return out
    }

    public func contains(_ word: String) -> Bool { entry(word) != nil }

    /// Words of a list, most frequent first (unranked last, alphabetical).
    public func words(in list: ExamList) -> [String] {
        var out: [String] = []
        query("""
        SELECT word FROM words WHERE tags & ? <> 0
        ORDER BY CASE WHEN (CASE WHEN frq > 0 THEN frq ELSE bnc END) > 0 THEN 0 ELSE 1 END,
                 CASE WHEN frq > 0 THEN frq ELSE bnc END, word
        """, [list.bit]) { out.append(String(cString: sqlite3_column_text($0, 0))) }
        return out
    }

    public func count(in list: ExamList) -> Int {
        var n = 0
        query("SELECT COUNT(*) FROM words WHERE tags & ? <> 0", [list.bit]) { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }

    /// Every word (any form) ranked 1…n: the most common words, skipped before a vocabulary test.
    public func topWords(_ n: Int) -> Set<String> {
        var out = Set<String>()
        query("SELECT word FROM words WHERE (CASE WHEN frq > 0 THEN frq ELSE bnc END) BETWEEN 1 AND ?", [n]) {
            out.insert(String(cString: sqlite3_column_text($0, 0)).lowercased())
        }
        return out
    }

    /// Base forms (no inflections) whose rank lies in `lo...hi`.
    public func lemmas(rank lo: Int, _ hi: Int) -> [String] {
        var out: [String] = []
        query("SELECT word FROM words WHERE lemma IS NULL AND (CASE WHEN frq > 0 THEN frq ELSE bnc END) BETWEEN ? AND ? ORDER BY word",
              [lo, hi]) { out.append(String(cString: sqlite3_column_text($0, 0))) }
        return out
    }

    /// Base forms with their frequency rank, most frequent first (adaptive 词汇量 test).
    public func lemmasRanked(rank lo: Int, _ hi: Int) -> [(word: String, rank: Int)] {
        var out: [(String, Int)] = []
        query("SELECT word, CASE WHEN frq > 0 THEN frq ELSE bnc END AS r FROM words WHERE lemma IS NULL AND r BETWEEN ? AND ? ORDER BY r, word",
              [lo, hi]) { out.append((String(cString: sqlite3_column_text($0, 0)), Int(sqlite3_column_int64($0, 1)))) }
        return out
    }

    /// Pronounceable non-words, verified absent from all of ECDICT when the extract was built.
    public func pseudowords() -> [String] {
        var out: [String] = []
        query("SELECT word FROM pseudowords ORDER BY word") { out.append(String(cString: sqlite3_column_text($0, 0))) }
        return out
    }

    /// Short Chinese meaning ("vt. 放弃, 抛弃；n. …" → "放弃, 抛弃") for when system dictionaries lack one.
    public func shortChinese(_ word: String) -> String? {
        guard let z = entry(word)?.zh, !z.isEmpty else { return nil }
        let first = z.components(separatedBy: "；").first ?? z
        let stripped = first.replacingOccurrences(of: "^[a-z]+\\.\\s*", with: "", options: .regularExpression)
        let parts = stripped.components(separatedBy: CharacterSet(charactersIn: ",，")).prefix(3)
        let s = parts.joined(separator: "，").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}
