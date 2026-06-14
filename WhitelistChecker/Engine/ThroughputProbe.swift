import Foundation
import Network

/// Shape-сигнал: качаем данные с host по TLS и считаем байт/секунду.
/// Используем NWConnection (а не URLSession), чтобы форсировать .cellular
/// даже при активном Wi-Fi — URLSession так не умеет.
enum ThroughputProbe {

    struct Result {
        let bytes: Int
        let seconds: Double
        let httpStatus: Int?
        var bps: Double { seconds > 0 ? Double(bytes) / seconds : 0 }
        /// Поток шёл ~весь интервал (окно заполнено) — значит bps = реальный потолок.
        var windowFilled: Bool
    }

    /// host — домен или IP; path — что запросить; sni — имя для TLS/Host (по умолчанию = host).
    /// duration — сколько секунд качать.
    static func measure(host: String,
                        path: String,
                        port: UInt16 = 443,
                        sni: String? = nil,
                        channel: Channel,
                        duration: TimeInterval = 10.0,
                        connectTimeout: TimeInterval = 6.0) async -> Result {

        let serverName = sni ?? host
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        let params = NWParameters(tls: tls)
        if let iface = channel.requiredInterface {
            params.requiredInterfaceType = iface
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return Result(bytes: 0, seconds: 0, httpStatus: nil, windowFilled: false)
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)

        let state = TransferState()

        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in

            func finish() {
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
                    let req = "GET \(path) HTTP/1.1\r\nHost: \(serverName)\r\nUser-Agent: WhitelistChecker/1.0\r\nAccept: */*\r\nConnection: close\r\n\r\n"
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

/// Состояние одной передачи (потокобезопасное).
private final class TransferState {
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
    func markStartIfNeeded() { markStart() }
    func finishOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true; return true
    }
}
