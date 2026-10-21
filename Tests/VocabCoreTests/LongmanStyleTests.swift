import XCTest
@testable import VocabCore

final class LongmanStyleTests: XCTestCase {
    func testScopedToLongman() {
        XCTAssertTrue(LongmanStyle.applies(to: "LDOCE5"))
        XCTAssertTrue(LongmanStyle.applies(to: "com.example.Longman"))
        XCTAssertFalse(LongmanStyle.applies(to: "com.apple.dictionary.zh_CN-en.OCD"))
        // Every rule lives under Longman's root, so it can't leak into other entries.
        for line in LongmanStyle.css.split(separator: "\n") where line.contains("{") && !line.contains("@media") {
            XCTAssertTrue(line.contains(".lm5ppbody"), "unscoped rule: \(line)")
        }
    }
    func testInjectedIntoHead() {
        let html = "<html><head></head><body><span class=\"lm5ppbody\">x</span></body></html>"
        let out = EntryHTML.prepare(html, resourceDirectory: nil, extraCSS: LongmanStyle.css)
        XCTAssertTrue(out.contains(".lm5ppbody .HWD"))
        XCTAssertFalse(EntryHTML.prepare(html, resourceDirectory: nil).contains(".lm5ppbody .HWD"))
    }
}
