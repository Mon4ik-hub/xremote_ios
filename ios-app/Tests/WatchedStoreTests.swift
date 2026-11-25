import XCTest
@testable import AnimeGOCast

final class WatchedStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "watched-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testEmptyByDefault() {
        let store = WatchedStore(defaults: makeDefaults())
        XCTAssertFalse(store.isWatched("100001"))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testMarkAndPersistAcrossInstances() {
        let defaults = makeDefaults()
        let store = WatchedStore(defaults: defaults)
        store.markWatched("100001")
        store.markWatched("100002")

        let reloaded = WatchedStore(defaults: defaults)
        XCTAssertTrue(reloaded.isWatched("100001"))
        XCTAssertTrue(reloaded.isWatched("100002"))
        XCTAssertFalse(reloaded.isWatched("100003"))
    }

    func testToggleFlipsMark() {
        let defaults = makeDefaults()
        let store = WatchedStore(defaults: defaults)
        store.markWatched("100001")
        XCTAssertTrue(store.isWatched("100001"))

        store.toggle("100001") // снять пометку
        XCTAssertFalse(store.isWatched("100001"))

        store.toggle("100002") // поставить без play
        XCTAssertTrue(store.isWatched("100002"))
    }
}
