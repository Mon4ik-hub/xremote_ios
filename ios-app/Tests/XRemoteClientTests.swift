import XCTest
import Network
@testable import AnimeGOCast

/// XRemote-клиент против mock-сервера в том же процессе (NWListener на 127.0.0.1):
/// обычный ответ, молчание сервера (таймаут), запросы по очереди.
final class XRemoteClientTests: XCTestCase {
    private final class MockServer {
        let listener: NWListener
        private let queue = DispatchQueue(label: "test.mockserver")
        private let lock = NSLock()
        private var commandsStorage: [String] = []
        /// Возвращает ответ на команду по её порядковому номеру; nil — молчать.
        var responder: ((String, Int) -> String?)?

        var commands: [String] {
            lock.lock(); defer { lock.unlock() }
            return commandsStorage
        }

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
        }

        @discardableResult
        func start() throws -> Int {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "mock-сервер не поднялся")
            return Int(listener.port?.rawValue ?? 0)
        }

        func stop() {
            listener.cancel()
        }

        private func accept(_ connection: NWConnection) {
            connection.start(queue: queue)
            readLoop(connection, buffer: Data())
        }

        private func readLoop(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
                guard let self else { return }
                var buffer = buffer
                if let content, !content.isEmpty { buffer.append(content) }
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.lock.lock()
                    let index = self.commandsStorage.count
                    self.commandsStorage.append(line)
                    self.lock.unlock()
                    if let reply = self.responder?(line, index) {
                        connection.send(content: Data((reply + "\n").utf8), completion: .contentProcessed { _ in })
                    }
                    return // одна команда — одно соединение, как настоящий сервер
                }
                if error == nil, !(isComplete && (content == nil || content!.isEmpty)) {
                    self.readLoop(connection, buffer: buffer)
                }
            }
        }
    }

    private func payload(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    func testNormalExchange() async throws {
        let server = try MockServer()
        let port = try server.start()
        defer { server.stop() }
        server.responder = { _, _ in "{\"API_VERSION\":10,\"RESPONSE\":\"ALIVE\"}" }

        let client = try XRemoteClient(host: "127.0.0.1", port: port, timeout: 5)
        let message = payload(try CastMessage.ping())
        let response = try await client.send(message)

        XCTAssertEqual(response.response, "ALIVE")
        XCTAssertEqual(server.commands, [message.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    func testSilenceTimesOut() async throws {
        let server = try MockServer()
        let port = try server.start()
        defer { server.stop() }
        server.responder = { _, _ in nil } // сервер молчит — на неизвестную команду так и бывает

        let client = try XRemoteClient(host: "127.0.0.1", port: port, timeout: 1)
        do {
            _ = try await client.send(payload(try CastMessage.ping()))
            XCTFail("ожидали таймаут")
        } catch let error as XRemoteError {
            guard case .timeout = error else {
                XCTFail("не та ошибка: \(error)")
                return
            }
        }
    }

    func testSequentialRequestsUseSeparateConnections() async throws {
        let server = try MockServer()
        let port = try server.start()
        defer { server.stop() }
        server.responder = { _, index in "{\"RESPONSE\":\"\(index == 0 ? "ALIVE" : "COMMAND_SUCCESS")\"}" }

        let client = try XRemoteClient(host: "127.0.0.1", port: port, timeout: 5)
        let first = try await client.send(payload(try CastMessage.ping()))
        XCTAssertEqual(first.response, "ALIVE")
        let second = try await client.send(payload(try CastMessage.getPlayInfo()))
        XCTAssertEqual(second.response, "COMMAND_SUCCESS")

        XCTAssertEqual(server.commands.count, 2) // строго по очереди, обе дошли
    }

    func testBadAddressRejected() {
        XCTAssertThrowsError(try XRemoteClient(host: "", port: 31337))
        XCTAssertThrowsError(try XRemoteClient(host: " ", port: 31337))
        XCTAssertThrowsError(try XRemoteClient(host: "192.168.1.140", port: 0))
        XCTAssertThrowsError(try XRemoteClient(host: "192.168.1.140", port: 70000))
        XCTAssertThrowsError(try XRemoteClient(host: "192.168.1.140:31337", port: 31337)) // порт передаётся отдельно
    }
}
