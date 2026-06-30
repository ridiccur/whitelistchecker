import Foundation
import Network

/// Block-сигнал поверх TCP: проходит ли TLS-рукопожатие к host:443.
/// Цель — поймать блокировку по SNI/DPI, когда TCP открывается, но рукопожатие
/// рвут (ECONNRESET / таймаут на ClientHello). Это класс блокировок, который
/// голая TCP-проба пропускает (handshake к :443 успешен → ложно «доступен»).
///
/// .ready  → TLS установлен (сертификат провалидирован) → доступен;
/// .tls    → сервер ответил TLS-ошибкой/алертом (cert mismatch и т.п.) — соединение
///           всё равно есть, это не сетевой блок → доступен;
/// reset/таймаут на handshake → SNI/DPI-блок.
/// После .ready шлём лёгкий GET, чтобы добрать HTTP-статус (справочно в detail).
enum HTTPSProbe {
    static func probe(ip: String,
                      serverName: String,
                      port: UInt16 = 443,
                      timeout: TimeInterval = 5.0) async -> TLSProbeResult {

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        let params = NWParameters(tls: tls)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .skipped }
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: params)
        let start = DispatchTime.now()
        let done = OnceFlag()
        let status = StatusBox()

        return await withCheckedContinuation { (cont: CheckedContinuation<TLSProbeResult, Never>) in

            func finishOK() {
                if done.resolveOnce() {
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    conn.cancel()
                    cont.resume(returning: .ok(handshakeMs: ms, httpStatus: status.code))
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // TLS установлен — это уже «доступен». GET добирает HTTP-статус.
                    let req = "GET / HTTP/1.1\r\nHost: \(serverName)\r\nUser-Agent: WhitelistChecker/1.0\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                    conn.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, _, _ in
                        if let data, let code = Self.httpStatus(data) { status.code = code }
                        finishOK()
                    }
                    // если HTTP-ответ не пришёл за 2с — всё равно доступен (TLS прошёл)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { finishOK() }
                case .failed(let err):
                    if done.resolveOnce() { conn.cancel(); cont.resume(returning: Self.classify(err)) }
                case .waiting(let err):
                    // отказ/недоступность/сброс видны сразу — это блок; иначе ждём timeout
                    if case .posix(let code) = err,
                       code == .ECONNREFUSED || code == .EHOSTUNREACH ||
                       code == .ENETUNREACH || code == .ECONNRESET {
                        if done.resolveOnce() { conn.cancel(); cont.resume(returning: .reset) }
                    }
                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if done.resolveOnce() { conn.cancel(); cont.resume(returning: .reset) }
            }
        }
    }

    private static func classify(_ err: NWError) -> TLSProbeResult {
        switch err {
        case .tls:    return .serverTLS   // сервер участвовал в TLS → соединение есть
        case .posix:  return .reset       // сброс/недоступность на handshake → блок
        default:      return .reset
        }
    }

    /// Парс первой строки HTTP-ответа: "HTTP/1.1 200 OK" → 200.
    private static func httpStatus(_ data: Data) -> Int? {
        guard let r = data.range(of: Data("\r\n".utf8)),
              let line = String(data: data.subdata(in: data.startIndex..<r.lowerBound), encoding: .utf8)
        else { return nil }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }
}

/// Потокобезопасный «однократный резолв» континуации.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func resolveOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true; return true
    }
}

/// HTTP-статус из ответа (доступ под защитой OnceFlag — гонок нет).
private final class StatusBox: @unchecked Sendable {
    var code: Int?
}
