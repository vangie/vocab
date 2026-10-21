import XCTest
@testable import VocabCore

final class PhoneticsTests: XCTestCase {
    let oxford = #"<span class="prx"><span class="gp tg_prx">BrE </span><span d:prn="UK_IPA solitary" soundFile="attune#_gb_4" dialect="BrE" class="ph">əˈtjuːn<d:prn></d:prn></span></span><span dialect="AmE" class="prx"><span class="gp tg_prx">AmE </span><span d:prn="UK_IPA solitary" soundFile="attune#_us_1" dialect="AmE" class="ph">əˈtun<d:prn></d:prn></span></span>"#
    let ldoce = #"<a class="PronCodes"><span class="neutral span"> /</span><span class="PRON">əˈtɜːni</span><span class="AMEVARPRON"><span class="neutral span"> $ </span>-ɜːr-</span><span class="neutral span">/</span></a>"#

    func testAmericanFirst() {
        XCTAssertEqual(Phonetics.ipa(inHTML: [oxford]), "əˈtun")
        XCTAssertEqual(Phonetics.ipa(inHTML: [ldoce, oxford]), "əˈtun")
    }
    func testLongmanThenBritish() {
        XCTAssertEqual(Phonetics.ipa(inHTML: [ldoce]), "əˈtɜːni")
        let brOnly = oxford.replacingOccurrences(of: "dialect=\"AmE\"", with: "dialect=\"X\"")
        XCTAssertEqual(Phonetics.ipa(inHTML: [brOnly]), "əˈtjuːn")
        XCTAssertNil(Phonetics.ipa(inHTML: ["<p>no ipa</p>"]))
    }
}
