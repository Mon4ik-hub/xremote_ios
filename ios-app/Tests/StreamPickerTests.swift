import XCTest
@testable import AnimeGOCast

final class StreamPickerTests: XCTestCase {
    /// Потоки в том порядке, как их отдаёт экстрактор: по убыванию качества, mp4 раньше hls.
    private let streams: [Stream] = [
        Stream(kind: .hls, quality: 1080, url: "hls1080"),
        Stream(kind: .mp4, quality: 1080, url: "mp4-1080"),
        Stream(kind: .mp4, quality: 720, url: "mp4-720"),
        Stream(kind: .mp4, quality: 480, url: "mp4-480"),
    ]

    func testBestPicksTopMp4() {
        XCTAssertEqual(pickMp4(streams, maxQuality: nil)?.url, "mp4-1080")
        XCTAssertEqual(pickMp4(streams, maxQuality: "best")?.url, "mp4-1080")
    }

    func testCapFiltersQuality() {
        XCTAssertEqual(pickMp4(streams, maxQuality: "1080")?.url, "mp4-1080")
        XCTAssertEqual(pickMp4(streams, maxQuality: "720")?.url, "mp4-720")
        XCTAssertEqual(pickMp4(streams, maxQuality: "480")?.url, "mp4-480")
    }

    func testHigherCapPicksBestAvailable() {
        XCTAssertEqual(pickMp4(streams, maxQuality: "2160")?.url, "mp4-1080")
    }

    func testFallbackToLastWhenAllAboveCap() {
        let only = [Stream(kind: .mp4, quality: 1080, url: "mp4-1080")]
        XCTAssertEqual(pickMp4(only, maxQuality: "720")?.url, "mp4-1080")
    }

    func testNoMp4MeansNil() {
        let hlsOnly = [Stream(kind: .hls, quality: 720, url: "hls720")]
        XCTAssertNil(pickMp4(hlsOnly, maxQuality: "720"))
        XCTAssertNil(pickMp4([], maxQuality: nil))
    }
}
