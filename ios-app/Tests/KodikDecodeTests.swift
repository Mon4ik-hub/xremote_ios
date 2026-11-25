import XCTest
@testable import AnimeGOCast

final class KodikDecodeTests: XCTestCase {
    func testCaesarShiftPreservesCaseAndNonLetters() {
        XCTAssertEqual(KodikExtractor.caesarShift("abc", 1), "bcd")
        XCTAssertEqual(KodikExtractor.caesarShift("aBc1/", 2), "cDe1/")
        XCTAssertEqual(KodikExtractor.caesarShift("z", 1), "a")
        XCTAssertEqual(KodikExtractor.caesarShift("A", 25), "Z")
        XCTAssertEqual(KodikExtractor.caesarShift("ёж. 123", 3), "ёж. 123")
    }

    private func encode(_ link: String, shift: Int) -> String {
        let shifted = KodikExtractor.caesarShift(link, shift)
        let data = Data(shifted.utf8)
        return data.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    func testDecodeKodikUrlBruteForcesShift() throws {
        let original = "//cloud.example.com/useruploads/video/720.mp4"
        for shift in [0, 3, 17, 25] {
            let encoded = encode(original, shift: shift)
            let decoded = try KodikExtractor.decodeKodikUrl(encoded)
            XCTAssertEqual(decoded.link, original)
            XCTAssertEqual(decoded.shift, shift)
        }
    }

    func testDecodeKodikUrlUsesKnownShift() throws {
        let original = "https://cloud.example.com/v.mp4"
        let encoded = encode(original, shift: 11)
        let decoded = try KodikExtractor.decodeKodikUrl(encoded, knownShift: 11)
        XCTAssertEqual(decoded.link, original)
        XCTAssertEqual(decoded.shift, 11)
    }

    func testDecodeKodikUrlFallsBackFromWrongKnownShift() throws {
        let original = "https://cloud.example.com/v.mp4"
        let encoded = encode(original, shift: 4)
        let decoded = try KodikExtractor.decodeKodikUrl(encoded, knownShift: 9)
        XCTAssertEqual(decoded.link, original)
        XCTAssertEqual(decoded.shift, 4)
    }

    func testDecodeKodikUrlThrowsOnGarbage() {
        // "-" недопустим в стандартном base64 — ни один сдвиг не подойдёт
        XCTAssertThrowsError(try KodikExtractor.decodeKodikUrl("////garbage-not-base64!!"))
    }

    func testForceHttps() {
        XCTAssertEqual(KodikExtractor.forceHttps("//a.b/c"), "https://a.b/c")
        XCTAssertEqual(KodikExtractor.forceHttps("https://a.b/c"), "https://a.b/c")
    }
}
