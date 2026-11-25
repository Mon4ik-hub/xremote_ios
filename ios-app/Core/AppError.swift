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
}
