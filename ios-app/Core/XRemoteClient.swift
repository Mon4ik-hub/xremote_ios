import Foundation
import Network

struct XRemoteResponse {
    let raw: String
    let json: [String: Any]
    /// Значение поля RESPONSE: "ALIVE", "COMMAND_SUCCESS", "PLAYER_NOT_RUNNING", ...
    var response: String? { json["RESPONSE"] as? String }
}

enum XRemoteError: LocalizedError {
    case badAddress(String)
    case connectionFailed(String)
    case timeout
    case connectionClosed
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .badAddress(let address):
            return "Неверный адрес сервера: \(address) — нужен вида 192.168.1.140:31337"
        case .connectionFailed(let reason):
            return "Не удалось подключиться к телевизору: \(reason)"
        case .timeout:
            return "Сервер не ответил за 5 секунд. Проверьте, что AniLabX запущен и телевизор в той же Wi-Fi-сети."
        case .connectionClosed:
            return "Соединение закрылось, не дождавшись ответа сервера."
        case .badResponse(let text):
            return "Непонятный ответ сервера: \(text)"
        }
    }
}

/// Потокобезопасная ячейка для ошибки из колбэков Network.framework.
private final class LockedError {
    private let lock = NSLock()
    private var value: Error?
    func set(_ newValue: Error) {
        lock.lock(); value = newValue; lock.unlock()
    }
    func get() -> Error? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Клиент XRemote — «голый» TCP по правилам AniLabX:
/// одна команда = одно соединение, туда строка JSON + "\n", обратно одна строка
/// JSON, соединение закрывает клиент. Таймаут 5 секунд обязателен: на неизвестную
/// команду сервер вообще не отвечает. Последовательность вызовов send обеспечивает
/// очередь запросов (каждый send — новое соединение после завершения предыдущего).
final class XRemoteClient {
    let host: String
    let port: UInt16
    let timeout: TimeInterval

    init(host: String, port: Int, timeout: TimeInterval = 5) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedHost.contains(":"),
              (1...65535).contains(port), let portValue = UInt16(exactly: port) else {
            throw XRemoteError.badAddress("\(host):\(port)")
        }
        self.host = trimmedHost
        self.port = portValue
        self.timeout = timeout
    }

    func send(_ payload: String) async throws -> XRemoteResponse {
        let client = self
        return try await Task.detached(priority: .userInitiated) {
            try client.sendBlocking(payload)
        }.value
    }

    /// Блокирующая реализация на отдельном потоке: за 5-секундным бюджетом проще
    /// гоняться семафором, чем стыковать продолжения Network.framework.
    private func sendBlocking(_ payload: String) throws -> XRemoteResponse {
        let deadline = Date().addingTimeInterval(timeout)
        let semaphore = DispatchSemaphore(value: 0)

        let connection = NWConnection(
            to: NWEndpoint.hostPort(name: host, port: NWEndpoint.Port(rawValue: port)!),
            using: .tcp
        )
        defer { connection.cancel() }

        let stateFailure = LockedError()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                stateFailure.set(XRemoteError.connectionFailed(error.localizedDescription))
                semaphore.signal()
            case .waiting(let error):
                // «нет маршрута» и подобное — считаем ошибкой сразу, не ждём восстановления
                stateFailure.set(XRemoteError.connectionFailed(error.localizedDescription))
                semaphore.signal()
            case .cancelled:
                stateFailure.set(XRemoteError.connectionClosed)
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "ru.mon4ik.animegocast.xremote"))

        guard waitUntil(semaphore, deadline: deadline) else { throw XRemoteError.timeout }
        if let failure = stateFailure.get() {
            // соединение уже готово (.ready) — эта ошибка не актуальна
            if case XRemoteError.connectionClosed = failure, connection.state == .ready {} else { throw failure }
        }

        var text = payload
        if !text.hasSuffix("\n") { text += "\n" }
        let sendFailure = LockedError()
        connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
            if let error {
                sendFailure.set(XRemoteError.connectionFailed(error.localizedDescription))
            }
            semaphore.signal()
        })
        guard waitUntil(semaphore, deadline: deadline) else { throw XRemoteError.timeout }
        if let failure = sendFailure.get() { throw failure }

        // читаем одну строку ответа до "\n"
        var buffer = Data()
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else {
                    throw XRemoteError.badResponse("пустая строка")
                }
                guard let object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                    throw XRemoteError.badResponse(String(line.prefix(200)))
                }
                return XRemoteResponse(raw: line, json: object)
            }
            guard Date() < deadline else { throw XRemoteError.timeout }

            let receiveFailure = LockedError()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let error {
                    receiveFailure.set(XRemoteError.connectionFailed(error.localizedDescription))
                } else if isComplete, content?.isEmpty != false {
                    receiveFailure.set(XRemoteError.connectionClosed)
                }
                semaphore.signal()
            }
            guard waitUntil(semaphore, deadline: deadline) else { throw XRemoteError.timeout }
            if let failure = receiveFailure.get() { throw failure }
            if let content, !content.isEmpty {
                buffer.append(content)
            }
        }
    }

    private func waitUntil(_ semaphore: DispatchSemaphore, deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        return semaphore.wait(timeout: .now() + remaining) == .success
    }
}
