import Foundation
import Network

/// Резолвинг доменов для проверок. Умеет:
///  - системный резолвер телефона (getaddrinfo),
///  - конкретный DNS-сервер по UDP/53 (Yandex / оператора и т.п.),
///  - чтение текущих системных DNS-серверов (для отображения),
///  - health-check системного DNS.
enum DNSResolver {

    /// Резолв A-записей выбранным способом. Возвращает IPv4-адреса.
    static func resolveA(_ host: String, via choice: DNSChoice, timeout: TimeInterval = 4.0) async -> [String] {
        if InputParserIsIPv4(host) { return [host] }
        switch choice {
        case .system:           return await resolveSystem(host)
        case .server(let ip):   return await resolveViaServer(host, server: ip, timeout: timeout)
        }
    }

    /// Системный резолвер (getaddrinfo) — блокирующий, уводим в отдельный поток.
    static func resolveSystem(_ host: String) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_INET,
                                     ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var info: UnsafeMutablePointer<addrinfo>?
                let err = getaddrinfo(host, nil, &hints, &info)
                guard err == 0, let first = info else { cont.resume(returning: []); return }
                defer { freeaddrinfo(first) }
                var out: [String] = []
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let cur = p {
                    if let sa = cur.pointee.ai_addr {
                        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                            var addr = sin.pointee.sin_addr
                            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                            out.append(String(cString: buf))
                        }
                    }
                    p = cur.pointee.ai_next
                }
                cont.resume(returning: Array(Set(out)))
            }
        }
    }

    /// Текущие системные DNS-серверы (через libresolv). Для отображения «оператора».
    static func systemServers() -> [String] {
        var buf = [CChar](repeating: 0, count: 256)
        let n = wl_system_dns_servers(&buf, 256)
        guard n > 0 else { return [] }
        return String(cString: buf).split(separator: ",").map(String.init)
    }

    /// DNS жив? Резолвим заведомо-белый домен выбранным резолвером
    /// (системным по умолчанию, либо конкретным сервером — Yandex/оператора).
    static func health(via choice: DNSChoice = .system) async -> Bool {
        !(await resolveA("ya.ru", via: choice)).isEmpty
    }

    // MARK: - DNS-запрос к конкретному серверу по UDP/53

    static func resolveViaServer(_ host: String, server: String, timeout: TimeInterval) async -> [String] {
        guard let query = buildQuery(host) else { return [] }
        guard let port = NWEndpoint.Port(rawValue: 53) else { return [] }
        let conn = NWConnection(host: NWEndpoint.Host(server), port: port, using: .udp)

        return await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let done = OnceFlag()
            func finish(_ ips: [String]) {
                if done.set() { conn.cancel(); cont.resume(returning: ips) }
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    conn.send(content: query, completion: .contentProcessed { _ in })
                    conn.receiveMessage { data, _, _, _ in
                        finish(parseAnswers(data))
                    }
                case .failed, .cancelled:
                    finish([])
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish([]) }
        }
    }

    /// Сборка DNS-запроса A-записи.
    static func buildQuery(_ host: String) -> Data? {
        var d = Data()
        // header: id=0xABCD, flags=0x0100 (RD), qd=1
        d.append(contentsOf: [0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in host.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard bytes.count < 64 else { return nil }
            d.append(UInt8(bytes.count))
            d.append(contentsOf: bytes)
        }
        d.append(0x00)                       // конец QNAME
        d.append(contentsOf: [0x00, 0x01])   // QTYPE = A
        d.append(contentsOf: [0x00, 0x01])   // QCLASS = IN
        return d
    }

    /// Парсинг ответа: достаём все A-записи (TYPE=1, RDLEN=4).
    static func parseAnswers(_ data: Data?) -> [String] {
        guard let data = data, data.count > 12 else { return [] }
        let b = [UInt8](data)
        let qd = Int(b[4]) << 8 | Int(b[5])
        let an = Int(b[6]) << 8 | Int(b[7])
        var i = 12
        // пропускаем вопросы
        for _ in 0..<qd {
            i = skipName(b, i)
            i += 4 // QTYPE+QCLASS
            if i > b.count { return [] }
        }
        var out: [String] = []
        for _ in 0..<an {
            i = skipName(b, i)
            guard i + 10 <= b.count else { break }
            let type = Int(b[i]) << 8 | Int(b[i+1])
            let rdlen = Int(b[i+8]) << 8 | Int(b[i+9])
            i += 10
            guard i + rdlen <= b.count else { break }
            if type == 1 && rdlen == 4 {
                out.append("\(b[i]).\(b[i+1]).\(b[i+2]).\(b[i+3])")
            }
            i += rdlen
        }
        return out
    }

    /// Пропуск доменного имени (с учётом компрессии 0xC0).
    static func skipName(_ b: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < b.count {
            let len = b[i]
            if len == 0 { return i + 1 }
            if len & 0xC0 == 0xC0 { return i + 2 } // указатель компрессии
            i += Int(len) + 1
        }
        return i
    }
}

/// Локальная проверка IPv4 (чтобы не тянуть InputParser в DNS-слой жёстко).
private func InputParserIsIPv4(_ s: String) -> Bool {
    let o = s.split(separator: ".", omittingEmptySubsequences: false)
    guard o.count == 4 else { return false }
    return o.allSatisfy { if let v = Int($0), v >= 0, v <= 255 { return true } else { return false } }
}

/// Однократный флаг для континуации.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
