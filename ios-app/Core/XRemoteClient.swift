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

/// Потокобезопасная ячейка для значений из колбэков Network.framework.
private final class Locked<T> {
    private let lock = NSLock()
    private var value: T

    init(_ initial: T) {
        value = initial
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Клиент XRemote — «голый» TCP по правилам AniLabX:
/// одна команда = одно соединение, туда строка JSON + "\n", обратно одна строка
/// JSON, соединение закрывает клиент. Таймаут 5 секунд обязателен: на неизвестную
/// команду сервер вообще не отвечает. Запросы идут строго по очереди — каждый
/// send открывает новое соединение только после завершения предыдущего.
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

    // MARK: - Блокирующие этапы одной команды

    /// Блокирующая реализация на отдельном потоке: за 5-секундным бюджетом проще
    /// гоняться семафором, чем стыковать продолжения Network.framework.
    private func sendBlocking(_ payload: String) throws -> XRemoteResponse {
        let deadline = Date().addingTimeInterval(timeout)
        let connection = try connect(deadline: deadline)
        defer { connection.cancel() }
        try sendText(payload, on: connection, deadline: deadline)
        return try readResponse(on: connection, deadline: deadline)
    }

    private func connect(deadline: Date) throws -> NWConnection {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        let failure = Locked<Error?>(nil)
        connection.stateUpdateHandler = { (state: NWConnection.State) in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                failure.set(XRemoteError.connectionFailed(error.localizedDescription))
                semaphore.signal()
            case .waiting(let error):
                // «нет маршрута» и подобное — считаем ошибкой сразу, не ждём восстановления
                failure.set(XRemoteError.connectionFailed(error.localizedDescription))
                semaphore.signal()
            case .cancelled:
                failure.set(XRemoteError.connectionClosed)
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "ru.mon4ik.animegocast.xremote"))

        guard waitUntil(semaphore, deadline: deadline) else { throw XRemoteError.timeout }
        if let failure = failure.get() {
            if case XRemoteError.connectionClosed = failure, connection.state == .ready {
                // отмена после готовности — нормальное завершение, не ошибка подключения
            } else {
                throw failure
            }
        }
        return connection
    }

    private func sendText(_ payload: String, on connection: NWConnection, deadline: Date) throws {
        var text = payload
        if !text.hasSuffix("\n") {
            text += "\n"
        }
        let semaphore = DispatchSemaphore(value: 0)
        let failure = Locked<Error?>(nil)
        connection.send(content: Data(text.utf8), completion: .contentProcessed { (error: NWError?) in
            if let error {
                failure.set(XRemoteError.connectionFailed(error.localizedDescription))
            }
            semaphore.signal()
        })
        guard waitUntil(semaphore, deadline: deadline) else { throw XRemoteError.timeout }
        if let failure = failure.get() {
            throw failure
        }
    }

    private func readResponse(on connection: NWConnection, deadline: Date) throws -> XRemoteResponse {
        var buffer = Data()
        while true {
            if let response = try takeResponse(from: &buffer) {
                return response
            }
            guard Date() < deadline else { throw XRemoteError.timeout }

            let semaphore = DispatchSemaphore(value: 0)
            let failure = Locked<Error?>(nil)
            let received = Locked<Data?>(nil)
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 65536
            ) { (content: Data?, _: NWConnection.ContentContext?, isComplete: Bool, error: NWError?) in
                received.set(content)
                if let error {
                    failure.set(XRemoteError.connectionFailed(error.localizedDescription))
                } else if isComplete, content?.isEmpty != false {
                    failure.set(XRemoteError.connectionClosed)
                }
                semaphore.signal()
            }
            guard waitUntil(semaphore, deadline: deadline) else { throw XRemoteError.timeout }
            if let failure = failure.get() {
                throw failure
            }
            if let content = received.get(), !content.isEmpty {
                buffer.append(content)
            }
        }
    }

    /// Если в буфере есть строка до "\n" — разбирает её в ответ и срезает из буфера.
    private func takeResponse(from buffer: inout Data) throws -> XRemoteResponse? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let lineData = buffer.subdata(in: buffer.startIndex..<newline)
        let line = String(data: lineData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !line.isEmpty else {
            throw XRemoteError.badResponse("пустая строка")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
            throw XRemoteError.badResponse(String(line.prefix(200)))
        }
        return XRemoteResponse(raw: line, json: object)
    }

    private func waitUntil(_ semaphore: DispatchSemaphore, deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        return semaphore.wait(timeout: .now() + remaining) == .success
    }
}
