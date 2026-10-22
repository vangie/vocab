import XCTest
@testable import VocabCore

/// The quiz's audio and IPA belong to the displayed word only: "writing" never plays "write".
final class ExactAudioTests: XCTestCase {
    var dir: URL!
    let d = DictionaryInfo(id: "test.dict", name: "T", shortName: "T", bundleURL: nil)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-audio-\(UUID())")
        for f in ["ameProns/right1.mp3", "ameProns/writing.mp3", "ameProns/go1.mp3", "ameProns/ld41went.mp3",
                  "ameProns/apple1.mp3", "ameProns/run1.mp3", "ameProns/running__us_2.mp3", "exaProns/x.mp3"] {
            let u = dir.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: u.path, contents: Data())
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func entry(_ title: String, reported: String? = nil, _ audio: [String], ipa: String = "") -> DictionaryEntry {
        let a = audio.map { "<a href=\"javascript:new Audio(&quot;\($0)&quot;).play()\">♪</a>" }.joined()
        let html = "<d:entry d:title=\"\(title)\"><span class=\"PRON\">\(ipa)</span>\(a)</d:entry>"
        return DictionaryEntry(id: "\(title)-\(UUID())", dictionary: d, headword: reported ?? title, html: html,
                               panelHTML: html, plainText: "", resourceDirectory: dir)
    }

    func testWritingUsesItsOwnEntryNotWrite() {
        let es = [entry("write", ["ameProns/right1.mp3"], ipa: "raɪt"), entry("writing", ["exaProns/x.mp3", "ameProns/writing.mp3"], ipa: "ˈraɪtɪŋ")]
        XCTAssertEqual(Phonetics.audio(for: "writing", in: es)?.lastPathComponent, "writing.mp3")
        XCTAssertEqual(Phonetics.ipa(inHTML: Phonetics.exactEntries("writing", es).map(\.html)), "ˈraɪtɪŋ")
        XCTAssertNil(Phonetics.audio(for: "writing", in: [es[0]]), "base form's audio must never be used")
    }

    func testRunningFromNamedFileInsideRunEntry() {
        // OALD10 lists inflection recordings under the base entry, named after the form.
        let run = entry("run", ["ameProns/run1.mp3", "ameProns/running__us_2.mp3"])
        XCTAssertEqual(Phonetics.audio(for: "running", in: [run])?.lastPathComponent, "running__us_2.mp3")
        XCTAssertTrue(Phonetics.exactEntries("running", [run]).isEmpty)
    }

    func testWentIgnoresGoEntryReportedAsWent() {
        // DCS reports the searched key as headword; Oxford's "go" entry comes back as "went".
        let goAsWent = entry("go", reported: "went", ["ameProns/go1.mp3"], ipa: "ɡoʊ")
        XCTAssertNil(Phonetics.audio(for: "went", in: [goAsWent]))
        XCTAssertNil(Phonetics.ipa(inHTML: Phonetics.exactEntries("went", [goAsWent]).map(\.html)))
        let went = entry("went", ["ameProns/ld41went.mp3"], ipa: "went")
        XCTAssertEqual(Phonetics.audio(for: "went", in: [goAsWent, went])?.lastPathComponent, "ld41went.mp3")
    }

    func testApplesNeverPlaysApple() {
        let apple = entry("apple", ["ameProns/apple1.mp3"], ipa: "ˈæpl")
        XCTAssertNil(Phonetics.audio(for: "apples", in: [apple]))   // → TTS
        XCTAssertTrue(Phonetics.exactEntries("apples", [apple]).isEmpty)
        XCTAssertEqual(Phonetics.audio(for: "Apple", in: [apple])?.lastPathComponent, "apple1.mp3")
    }

    func testFileWord() {
        XCTAssertEqual(Phonetics.fileWord("ameProns/writing__us_4.mp3"), "writing")
        XCTAssertEqual(Phonetics.fileWord("breProns/writing0205.mp3"), "writing")
        XCTAssertNil(Phonetics.fileWord("Sounds/zzz_us_A_A39_A3904_A3904010.mp3"))
        XCTAssertNil(Phonetics.fileWord("exaProns/p008-000504937.mp3"))
        XCTAssertEqual(Phonetics.normalized("writ‧ing"), "writing")
    }

    /// Against the installed dictionaries, when present.
    func testInstalledDictionaries() throws {
        let svc = DictionaryService.shared
        let dicts = svc.availableDictionaries().filter { Phonetics.audioDictionaryIDs.contains($0.id) }
        guard !dicts.isEmpty else { throw XCTSkip("no LDOCE5/OALD10/Macmillan installed") }
        for w in ["writing", "running", "went"] {
            let f = Phonetics.lookup(w, in: dicts).audio?.lastPathComponent ?? ""
            XCTAssertTrue(f.isEmpty || f.lowercased().contains(w) || f.hasPrefix("zzz"), "\(w) → \(f)")
            XCTAssertFalse(["right1.mp3", "run1.mp3", "go1.mp3"].contains(f), "\(w) → \(f)")
        }
        XCTAssertNotEqual(Phonetics.lookup("apples", in: dicts).audio?.lastPathComponent, "apple1.mp3")
    }
}
