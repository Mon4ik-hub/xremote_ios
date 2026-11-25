import XCTest
@testable import AnimeGOCast

final class AppLogTests: XCTestCase {
    func testWriteReadAndClear() {
        let log = AppLog.shared
        log.clear()
        // clear асинхронный — даём очередь отработать
        let expectation = expectation(description: "clear")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        log.log("строка 1")
        log.log("строка 2")
        let drain = expectation(description: "append")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { drain.fulfill() }
        wait(for: [drain], timeout: 2)

        let text = log.text()
        XCTAssertTrue(text.contains("строка 1"))
        XCTAssertTrue(text.contains("строка 2"))
    }
}
