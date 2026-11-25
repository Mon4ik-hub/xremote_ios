import XCTest
@testable import AnimeGOCast

final class CastMessageTests: XCTestCase {
    private func makeRequest(season: String = "1 сезон") -> CastMessage.PlayRequest {
        CastMessage.PlayRequest(
            contentId: "animego/100001",
            title: "Тайная битва за престол",
            season: season,
            translation: "Dream Cast",
            episode: "1 серия",
            qualityName: "1080p",
            directUrl: "https://cdn.example.com/video.mp4?srcAg=CHROME",
            embedUrl: "https://s3.cdnvideohub.com/cdn-iframe/123/Dream%20Cast/1/1",
            headersForDirect: ["Referer": "https://animego.org/"]
        )
    }

    func testPlayVideoStructure() throws {
        let data = try CastMessage.playVideo(makeRequest())
        XCTAssertEqual(data.last, 0x0A) // JSON заканчивается \n — сервер читает построчно

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        XCTAssertEqual(json["COMMAND"] as? String, "PLAY_VIDEO")
        XCTAssertEqual(json["API_VERSION"] as? Int, 10)
        XCTAssertEqual(json["CLIENT_NAME"] as? String, "iPhone")
        XCTAssertEqual(json["CLIENT_APP_NAME"] as? String, "AnimeGO Cast")
        XCTAssertEqual(json["CLIENT_TYPE"] as? String, "PHONE")
        XCTAssertEqual(json["PLAY_COMMAND"] as? String, "NONE")

        let playData = try XCTUnwrap(json["PLAY_DATA"] as? [String: Any])
        // обязательные непустые поля — без них сервер AniLabX падает
        for key in ["CONTENT_ID", "CONTENT_TITLE", "SEASON", "TRANSLATION", "EPISODE"] {
            let value = try XCTUnwrap(playData[key] as? String, "нет поля \(key)")
            XCTAssertFalse(value.isEmpty, "пустое поле \(key)")
        }
        XCTAssertEqual(playData["CONTENT_ID"] as? String, "animego/100001")
        XCTAssertEqual(playData["SEASON"] as? String, "1 сезон")
        XCTAssertEqual(playData["EPISODE"] as? String, "1 серия")

        let linkItem = try XCTUnwrap(playData["LINK_ITEM"] as? [String: Any])
        let linkParts = try XCTUnwrap(linkItem["LINK_PARTS"] as? [String])
        XCTAssertEqual(linkParts.first, "https://cdn.example.com/video.mp4?srcAg=CHROME") // LINK_PARTS[0] — ссылка

        let parseLink = try XCTUnwrap(playData["PARSE_LINK"] as? [String: Any]) // PARSE_LINK на месте
        XCTAssertEqual(parseLink["ORIGINAL"] as? String, "https://s3.cdnvideohub.com/cdn-iframe/123/Dream%20Cast/1/1")
        XCTAssertEqual(parseLink["DIRECT"] as? String, "https://cdn.example.com/video.mp4?srcAg=CHROME")
        XCTAssertNotNil(parseLink["HEADERS_FOR_DIRECT"] as? [String: String])
    }

    func testPlayVideoRejectsEmptyRequiredFields() {
        XCTAssertThrowsError(try CastMessage.playVideo(makeRequest(season: "")))   // пустой SEASON запрещён
        XCTAssertThrowsError(try CastMessage.playVideo(makeRequest(season: "   ")))

        var blank = makeRequest()
        blank.translation = ""
        XCTAssertThrowsError(try CastMessage.playVideo(blank))

        blank = makeRequest()
        blank.contentId = ""
        XCTAssertThrowsError(try CastMessage.playVideo(blank))

        blank = makeRequest()
        blank.directUrl = ""
        XCTAssertThrowsError(try CastMessage.playVideo(blank))
    }

    func testServiceCommandsStructure() throws {
        for (data, command) in [(try CastMessage.ping(), "PING"),
                                (try CastMessage.getPlayInfo(), "GET_PLAY_INFO"),
                                (try CastMessage.closePlayer(), "CLOSE_PLAYER")] {
            XCTAssertEqual(data.last, 0x0A)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
            XCTAssertEqual(json["COMMAND"] as? String, command)
            XCTAssertEqual(json["API_VERSION"] as? Int, 10)
        }
    }
}
