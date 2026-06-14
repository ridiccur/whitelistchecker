import Foundation
import Network

/// Через какой интерфейс гнать пробы.
enum Channel: String, CaseIterable, Identifiable {
    case cellular = "Сотовый"
    case wifi     = "Wi-Fi"
    case auto     = "Авто"
    var id: String { rawValue }

    var requiredInterface: NWInterface.InterfaceType? {
        switch self {
        case .cellular: return .cellular
        case .wifi:     return .wifi
        case .auto:     return nil
        }
    }
}

/// Результат TCP-handshake (block-сигнал).
enum TCPResult: Equatable {
    case open(connectMs: Double)
    case rst            // активный отказ — refused/unreachable
    case drop           // таймаут — пакеты в чёрную дыру (типичная IP-блокировка)
    case dnsFail
    case error(String)

    var short: String {
        switch self {
        case .open(let ms): return String(format: "OPEN %.0fms", ms)
        case .rst:          return "RST"
        case .drop:         return "DROP"
        case .dnsFail:      return "DNS"
        case .error(let e): return "ERR \(e)"
        }
    }
}

/// Итоговая классификация цели.
enum Verdict: String {
    case white        = "WHITE"        // полная скорость — в белом списке
    case shaped       = "SHAPED"       // придушено по полосе
    case blocked      = "BLOCKED"      // соединение не устанавливается
    case inconclusive = "INCONCLUSIVE" // мало данных для вывода о шейпе
    case pending      = "…"

    var emoji: String {
        switch self {
        case .white: return "🟢"; case .shaped: return "🟡"
        case .blocked: return "⛔"; case .inconclusive: return "⚪"
        case .pending: return "⏳"
        }
    }
}

/// Полный результат проверки одной цели — наблюдаемый объект для UI.
final class ProbeResult: ObservableObject, Identifiable {
    let id = UUID()
    let target: Target
    @Published var tcp: TCPResult?
    @Published var speedBps: Double?     // байт/с, если мерили throughput
    @Published var verdict: Verdict = .pending
    @Published var detail: String = ""

    init(target: Target) { self.target = target }

    var speedHuman: String {
        guard let b = speedBps else { return "—" }
        if b >= 1_048_576 { return String(format: "%.2f МБ/с", b/1_048_576) }
        if b >= 1024      { return String(format: "%.1f КБ/с", b/1024) }
        return String(format: "%.0f Б/с", b)
    }
}

/// Агрегатный режим сети по набору заведомо-зарубежных целей.
enum NetworkMode: String {
    case blocklist = "Блокировка по белым спискам"
    case shaping   = "Шейп по белым спискам"
    case open      = "Ограничений не видно"
    case unknown   = "Недостаточно данных"
}
