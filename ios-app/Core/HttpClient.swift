import Foundation

/// HTTP-хелпер поверх URLSession: GET/POST с заголовками, JSON-объекты без Codable
/// (ответы animego/Kodik/CVH разной формы).
struct HttpClient {
    /// Браузерный User-Agent обязателен: CDN CVH пишет тип клиента в srcAg,
    /// а плеер AniLabX ходит как Chrome; animego тоже отдаёт разметку под браузер.
    static let browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private let session: URLSession

    init(session: URLSession = HttpClient.makeSession()) {
        self.session = session
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }

    func getText(_ url: String, headers: [String: String]) async throws -> String {
        String(decoding: try await get(url, headers: headers), as: UTF8.self)
    }

    func getJson(_ url: String, headers: [String: String]) async throws -> [String: Any] {
        try await decodeObject(get(url, headers: headers), url: url)
    }

    func postForm(_ url: String, form: [String: String], headers: [String: String]) async throws -> [String: Any] {
        let body = FormData.encode(form)
        return try await decodeObject(request("POST", url, headers: headers, body: body), url: url)
    }

    func get(_ url: String, headers: [String: String]) async throws -> Data {
        try await request("GET", url, headers: headers, body: nil)
    }

    private func request(_ method: String, _ url: String, headers: [String: String], body: Data?) async throws -> Data {
        guard let urlObject = URL(string: url) else {
            throw AppError.network("Плохой адрес: \(url)")
        }
        var request = URLRequest(url: urlObject)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.network("Не HTTP-ответ: \(url)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError.network("\(method) \(url) → HTTP \(http.statusCode)")
        }
        return data
    }

    private func decodeObject(_ data: Data, url: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw AppError.network("Ответ не JSON-объект: \(url)")
        }
        return dict
    }
}

/// Сериализация application/x-www-form-urlencoded — как URLSearchParams в JS.
enum FormData {
    static func encode(_ form: [String: String]) -> Data {
        let parts = form.sorted { $0.key < $1.key }
            .map { encodeComponent($0.key) + "=" + encodeComponent($0.value) }
        return Data(parts.joined(separator: "&").utf8)
    }

    static func encodeComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }
}
