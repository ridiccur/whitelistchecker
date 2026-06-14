import Foundation
import Network

/// Block-сигнал: одна попытка TCP-handshake к host:port.
/// Различает OPEN / RST / DROP по состояниям NWConnection.
/// Форсинг канала через NWParameters.requiredInterfaceType.
enum TCPProbe {
    /// timeout — сколько ждать перехода в .ready прежде чем счесть DROP.
    static func probe(host: String,
                      port: UInt16 = 443,
                      channel: Channel,
                      timeout: TimeInterval = 4.0) async -> TCPResult {

        let params = NWParameters.tcp
        if let iface = channel.requiredInterface {
            params.requiredInterfaceType = iface
        }
        // не хотим, чтобы система молча увела нас на другой путь
        params.prohibitExpensivePaths = false

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return .error("bad port")
        }
        let conn = NWConnection(host: nwHost, port: nwPort, using: params)

        let start = DispatchTime.now()

        return await withCheckedContinuation { (cont: CheckedContinuation<TCPResult, Never>) in
            let done = Resolved()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    if done.resolveOnce() { conn.cancel(); cont.resume(returning: .open(connectMs: ms)) }
                case .failed(let err):
                    let r = classify(err)
                    if done.resolveOnce() { conn.cancel(); cont.resume(returning: r) }
                case .waiting(let err):
                    // .waiting = путь пока недоступен / соединение не идёт.
                    // Для cellular при активном Wi-Fi это нормально первые мгновения,
                    // поэтому НЕ резолвим сразу — пусть отработает timeout ниже.
                    // Но явный refused/unreachable в .waiting — это сигнал.
                    if case .posix(let code) = err, code == .ECONNREFUSED {
                        if done.resolveOnce() { conn.cancel(); cont.resume(returning: .rst) }
                    }
                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .userInitiated))

            // таймаут → DROP (пакеты в чёрную дыру)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if done.resolveOnce() { conn.cancel(); cont.resume(returning: .drop) }
            }
        }
    }

    private static func classify(_ err: NWError) -> TCPResult {
        switch err {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:               return .rst
            case .EHOSTUNREACH, .ENETUNREACH: return .rst
            case .ETIMEDOUT:                  return .drop
            default:                          return .error("posix \(code.rawValue)")
            }
        case .dns:
            return .dnsFail
        default:
            return .error("\(err)")
        }
    }
}

/// Потокобезопасный «однократный резолв» континуации.
private final class Resolved: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func resolveOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true; return true
    }
}
