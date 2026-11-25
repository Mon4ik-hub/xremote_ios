import Foundation

/// Ошибка с готовым русским текстом для показа пользователю.
enum AppError: LocalizedError {
    case network(String)
    case parse(String)
    case cast(String)

    var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .parse(let message): return message
        case .cast(let message): return message
        }
    }

    /// Человекочитаемый текст любой ошибки (и для панели, и для приложения).
    static func humanText(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return error.localizedDescription
    }
}
