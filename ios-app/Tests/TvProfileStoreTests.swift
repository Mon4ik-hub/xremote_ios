import XCTest
@testable import AnimeGOCast

final class TvProfileStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "tvprofile-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultSingleProfile() {
        let store = TvProfileStore(defaults: makeDefaults())
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "Телевизор")
        XCTAssertEqual(store.profiles[0].host, "192.168.1.140")
        XCTAssertEqual(store.profiles[0].port, 31337)
        XCTAssertEqual(store.lastUsed?.id, store.profiles[0].id)
    }

    func testSaveAndReloadFromUserDefaults() {
        let defaults = makeDefaults()
        let store = TvProfileStore(defaults: defaults)
        store.add(TvProfile(name: "Гостиная", host: "192.168.1.50", port: 31338))

        let reloaded = TvProfileStore(defaults: defaults) // тот же UserDefaults
        XCTAssertEqual(reloaded.profiles.count, 2)
        XCTAssertTrue(reloaded.profiles.contains { $0.name == "Гостиная" && $0.host == "192.168.1.50" && $0.port == 31338 })
    }

    func testAddressValidation() {
        XCTAssertNotNil(TvProfileStore.validatedAddress(host: "192.168.1.140", port: "31337"))
        XCTAssertEqual(TvProfileStore.validatedAddress(host: " 192.168.1.140 ", port: " 31337 ")?.host, "192.168.1.140")
        XCTAssertEqual(TvProfileStore.validatedAddress(host: "http://192.168.1.140/", port: "31337")?.host, "192.168.1.140")
        XCTAssertNil(TvProfileStore.validatedAddress(host: "", port: "31337"))
        XCTAssertNil(TvProfileStore.validatedAddress(host: "два слова", port: "31337"))
        XCTAssertNil(TvProfileStore.validatedAddress(host: "192.168.1.140:31337", port: "31337")) // порт — отдельное поле
        XCTAssertNil(TvProfileStore.validatedAddress(host: "192.168.1.140", port: "0"))
        XCTAssertNil(TvProfileStore.validatedAddress(host: "192.168.1.140", port: "70000"))
        XCTAssertNil(TvProfileStore.validatedAddress(host: "192.168.1.140", port: "abc"))
    }

    func testMarkUsedBubblesLastUsedToTop() {
        let store = TvProfileStore(defaults: makeDefaults())
        let first = store.profiles[0]
        let second = TvProfile(name: "Второй", host: "10.0.0.2", port: 31337)
        store.add(second)

        store.markUsed(id: second.id) // отправка второму поднимает его наверх
        XCTAssertEqual(store.profiles.map { $0.id }, [second.id, first.id])
        XCTAssertEqual(store.lastUsed?.id, second.id)

        store.markUsed(id: first.id) // и наоборот
        XCTAssertEqual(store.profiles.map { $0.id }, [first.id, second.id])
    }

    func testRemoveLastUsedPromotesNext() {
        let store = TvProfileStore(defaults: makeDefaults())
        let stay = store.profiles[0]
        let removed = TvProfile(name: "Удаляемый", host: "10.0.0.3", port: 31337)
        store.add(removed)
        store.markUsed(id: removed.id) // удалаемый стал последним использованным

        store.remove(id: removed.id)
        XCTAssertEqual(store.profiles.first?.id, stay.id) // «последним» стал другой
        XCTAssertEqual(store.lastUsed?.id, stay.id)
    }

    func testRemoveKeepsOrderOfRest() {
        let store = TvProfileStore(defaults: makeDefaults())
        let a = store.profiles[0]
        let b = TvProfile(name: "B", host: "10.0.0.2", port: 31337)
        let c = TvProfile(name: "C", host: "10.0.0.3", port: 31337)
        store.add(b)
        store.add(c)

        store.remove(id: b.id)
        XCTAssertEqual(store.profiles.map { $0.id }, [a.id, c.id])
    }

    func testUpdateKeepsPosition() {
        let store = TvProfileStore(defaults: makeDefaults())
        let a = store.profiles[0]
        var b = TvProfile(name: "B", host: "10.0.0.2", port: 31337)
        store.add(b)

        b.name = "Переименованный"
        b.port = 32000
        store.update(b)
        XCTAssertEqual(store.profiles.map { $0.id }, [a.id, b.id])
        XCTAssertEqual(store.profiles[1].name, "Переименованный")
        XCTAssertEqual(store.profiles[1].port, 32000)
    }
}
