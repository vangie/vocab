import CryptoKit
import Foundation
import SQLite3
import zlib

/// CSV (RFC 4180) export and import.
public enum CSVExporter {
    public static let header = ["word", "lemma", "definition", "dictionary", "context", "source_app", "source_title", "source_url",
                                "tags", "note", "wordbook", "added", "due", "interval_days", "repetitions", "lapses",
                                "stability", "difficulty", "state"]

    static func quote(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    public static func csv(_ items: [WordItem], books: [Wordbook] = []) -> String {
        let f = ISO8601DateFormatter()
        var lines = [header.joined(separator: ",")]
        for i in items {
            lines.append([i.word, i.lemma ?? "", i.definition, i.dictionary, i.context ?? "",
                          i.sourceApp ?? "", i.sourceTitle ?? "", i.sourceURL ?? "",
                          i.tags.joined(separator: "; "), i.note, books.first { $0.id == i.bookID }?.name ?? "",
                          f.string(from: i.added),
                          f.string(from: i.review.due), String(format: "%g", i.review.intervalDays),
                          "\(i.review.repetitions)", "\(i.review.lapses)",
                          i.review.stability.map { String(format: "%.4g", $0) } ?? "", i.review.difficulty.map { String(format: "%.4g", $0) } ?? "",
                          "\(i.review.state)"].map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

public enum CSVParser {
    /// RFC 4180 rows (quoted fields, doubled quotes, CRLF or LF). A leading UTF-8 BOM is ignored.
    public static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []; var row: [String] = []; var field = ""
        var inQ = false
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQ {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { inQ = false }
                } else { field.unicodeScalars.append(c) }
            } else if c == "\"" { inQ = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\r" || c == "\n" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else { field.unicodeScalars.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

public struct ImportResult: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var contexts = 0
}

public enum WordbookImporter {
    /// Import CSV. With a header row, columns are matched by name (our export, or word/definition/
    /// context/tags/note …); without one, column 1 is the word and column 2 the definition.
    @discardableResult
    public static func importCSV(_ text: String, into store: WordStore, book: Int64? = nil, now: Date = Date()) throws -> ImportResult {
        var rows = CSVParser.rows(text)
        guard !rows.isEmpty else { return ImportResult() }
        let aliases: [String: [String]] = [
            "word": ["word", "单词", "term", "front", "生词"], "definition": ["definition", "释义", "meaning", "back", "translation"],
            "context": ["context", "sentence", "例句", "原句", "usage"], "lemma": ["lemma", "stem", "原形"],
            "tags": ["tags", "tag", "标签"], "note": ["note", "notes", "备注", "笔记"], "dictionary": ["dictionary", "词典"],
            "source_app": ["source_app", "source", "来源"], "source_title": ["source_title", "title", "book"],
            "source_url": ["source_url", "url"], "wordbook": ["wordbook", "生词本"], "added": ["added", "加入时间"],
        ]
        let head = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var col: [String: Int] = [:]
        for (k, names) in aliases { if let i = head.firstIndex(where: { names.contains($0) }) { col[k] = i } }
        if col["word"] != nil { rows.removeFirst() } else { col = ["word": 0, "definition": 1] }
        let iso = ISO8601DateFormatter()
        var res = ImportResult()
        try store.transaction {
            var bookIDs: [String: Int64] = [:]
            for r in rows {
                func v(_ k: String) -> String? {
                    guard let i = col[k], i < r.count else { return nil }
                    let s = r[i].trimmingCharacters(in: .whitespacesAndNewlines); return s.isEmpty ? nil : s
                }
                guard let word = v("word") else { continue }
                var target = book
                if target == nil, let bn = v("wordbook") {
                    if bookIDs[bn] == nil { bookIDs[bn] = try store.createBook(bn).id }
                    target = bookIDs[bn]
                }
                let existing = try store.find(word: word)
                let before = existing?.contextCount ?? 0
                let src = WordSource(app: v("source_app"), title: v("source_title"), url: v("source_url"))
                let it = try store.add(word: word, definition: v("definition") ?? "", dictionary: v("dictionary") ?? "",
                                       context: v("context"), lemma: v("lemma"),
                                       source: src.app == nil && src.title == nil && src.url == nil ? nil : src,
                                       book: target, now: v("added").flatMap(iso.date(from:)) ?? now)
                if existing == nil { res.added += 1 } else { res.updated += 1 }
                res.contexts += it.contextCount - before
                if let t = v("tags") {
                    let tags = t.split(whereSeparator: { ";,，；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
                    for tag in tags { try store.addTag(tag, to: [it.id]) }
                }
                if let n = v("note"), it.note.isEmpty { try store.setNote(id: it.id, n) }
            }
        }
        return res
    }

    /// Import a Kindle `vocab.db` (WORDS / LOOKUPS / BOOK_INFO): each lookup becomes a context
    /// sentence with the book title as its source; the stem is the word, the looked-up form its surface.
    @discardableResult
    public static func importKindle(at url: URL, into store: WordStore, book: Int64? = nil) throws -> ImportResult {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw WordStoreError.open(url.path) }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT w.word, w.stem, l.usage, l.timestamp, b.title, b.authors
        FROM LOOKUPS l JOIN WORDS w ON w.id = l.word_key LEFT JOIN BOOK_INFO b ON b.id = l.book_key
        ORDER BY l.timestamp
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw WordStoreError.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(st) }
        func t(_ i: Int32) -> String? {
            sqlite3_column_text(st, i).map { String(cString: $0) }.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        var res = ImportResult()
        try store.transaction {
            while sqlite3_step(st) == SQLITE_ROW {
                guard let surface = t(0) else { continue }
                let stem = t(1) ?? surface
                let ts = sqlite3_column_double(st, 3)
                let date = ts > 0 ? Date(timeIntervalSince1970: ts / 1000) : Date()
                let src = WordSource(app: "Kindle", title: t(4))
                let existing = try store.find(word: stem)
                let before = existing?.contextCount ?? 0
                let it = try store.add(word: stem, definition: "", dictionary: "", context: t(2), surface: surface,
                                       lemma: nil, source: src, book: book, now: date)
                if existing == nil { res.added += 1 } else { res.updated += 1 }
                res.contexts += it.contextCount - before
            }
        }
        return res
    }
}

// MARK: - Anki

/// Writes an Anki package (.apkg, legacy collection.anki2 schema 11) with one Cloze note per word:
/// the source sentence with the word blanked, the definition as the hint/extra. Words without a
/// sentence become "{{c1::word}}" with the definition on the back.
public enum AnkiExporter {
    public static let modelID: Int64 = 1_607_392_319   // fixed so re-imports update the same note type
    public static let deckBase: Int64 = 2_059_400_110

    /// Cloze text for one word: every occurrence of the word (or its surface/lemma) in the sentence.
    public static func cloze(sentence: String?, word: String, forms: [String] = [], hint: String? = nil) -> String {
        let h = hint.map { "::" + $0.replacingOccurrences(of: "}}", with: "} }") } ?? ""
        guard let s = sentence, !s.isEmpty else { return "{{c1::\(escape(word))\(h)}}" }
        let candidates = ([word] + forms).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var text = escape(s)
        for f in candidates {
            let pat = "(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: escape(f)) + "[\\p{L}]*"
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { continue }
            let r = NSRange(text.startIndex..., in: text)
            if re.firstMatch(in: text, range: r) != nil {
                text = re.stringByReplacingMatches(in: text, range: r, withTemplate: "{{c1::$0\(NSRegularExpression.escapedTemplate(for: h))}}")
                return text
            }
        }
        // The word isn't literally in the sentence: show the sentence, cloze the word after it.
        return text + "<br>{{c1::\(escape(word))\(h)}}"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func checksum(_ s: String) -> Int64 {
        let d = Insecure.SHA1.hash(data: Data(s.utf8))
        return Int64(d.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) })
    }

    static func guid(_ s: String) -> String {
        let d = Insecure.SHA1.hash(data: Data(("vocab:" + s).utf8))
        return String(Data(d.prefix(8)).base64EncodedString().prefix(10))
    }

    public struct Note: Sendable { public var text: String; public var extra: String; public var tags: [String]; public var key: String }

    public static func notes(for items: [WordItem]) -> [Note] {
        items.map { i in
            let hint = i.definition.isEmpty ? nil : String(i.definition.prefix(40))
            var extra = "<b>\(escape(i.word))</b>"
            if !i.definition.isEmpty { extra += "<br>" + escape(i.definition) }
            if !i.sourceLabel.isEmpty { extra += "<br><small>\(escape(i.sourceLabel))</small>" }
            return Note(text: cloze(sentence: i.context, word: i.word, forms: [i.lemma].compactMap { $0 }, hint: hint),
                        extra: extra,
                        tags: i.tags.map { $0.replacingOccurrences(of: " ", with: "_") } + ["Vocab"], key: i.word.lowercased())
        }
    }

    /// Build the .apkg (a zip of collection.anki2 + an empty media map) at `url`.
    public static func write(_ items: [WordItem], deckName: String, to url: URL, now: Date = Date()) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-anki-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let col = tmp.appendingPathComponent("collection.anki2")
        try buildCollection(notes(for: items), deckName: deckName, at: col, now: now)
        let zip = try ZipWriter.archive([("collection.anki2", try Data(contentsOf: col)), ("media", Data("{}".utf8))])
        try zip.write(to: url, options: .atomic)
    }

    static func buildCollection(_ notes: [Note], deckName: String, at url: URL, now: Date) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw WordStoreError.open(url.path) }
        defer { sqlite3_close(db) }
        func exec(_ s: String) throws {
            var e: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, s, nil, nil, &e) != SQLITE_OK { let m = e.map { String(cString: $0) } ?? "?"; sqlite3_free(e); throw WordStoreError.sql(m) }
        }
        try exec(schema)
        let secs = Int64(now.timeIntervalSince1970), ms = secs * 1000
        let deckID = deckBase + checksum(deckName) % 100_000
        let model: [String: Any] = [
            "id": modelID, "name": "Vocab Cloze", "type": 1, "mod": secs, "usn": -1, "sortf": 0, "did": deckID,
            "tmpls": [["name": "Cloze", "ord": 0, "qfmt": "{{cloze:Text}}", "afmt": "{{cloze:Text}}<br>\n{{Back Extra}}",
                       "did": NSNull(), "bqfmt": "", "bafmt": ""]],
            "flds": [["name": "Text", "ord": 0, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": []],
                     ["name": "Back Extra", "ord": 1, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": []]],
            "css": ".card { font-family: -apple-system, 'PingFang SC', sans-serif; font-size: 20px; text-align: center; color: black; background-color: white; }\n.cloze { font-weight: bold; color: #0a64d6; }\n.nightMode .cloze { color: #5aa9ff; }",
            "latexPre": "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
            "latexPost": "\\end{document}", "latexsvg": false, "tags": [], "vers": [], "req": [[0, "any", [0]]],
        ]
        func deck(_ id: Int64, _ name: String) -> [String: Any] {
            ["id": id, "name": name, "mod": secs, "usn": -1, "desc": "", "dyn": 0, "conf": 1, "collapsed": false,
             "extendNew": 10, "extendRev": 50, "newToday": [0, 0], "revToday": [0, 0], "lrnToday": [0, 0], "timeToday": [0, 0]]
        }
        let decks: [String: Any] = ["1": deck(1, "Default"), "\(deckID)": deck(deckID, deckName)]
        let dconf: [String: Any] = ["1": [
            "id": 1, "name": "Default", "mod": 0, "usn": 0, "maxTaken": 60, "autoplay": true, "timer": 0, "replayq": true, "dyn": false,
            "new": ["bury": true, "delays": [1, 10], "initialFactor": 2500, "ints": [1, 4, 7], "order": 1, "perDay": 20, "separate": true],
            "lapse": ["delays": [10], "leechAction": 0, "leechFails": 8, "minInt": 1, "mult": 0],
            "rev": ["bury": true, "ease4": 1.3, "fuzz": 0.05, "ivlFct": 1, "maxIvl": 36500, "minSpace": 1, "perDay": 100],
        ]]
        let conf: [String: Any] = ["activeDecks": [1], "curDeck": 1, "newSpread": 0, "collapseTime": 1200, "timeLim": 0,
                                   "estTimes": true, "dueCounts": true, "curModel": NSNull(), "nextPos": 1, "sortType": "noteFld",
                                   "sortBackwards": false, "addToCur": true]
        func json(_ o: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self) }
        let tr = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func insert(_ sql: String, _ vals: [Any]) throws {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw WordStoreError.sql(String(cString: sqlite3_errmsg(db))) }
            defer { sqlite3_finalize(st) }
            for (i, v) in vals.enumerated() {
                if let s = v as? String { sqlite3_bind_text(st, Int32(i + 1), s, -1, tr) }
                else if let n = v as? Int64 { sqlite3_bind_int64(st, Int32(i + 1), n) }
                else if let n = v as? Int { sqlite3_bind_int64(st, Int32(i + 1), Int64(n)) }
            }
            guard sqlite3_step(st) == SQLITE_DONE else { throw WordStoreError.sql(String(cString: sqlite3_errmsg(db))) }
        }
        try exec("BEGIN")
        try insert("INSERT INTO col VALUES(1,?,?,?,11,0,0,0,?,?,?,?,'{}')",
                   [secs, ms, ms, try json(conf), try json(["\(modelID)": model]), try json(decks), try json(dconf)])
        for (n, note) in notes.enumerated() {
            let nid = ms + Int64(n)
            let sfld = note.text
            let tags = note.tags.isEmpty ? "" : " " + note.tags.joined(separator: " ") + " "
            try insert("INSERT INTO notes VALUES(?,?,?,?,-1,?,?,?,?,0,'')",
                       [nid, guid(note.key), modelID, secs, tags, note.text + "\u{1f}" + note.extra, sfld, checksum(stripHTML(sfld))])
            try insert("INSERT INTO cards VALUES(?,?,?,0,?,-1,0,0,?,0,0,0,0,0,0,0,0,'')",
                       [nid, nid, deckID, secs, n + 1])
        }
        try exec("COMMIT")
    }

    static func stripHTML(_ s: String) -> String { s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }

    static let schema = """
    CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null, scm integer not null, ver integer not null,
      dty integer not null, usn integer not null, ls integer not null, conf text not null, models text not null, decks text not null,
      dconf text not null, tags text not null);
    CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null, mod integer not null, usn integer not null,
      tags text not null, flds text not null, sfld integer not null, csum integer not null, flags integer not null, data text not null);
    CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null, ord integer not null, mod integer not null,
      usn integer not null, type integer not null, queue integer not null, due integer not null, ivl integer not null,
      factor integer not null, reps integer not null, lapses integer not null, left integer not null, odue integer not null,
      odid integer not null, flags integer not null, data text not null);
    CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null, ease integer not null, ivl integer not null,
      lastIvl integer not null, factor integer not null, time integer not null, type integer not null);
    CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
    CREATE INDEX ix_notes_usn on notes (usn);
    CREATE INDEX ix_cards_usn on cards (usn);
    CREATE INDEX ix_revlog_usn on revlog (usn);
    CREATE INDEX ix_cards_nid on cards (nid);
    CREATE INDEX ix_cards_sched on cards (did, queue, due);
    CREATE INDEX ix_revlog_cid on revlog (cid);
    CREATE INDEX ix_notes_csum on notes (csum);
    """
}

/// Minimal zip writer (stored entries, CRC-32 from zlib).
public enum ZipWriter {
    public static func archive(_ files: [(name: String, data: Data)]) throws -> Data {
        var out = Data(); var central = Data()
        func u16(_ v: Int, _ d: inout Data) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: UInt32, _ d: inout Data) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        for f in files {
            let name = Data(f.name.utf8)
            let crc = f.data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            let offset = UInt32(out.count)
            u32(0x04034b50, &out); u16(20, &out); u16(0x0800, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(crc, &out); u32(UInt32(f.data.count), &out); u32(UInt32(f.data.count), &out); u16(name.count, &out); u16(0, &out)
            out.append(name); out.append(f.data)
            u32(0x02014b50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central)
            u16(0, &central); u16(0x21, &central); u32(crc, &central); u32(UInt32(f.data.count), &central)
            u32(UInt32(f.data.count), &central); u16(name.count, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(0, &central); u32(offset, &central); central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x06054b50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(UInt32(central.count), &out); u32(cdOffset, &out); u16(0, &out)
        return out
    }
}
