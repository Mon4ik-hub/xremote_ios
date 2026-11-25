import XCTest
@testable import AnimeGOCast

final class CastPreferencesTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "castprefs-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsAreCvhAndAnyDub() {
        let prefs = CastPreferences(defaults: makeDefaults())
        XCTAssertEqual(prefs.playerKey, "cvh")
        XCTAssertEqual(prefs.dub, "")
    }

    func testSaveAndReload() {
        let defaults = makeDefaults()
        let prefs = CastPreferences(defaults: defaults)
        prefs.playerKey = "kodik"
        prefs.dub = "AniLiberty"

        let reloaded = CastPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.playerKey, "kodik")
        XCTAssertEqual(reloaded.dub, "AniLiberty")
    }
}
