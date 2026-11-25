import XCTest
@testable import AnimeGOCast

final class AppLogTests: XCTestCase {
    func testWriteReadAndClear() {
        let log = AppLog.shared
        log.clear()
        // clear асинхронный — даём очереди отработать
        let cleared = XCTestExpectation(description: "clear")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cleared.fulfill() }
        wait(for: [cleared], timeout: 2)

        log.log("строка 1")
        log.log("строка 2")
        let appended = XCTestExpectation(description: "append")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { appended.fulfill() }
        wait(for: [appended], timeout: 2)

        let text = log.text()
        XCTAssertTrue(text.contains("строка 1"))
        XCTAssertTrue(text.contains("строка 2"))
    }
}
