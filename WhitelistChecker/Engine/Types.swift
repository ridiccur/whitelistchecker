import Foundation

/// Режим проверки.
enum CheckMode: String, CaseIterable, Identifiable {
    case shape = "Шейп"          // throughput: WHITE vs SHAPED
    case block = "Блокировка"    // TCP-handshake: доступен vs BLOCKED
    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .shape: return "скорость по белым спискам"
        case .block: return "полная блокировка по белым спискам"
        }
    }
}

/// Выбор DNS-резолвера, который ИСПОЛЬЗУЕТ ПРИЛОЖЕНИЕ для проверок доменов.
/// (Системный DNS телефона приложение менять не может — это резолвер только для проб.)
enum DNSChoice: Equatable {
    case system               // штатный резолвер телефона (getaddrinfo)
    case server(String)       // конкретный DNS-сервер по IP (UDP/53)

    var label: String {
        switch self {
        case .system: return "Системный"
        case .server(let ip): return ip
        }
    }
    var serverIP: String? {
        if case .server(let ip) = self { return ip }
        return nil
    }
}

/// Известные whitelisted DNS (работают под ограничениями белых списков).
enum KnownDNS {
    static let yandex = "77.88.8.8"
    static let yandexSecondary = "77.88.8.1"
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

/// Результат HTTPS/TLS-пробы — block-сигнал поверх TCP.
/// Ловит блокировку по SNI/DPI: TCP открывается, но TLS-рукопожатие рвут.
enum TLSProbeResult: Equatable {
    case ok(handshakeMs: Double, httpStatus: Int?)  // рукопожатие прошло → доступен
    case reset                                       // сброс/таймаут на handshake → SNI/DPI-блок
    case serverTLS                                   // сервер ответил TLS (алерт/cert) → соединение есть
    case skipped                                     // не делали (IP-цель или TCP не открыт)

    var short: String {
        switch self {
        case .ok(let ms, let st):
            return st != nil ? String(format: "TLS %.0fмс·HTTP %d", ms, st!)
                             : String(format: "TLS %.0fмс", ms)
        case .reset:     return "TLS reset"
        case .serverTLS: return "TLS ответ"
        case .skipped:   return "—"
        }
    }
}

/// Результат ICMP-пинга — справочный, на вердикт не влияет
/// (многие хосты/CDN глушат ICMP по политике, будучи доступными).
enum ICMPResult: Equatable {
    case reply(ms: Double)
    case timeout
    var short: String {
        switch self {
        case .reply(let ms): return String(format: "ping %.0fмс", ms)
        case .timeout:       return "ping —"
        }
    }
}

/// Итоговая классификация цели.
enum Verdict: String {
    case white        = "WHITE"        // полная скорость — в белом списке
    case shaped       = "SHAPED"       // придушено по полосе
    case reachable    = "ДОСТУПЕН"     // TCP открыт (режим блокировки: не заблокирован)
    case blocked      = "BLOCKED"      // соединение не устанавливается
    case inconclusive = "INCONCLUSIVE" // мало данных / DNS
    case pending      = "…"

    var emoji: String {
        switch self {
        case .white, .reachable: return "🟢"
        case .shaped: return "🟡"
        case .blocked: return "⛔"
        case .inconclusive: return "⚪"
        case .pending: return "⏳"
        }
    }
}

/// Полный результат проверки одной цели — наблюдаемый объект для UI.
final class ProbeResult: ObservableObject, Identifiable {
    let id = UUID()
    let target: Target
    @Published var resolvedIP: String?   // для доменов — найденный IP
    @Published var tcp: TCPResult?
    @Published var tls: TLSProbeResult?  // HTTPS/TLS-проба (SNI/DPI-блок)
    @Published var icmp: ICMPResult?     // ICMP-пинг (справочно)
    @Published var speedBps: Double?
    var speedTrustworthy = false         // можно ли судить о шейпе по speedBps
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

/// Статус системного DNS.
enum DNSStatus: Equatable {
    case unknown
    case checking
    case ok(via: String)        // резолвит, через какой сервер
    case failed                 // системный DNS не отвечает
}
