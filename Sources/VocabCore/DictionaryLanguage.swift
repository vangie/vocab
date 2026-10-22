import Foundation

/// Language groups for the Settings › 词典 filter bar.
public enum DictionaryLanguageGroup: String, CaseIterable, Sendable {
    case simplified, traditional, english, japanese, other

    public var label: String {
        switch self {
        case .simplified: "中文简体"
        case .traditional: "中文繁体"
        case .english: "英语"
        case .japanese: "日语"
        case .other: "其他"
        }
    }

    public static let defaultSelection: Set<DictionaryLanguageGroup> = [.simplified, .english]
    public static let filterKey = "dictionaryLanguageFilter"

    /// Saved filter values, migrating the old single 普通话 group to 简体; the removed 粤语 group is dropped.
    public static func decodeFilter(_ raw: [String]) -> Set<DictionaryLanguageGroup> {
        Set(raw.compactMap { $0 == "mandarin" ? .simplified : DictionaryLanguageGroup(rawValue: $0) })
    }

    /// Known dictionaries whose names mislead (Chinese name, English-only content…).
    static let overrides: [String: Set<DictionaryLanguageGroup>] = [
        "重编国语辞典": [.traditional], "重編國語辭典": [.traditional],
        "Macmillan2": [.english], "麦克米伦英语词典第二版": [.english],
        "LDOCE5": [.english, .simplified], "朗文当代高级英语辞典": [.english, .simplified],
        "Longman5_Extras": [.english],
        "io.github.vangie.vocab.baidubaike": [.simplified],
    ]

    /// Simplified or traditional, from the characters of a Chinese name.
    static func chineseScript(_ name: String) -> DictionaryLanguageGroup {
        let simp = name.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? name
        return simp == name ? .simplified : .traditional
    }

    /// Groups of one dictionary: from its language codes (bilingual → each side), else from the name.
    public static func groups(languages: [String], name: String, id: String = "") -> Set<DictionaryLanguageGroup> {
        if let o = overrides[id] ?? overrides[name] { return o }
        var out = Set<DictionaryLanguageGroup>()
        var bareChinese = false
        for raw in languages {
            let c = raw.lowercased().replacingOccurrences(of: "_", with: "-")
            if c.hasPrefix("zh-hans") || c.hasPrefix("yue-hans") || c == "zh-cn" || c == "zh-sg" { out.insert(.simplified) }
            else if c.hasPrefix("zh-hant") || c.hasPrefix("yue-hant") || c == "zh-tw" || c == "zh-hk" || c == "zh-mo" { out.insert(.traditional) }
            else if c.hasPrefix("zh") || c.hasPrefix("cmn") || c.hasPrefix("yue") { bareChinese = true }
            else if c.hasPrefix("en") { out.insert(.english) }
            else if c.hasPrefix("ja") { out.insert(.japanese) }
            else if !c.isEmpty { out.insert(.other) }
        }
        if bareChinese && !out.contains(.simplified) && !out.contains(.traditional) { out.insert(chineseScript(name)) }
        if !out.isEmpty { return japaneseOnly(out, name: name) }
        // No metadata: guess from the name / id.
        let n = name.lowercased(), i = id.lowercased()
        if n.contains("英") || n.contains("english") || n.contains("oxford") || n.contains("longman") || n.contains("ldoce")
            || n.contains("macmillan") || n.contains("collins") || n.contains("webster") || n.contains("cambridge")
            || n.contains("wikipedia") || i.contains("wikipedia") || i.contains("ldoce") || i.contains("oald") { out.insert(.english) }
        // English as one side of a bilingual dictionary, named in the other language.
        for t in ["engelsk", "angol", "anglick", "anglès", "engels", "englanti", "inggris", "영한", "อังกฤษ", "apple dictionary", "english-", "-english"]
            where n.contains(t) { out.insert(.english) }
        if n.contains("japanese") || n.contains("大辞林") || n.contains("辞泉") { out.insert(.japanese) }
        let han = name.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if han { out.insert(chineseScript(name)) }
        if i.contains("wikipedia") { out.insert(.simplified) }
        // Bilingual English–X (Oxford German, Arabic…, Korean, Thai…): X is "other".
        let otherScript = name.unicodeScalars.contains { v in
            v.value > 0x024F && !(0x4E00...0x9FFF).contains(v.value) && !(0x3000...0x30FF).contains(v.value)
                && !(0xFF00...0xFFEF).contains(v.value) && !(0x2000...0x206F).contains(v.value) && !(0x3400...0x4DBF).contains(v.value)
        }
        let otherLang = ["german", "french", "italian", "italiano", "português", "portuguese", "polish", "russian", "turkish", "español",
                         "spanish", "greek", "malay", "indonesia", "swedish", "svensk", "dansk", "norsk", "nederlands", "català", "catal",
                         "magyar", "ordbok", "ordbog", "suomi", "hrvat", "česk", "sloven", "türk", "việt", "arabic", "hebrew", "hindi", "deutsch", "français"]
        if out.contains(.english) && (otherScript || otherLang.contains(where: n.contains)) { out.insert(.other) }
        out = japaneseOnly(out, name: name)
        return out.isEmpty ? [.other] : out
    }

    /// Kana in the name (or ja metadata) makes it a Japanese dictionary: never a Chinese group.
    static func japaneseOnly(_ g: Set<DictionaryLanguageGroup>, name: String) -> Set<DictionaryLanguageGroup> {
        let kana = name.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        guard kana || g.contains(.japanese) else { return g }
        var out = g.subtracting([.simplified, .traditional])
        out.insert(.japanese)
        return out
    }

    /// Reorder within a filtered view: the visible dictionaries keep the global slots they occupied,
    /// filled in their new order; hidden ones don't move.
    public static func merge(global: [String], visibleInNewOrder visible: [String]) -> [String] {
        let shown = Set(visible)
        var it = visible.makeIterator()
        return global.map { shown.contains($0) ? (it.next() ?? $0) : $0 }
    }
}
