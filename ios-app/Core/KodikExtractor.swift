import Foundation

/// Kodik: страница плеера -> urlParams и данные видео -> адрес эндпоинта из
/// atob() в js-бандле -> POST с одноразовыми подписями -> base64 + шифр Цезаря
/// -> прямые ссылки. Порт kodikExtract / decodeKodikUrl / caesarShift из extractors.js.
enum KodikExtractor {
    static let referer = "https://animego.org/"

    private static let urlParamsSingle = Regex(#"urlParams\s*=\s*'(\{.*?\})'"#, dotMatchesLineSeparators: true)
    private static let urlParamsDouble = Regex(#"urlParams\s*=\s*"(\{.*?\})""#, dotMatchesLineSeparators: true)
    private static let videoField = Regex(#"\.(type|hash|id)\s*=\s*['"]([^'"]+)['"]"#)
    private static let playerScript = Regex(#"["'](/assets/js/app\.player[^"']+\.js)["']"#)
    private static let anyScript = Regex(#"<script[^>]+src=["'](/assets/js/[^"']+\.js)["']"#)
    private static let ajaxEndpoint = Regex(#"url:\s*atob\(["']([^"']+)["']\)"#)

    private static let manifestSuffix = ":hls:manifest.m3u8"

    static func extract(_ http: HttpClient, embedUrl rawUrl: String) async throws -> [Stream] {
        let url = forceHttps(rawUrl)
        let page = try await http.getText(url, headers: [
            "Referer": referer,
            "User-Agent": HttpClient.browserUA,
        ])

        let params = try parseUrlParams(page)
        let video = try parseVideoData(page)
        let scriptPath = try findScriptPath(page)

        let origin = originOf(url)
        let script = try await http.getText(origin + scriptPath, headers: [
            "Referer": url,
            "User-Agent": HttpClient.browserUA,
        ])
        let postPath = try endpoint(fromScript: script)
        guard postPath.hasPrefix("/") else {
            throw AppError.parse("Адрес эндпоинта Kodik неожиданный: \(postPath)")
        }

        // ref обязателен и должен быть раскодирован — пустой даёт 500
        let rawRef = params["ref"] ?? ""
        let form: [String: String] = [
            "hash": video["hash"] ?? "",
            "id": video["id"] ?? "",
            "type": video["type"] ?? "",
            "d": params["d"] ?? "",
            "d_sign": params["d_sign"] ?? "",
            "pd": params["pd"] ?? "",
            "pd_sign": params["pd_sign"] ?? "",
            "ref": rawRef.removingPercentEncoding ?? rawRef,
            "ref_sign": params["ref_sign"] ?? "",
            "bad_user": "true",
            "cdn_is_working": "true",
        ]
        let data = try await http.postForm(origin + postPath, form: form, headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": url,
            "Origin": origin,
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "User-Agent": HttpClient.browserUA,
        ])
        return try streams(fromResponse: data)
    }

    // MARK: - Разбор страницы плеера

    private static func parseUrlParams(_ page: String) throws -> [String: String] {
        guard let raw = urlParamsSingle.firstGroup(in: page) ?? urlParamsDouble.firstGroup(in: page) else {
            throw AppError.parse("На странице Kodik нет urlParams — разметка сменилась")
        }
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AppError.parse("Не разобрал urlParams на странице Kodik")
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            result[key] = CvhExtractor.stringValue(value)
        }
        return result
    }

    private static func parseVideoData(_ page: String) throws -> [String: String] {
        var video: [String: String] = [:]
        for match in videoField.allMatches(in: page) {
            guard let key = Regex.group(match, page, 1),
                  let value = Regex.group(match, page, 2) else { continue }
            if video[key] == nil { video[key] = value }
        }
        for key in ["type", "hash", "id"] where video[key] == nil {
            throw AppError.parse("На странице Kodik нет данных видео (\(key))")
        }
        return video
    }

    private static func findScriptPath(_ page: String) throws -> String {
        if let path = playerScript.firstGroup(in: page) { return path }
        if let path = anyScript.firstGroup(in: page) { return path }
        throw AppError.parse("На странице Kodik не найден js-бандл плеера")
    }

    private static func originOf(_ url: String) -> String {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme, let host = components.host else {
            return url
        }
        var origin = "\(scheme)://\(host)"
        if let port = components.port, port != 80, port != 443 {
            origin += ":\(port)"
        }
        return origin
    }

    private static func endpoint(fromScript script: String) throws -> String {
        guard let encoded = ajaxEndpoint.firstGroup(in: script) else {
            throw AppError.parse("В бандле Kodik нет atob() с адресом эндпоинта")
        }
        return try b64Decode(encoded)
    }

    // MARK: - Ссылки из ответа

    private static func streams(fromResponse data: [String: Any]) throws -> [Stream] {
        if let error = data["error"] as? String {
            throw AppError.parse("Kodik вернул ошибку: \(error)")
        }
        let links = data["links"] as? [String: Any] ?? [:]
        guard !links.isEmpty else { throw AppError.parse("Kodik не вернул ссылок") }

        var result: [Stream] = []
        var knownShift: Int?
        // ключи качества по возрастанию (как в JS: (a|0)-(b|0))
        for qualityKey in links.keys.sorted(by: { numeric($0) < numeric($1) }) {
            guard let variants = links[qualityKey] as? [[String: Any]],
                  let variant = variants.first,
                  let src = variant["src"] as? String else { continue }
            var link: String
            if src.contains(manifestSuffix) || src.hasPrefix("http:") || src.hasPrefix("https:") || src.hasPrefix("//") {
                link = forceHttps(src)
            } else {
                let decoded = try decodeKodikUrl(src, knownShift: knownShift)
                knownShift = decoded.shift
                link = forceHttps(decoded.link)
            }
            let quality = numeric(qualityKey)
            result.append(Stream(kind: .hls, quality: quality, url: link))
            if link.hasSuffix(manifestSuffix) {
                result.append(Stream(kind: .mp4, quality: quality, url: String(link.dropLast(manifestSuffix.count))))
            }
        }
        guard !result.isEmpty else { throw AppError.parse("Kodik вернул пустой список ссылок") }
        result.sort { lhs, rhs in
            if lhs.quality ?? 0 != rhs.quality ?? 0 { return lhs.quality ?? 0 > rhs.quality ?? 0 }
            return lhs.kind == .mp4 && rhs.kind != .mp4
        }
        return result
    }

    private static func numeric(_ key: String) -> Int { Int(key) ?? 0 }

    // MARK: - Раскодирование ссылок

    static func forceHttps(_ url: String) -> String {
        url.hasPrefix("//") ? "https:" + url : url
    }

    /// base64 с дописыванием паддинга — как atob в JS.
    static func b64Decode(_ value: String) throws -> String {
        let padded = value + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else {
            throw AppError.parse("Не удалось декодировать base64")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Шифр Цезаря по латинице с сохранением регистра (как в anime-dl-core).
    static func caesarShift(_ text: String, _ shift: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var out = ""
        for character in text {
            let upper = String(character).uppercased()
            if upper.count == 1, let index = alphabet.firstIndex(of: Character(upper)) {
                let shifted = alphabet[(index + shift) % 26]
                out += character.isLowercase ? String(shifted).lowercased() : String(shifted)
            } else {
                out += String(character)
            }
        }
        return out
    }

    /// base64 + цезарь; сдвиг брутфорсится, удачный возвращается для кэша.
    static func decodeKodikUrl(_ value: String, knownShift: Int? = nil) throws -> (link: String, shift: Int) {
        var shifts: [Int] = knownShift.map { [$0] } ?? []
        shifts.append(contentsOf: Array(0...25))
        for shift in shifts {
            if let decoded = try? b64Decode(caesarShift(value, shift)),
               decoded.hasPrefix("//") || decoded.hasPrefix("http") {
                return (decoded, shift)
            }
        }
        throw AppError.parse("Не удалось расшифровать ссылку Kodik (шифр, похоже, сменился)")
    }
}
