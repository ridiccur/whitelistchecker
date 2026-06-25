import Foundation
import Network

/// Shape-сигнал: качаем данные с host по TLS и считаем байт/секунду.
/// Используем NWConnection (а не URLSession): нужен ручной HTTP GET к произвольному
/// IP с заданным SNI (domain fronting при калибровке) — URLSession так не умеет.
/// Идём через основную сеть телефона (без форса интерфейса).
enum ThroughputProbe {

    struct Result {
        let bytes: Int
        let seconds: Double
        let httpStatus: Int?
        var bps: Double { seconds > 0 ? Double(bytes) / seconds : 0 }
        /// Поток шёл ~весь интервал (окно заполнено) — значит bps = реальный потолок.
        var windowFilled: Bool
        /// Замеру можно верить: либо взяли заметный объём (быстрый канал успел
        /// прокачать ≥1 МБ), либо устойчиво качали почти всё окно (медленный канал).
        /// Если сайт отдал маленькое тело (динамический `/`, не уважает Range) —
        /// false, и классификатор уходит на сетевой вердикт калибровки.
        var trustworthy: Bool { windowFilled || bytes >= 1_000_000 }
    }

    /// host — IP или домен (для TLS SNI), connectHost — куда реально коннектиться
    /// (если задан IP, а SNI берём из host). path — что запросить.
    /// duration — сколько секунд качать. rangeBytes — сколько байт просим через
    /// HTTP Range, чтобы заставить сервер отдать большое тело для замера.
    static func measure(host: String,
                        path: String,
                        port: UInt16 = 443,
                        connectHost: String? = nil,
                        duration: TimeInterval = 10.0,
                        connectTimeout: TimeInterval = 6.0,
                        rangeBytes: Int = 8 * 1024 * 1024) async -> Result {

        let serverName = host
        let dialHost = connectHost ?? host
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        let params = NWParameters(tls: tls)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return Result(bytes: 0, seconds: 0, httpStatus: nil, windowFilled: false)
        }
        let conn = NWConnection(host: NWEndpoint.Host(dialHost), port: nwPort, using: params)

        let state = TransferState()

        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in

            let finish: @Sendable () -> Void = {
                guard state.finishOnce() else { return }
                conn.cancel()
                let secs = state.elapsed()
                let filled = secs >= duration * 0.8
                cont.resume(returning: Result(bytes: state.byteCount,
                                              seconds: secs,
                                              httpStatus: state.httpStatus,
                                              windowFilled: filled))
            }

            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    state.markStart()
                    // Range заставляет CDN/статику отдать большое тело (ответ 206),
                    // иначе на маленьком динамическом `/` нечего мерить.
                    let req = "GET \(path) HTTP/1.1\r\nHost: \(serverName)\r\nUser-Agent: WhitelistChecker/1.0\r\nAccept: */*\r\nRange: bytes=0-\(rangeBytes - 1)\r\nConnection: close\r\n\r\n"
                    conn.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in })
                    receiveLoop(conn, state: state, onEnd: finish)
                case .failed, .cancelled:
                    finish()
                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .userInitiated))

            // connect-timeout: если не дошли до .ready
            DispatchQueue.global().asyncAfter(deadline: .now() + connectTimeout) {
                if !state.didStart { finish() }
            }
            // общий дедлайн замера
            DispatchQueue.global().asyncAfter(deadline: .now() + connectTimeout + duration) {
                finish()
            }
        }
    }

    private static func receiveLoop(_ conn: NWConnection, state: TransferState, onEnd: @escaping () -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, err in
            if let data = data, !data.isEmpty {
                state.append(data)
            }
            if isComplete || err != nil {
                onEnd(); return
            }
            // ограничиваем замер по времени, чтобы не качать гигабайты на белом канале
            if state.elapsed() >= state.hardLimit {
                onEnd(); return
            }
            receiveLoop(conn, state: state, onEnd: onEnd)
        }
    }
}

/// Состояние одной передачи (потокобезопасное — доступ под lock).
private final class TransferState: @unchecked Sendable {
    private let lock = NSLock()
    private var started: DispatchTime?
    private var finished = false
    private var buffer = Data()        // только заголовки, для парсинга статуса
    private var headerParsed = false

    var byteCount = 0
    var httpStatus: Int?
    let hardLimit: TimeInterval = 12.0
    var didStart: Bool { started != nil }

    func markStart() {
        lock.lock(); if started == nil { started = .now() }; lock.unlock()
    }
    func append(_ d: Data) {
        lock.lock()
        byteCount += d.count
        if !headerParsed {
            buffer.append(d.prefix(512))
            if let r = buffer.range(of: Data("\r\n".utf8)),
               let line = String(data: buffer.subdata(in: buffer.startIndex..<r.lowerBound), encoding: .utf8) {
                // "HTTP/1.1 200 OK"
                let parts = line.split(separator: " ")
                if parts.count >= 2 { httpStatus = Int(parts[1]) }
                headerParsed = true
            } else if buffer.count > 512 {
                headerParsed = true
            }
        }
        lock.unlock()
    }
    func elapsed() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let s = started else { return 0 }
        return Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1_000_000_000
    }
    func finishOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true; return true
    }
}
