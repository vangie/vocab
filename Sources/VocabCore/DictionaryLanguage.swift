import Foundation

/// Language groups for the Settings › 词典 filter bar.
public enum DictionaryLanguageGroup: String, CaseIterable, Sendable {
    case mandarin, cantonese, english, japanese, other

    public var label: String {
        switch self {
        case .mandarin: "中文普通话"
        case .cantonese: "中文广东话（粤语）"
        case .english: "英语"
        case .japanese: "日语"
        case .other: "其他"
        }
    }

    public static let defaultSelection: Set<DictionaryLanguageGroup> = [.mandarin, .english]
    public static let filterKey = "dictionaryLanguageFilter"

    /// Groups of one dictionary: from its language codes (bilingual → each side), else from the name.
    public static func groups(languages: [String], name: String, id: String = "") -> Set<DictionaryLanguageGroup> {
        var out = Set<DictionaryLanguageGroup>()
        for raw in languages {
            let c = raw.lowercased().replacingOccurrences(of: "_", with: "-")
            if c.hasPrefix("yue") || c == "zh-hk" || c == "zh-mo" { out.insert(.cantonese) }
            else if c.hasPrefix("zh") || c.hasPrefix("cmn") { out.insert(.mandarin) }
            else if c.hasPrefix("en") { out.insert(.english) }
            else if c.hasPrefix("ja") { out.insert(.japanese) }
            else if !c.isEmpty { out.insert(.other) }
        }
        if !out.isEmpty { return out }
        // No metadata: guess from the name / id.
        let n = name.lowercased(), i = id.lowercased()
        if n.contains("粤") || n.contains("粵") || n.contains("廣東") || n.contains("广东") || n.contains("cantonese") { out.insert(.cantonese) }
        if n.contains("英") || n.contains("english") || n.contains("oxford") || n.contains("longman") || n.contains("ldoce")
            || n.contains("macmillan") || n.contains("collins") || n.contains("webster") || n.contains("cambridge")
            || n.contains("wikipedia") || i.contains("wikipedia") || i.contains("ldoce") || i.contains("oald") { out.insert(.english) }
        // English as one side of a bilingual dictionary, named in the other language.
        for t in ["engelsk", "angol", "anglick", "anglès", "engels", "englanti", "inggris", "영한", "อังกฤษ", "apple dictionary", "english-", "-english"]
            where n.contains(t) { out.insert(.english) }
        if n.contains("中日") || n.contains("日中") || n.contains("汉日") || n.contains("日汉") { out.insert(.mandarin) }
        if n.contains("日") || n.contains("japanese") || n.contains("大辞林") || n.contains("辞泉") || n.contains("ウィズダム") { out.insert(.japanese) }
        let han = name.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let kana = name.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        if han && !kana && !out.contains(.japanese) && !out.contains(.cantonese) { out.insert(.mandarin) }
        if i.contains("wikipedia") { out.insert(.mandarin) }
        // Bilingual English–X (Oxford German, Arabic…, Korean, Thai…): X is "other".
        let otherScript = name.unicodeScalars.contains { v in
            v.value > 0x024F && !(0x4E00...0x9FFF).contains(v.value) && !(0x3000...0x30FF).contains(v.value)
                && !(0xFF00...0xFFEF).contains(v.value) && !(0x2000...0x206F).contains(v.value) && !(0x3400...0x4DBF).contains(v.value)
        }
        let otherLang = ["german", "french", "italian", "italiano", "português", "portuguese", "polish", "russian", "turkish", "español",
                         "spanish", "greek", "malay", "indonesia", "swedish", "svensk", "dansk", "norsk", "nederlands", "català", "catal",
                         "magyar", "ordbok", "ordbog", "suomi", "hrvat", "česk", "sloven", "türk", "việt", "arabic", "hebrew", "hindi", "deutsch", "français"]
        if out.contains(.english) && (otherScript || otherLang.contains(where: n.contains)) { out.insert(.other) }
        return out.isEmpty ? [.other] : out
    }

    /// Reorder within a filtered view: the visible dictionaries keep the global slots they occupied,
    /// filled in their new order; hidden ones don't move.
    public static func merge(global: [String], visibleInNewOrder visible: [String]) -> [String] {
        let shown = Set(visible)
        var it = visible.makeIterator()
        return global.map { shown.contains($0) ? (it.next() ?? $0) : $0 }
    }
}
