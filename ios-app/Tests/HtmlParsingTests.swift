import XCTest
@testable import AnimeGOCast

final class HtmlParsingTests: XCTestCase {
    func testAnimeMetaParsesIdAndTitle() throws {
        let meta = try Html.animeMeta(from: Fixtures.animePage)
        XCTAssertEqual(meta.animeId, "3592")
        XCTAssertEqual(meta.title, "Тайная битва за престол сильнейшего принца-дуралея")
    }

    func testAnimeMetaThrowsWithoutPlayer() {
        XCTAssertThrowsError(try Html.animeMeta(from: "<html><h1>просто страница</h1></html>"))
    }

    func testEpisodesParsedInOrder() {
        let episodes = Html.episodes(from: Fixtures.episodesHtml)
        XCTAssertEqual(episodes.map { $0.number }, ["1", "2", "3"])
        XCTAssertEqual(episodes.map { $0.id }, ["100001", "100002", "100003"])
    }

    func testEpisodesEmptyOnForeignMarkup() {
        XCTAssertTrue(Html.episodes(from: Fixtures.emptyHtml).isEmpty)
    }

    func testProvidersKeepOnlyCvhAndKodik() {
        let providers = Html.providers(from: Fixtures.providersHtml)
        XCTAssertEqual(providers.map { $0.key }, ["cvh", "kodik"])
        XCTAssertEqual(providers.map { $0.dub }, ["Dream Cast", "AniLiberty"])
        XCTAssertEqual(providers[0].url, "https://s3.cdnvideohub.com/public/cdn-iframe/123/Dream Cast/1/1?scene=1")
        XCTAssertEqual(providers[1].url, "https://kodik.info/find-player?shikimori=1&bad=false")
    }

    func testUnescapeHtml() {
        XCTAssertEqual(Html.unescapeHtml("a&quot;b&amp;&#x5B;c&#39;d&nbsp;"), "a\"b&[c'd ")
        XCTAssertEqual(Html.unescapeHtml("нет сущностей"), "нет сущностей")
        XCTAssertEqual(Html.unescapeHtml("&unknown; остаётся"), "&unknown; остаётся")
    }
}
