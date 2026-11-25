import XCTest
@testable import AnimeGOCast

final class HistoryStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "history-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testEmptyByDefault() {
        let store = HistoryStore(defaults: makeDefaults())
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testUpsertAddsNewestFirst() {
        let store = HistoryStore(defaults: makeDefaults())
        store.upsert(url: "u1", title: "Тайтл 1", episodeNumber: "3")
        store.upsert(url: "u2", title: "Тайтл 2", episodeNumber: "1")
        XCTAssertEqual(store.entries.map { $0.url }, ["u2", "u1"])
        XCTAssertEqual(store.entries[0].title, "Тайтл 2")
    }

    func testUpsertUpdatesExistingEntry() {
        let store = HistoryStore(defaults: makeDefaults())
        store.upsert(url: "u1", title: "Тайтл", episodeNumber: "3")
        store.upsert(url: "u2", title: "Другой", episodeNumber: "1")
        store.upsert(url: "u1", title: "Тайтл", episodeNumber: "4") // продолжили просмотр
        XCTAssertEqual(store.entries.count, 2) // один элемент на тайтл
        let entry = store.entries.first { $0.url == "u1" }
        XCTAssertEqual(entry?.episodeNumber, "4")
    }

    func testPersistsAcrossInstancesAndSorts() {
        let defaults = makeDefaults()
        let store = HistoryStore(defaults: defaults)
        store.upsert(url: "u1", title: "A", episodeNumber: "1")

        let reloaded = HistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].title, "A")
    }

    func testRemove() {
        let store = HistoryStore(defaults: makeDefaults())
        store.upsert(url: "u1", title: "A", episodeNumber: "1")
        store.remove(store.entries[0])
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testHandoffRoundTrip() throws {
        let payload = HistoryHandoff.Payload(
            url: "https://animego.me/anime/x-1",
            title: "Тайтл «в кавычках» & символы",
            episodeNumber: "12",
            episodeId: "100500",
            tvName: "Гостиная",
            tvHost: "192.168.1.50",
            tvPort: 31338,
            playerKey: "kodik",
            dub: "AniLiberty"
        )
        let url = try XCTUnwrap(HistoryHandoff.makeURL(payload))
        XCTAssertEqual(url.scheme, "animegocast")

        let parsed = try XCTUnwrap(HistoryHandoff.parse(url))
        XCTAssertEqual(parsed.url, payload.url)
        XCTAssertEqual(parsed.title, payload.title)
        XCTAssertEqual(parsed.episodeNumber, "12")
        XCTAssertEqual(parsed.episodeId, "100500")
        XCTAssertEqual(parsed.tvName, "Гостиная")
        XCTAssertEqual(parsed.tvHost, "192.168.1.50")
        XCTAssertEqual(parsed.tvPort, 31338)
        XCTAssertEqual(parsed.playerKey, "kodik")
        XCTAssertEqual(parsed.dub, "AniLiberty")
    }

    func testHandoffWithoutTVFields() throws {
        let payload = HistoryHandoff.Payload(
            url: "https://animego.me/anime/x-1",
            title: "Тайтл",
            episodeNumber: "1",
            episodeId: "1",
            tvName: nil,
            tvHost: nil,
            tvPort: nil,
            playerKey: nil,
            dub: nil
        )
        let url = try XCTUnwrap(HistoryHandoff.makeURL(payload))
        let parsed = try XCTUnwrap(HistoryHandoff.parse(url))
        XCTAssertNil(parsed.tvName)
        XCTAssertNil(parsed.tvPort)
        XCTAssertNil(parsed.playerKey)
    }

    func testHandoffRejectsForeignURL() {
        XCTAssertNil(HistoryHandoff.parse(URL(string: "https://animego.me/anime/x")!))
        XCTAssertNil(HistoryHandoff.parse(URL(string: "animex://resume?url=1")!))
    }

    func testPasteboardRoundTrip() throws {
        let payload = HistoryHandoff.Payload(
            url: "https://animego.me/anime/x-1",
            title: "Тайтл",
            episodeNumber: "5",
            episodeId: "100500",
            tvName: "Телевизор",
            tvHost: "192.168.1.140",
            tvPort: 31337,
            playerKey: "kodik",
            dub: "Дубляж"
        )
        HistoryPasteboard.write(payload)
        let read = try XCTUnwrap(HistoryPasteboard.readPayload())
        XCTAssertEqual(read.url, payload.url)
        XCTAssertEqual(read.title, payload.title)
        XCTAssertEqual(read.episodeNumber, "5")
        XCTAssertEqual(read.tvPort, 31337)
        XCTAssertEqual(read.playerKey, "kodik")

        HistoryPasteboard.clear()
        XCTAssertNil(HistoryPasteboard.readPayload()) // потребили — больше не импортируем
    }

    func testPasteboardIgnoresForeignContent() {
        UIPasteboard.general.string = "какой-то скопированный текст"
        XCTAssertNil(HistoryPasteboard.readPayload())
        UIPasteboard.general.string = ""
    }
}
