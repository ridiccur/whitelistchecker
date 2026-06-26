import Foundation

/// Оркестратор: ведёт пробы, классифицирует вердикт, считает режим сети.
/// Поддерживает два режима: .shape (throughput) и .block (только TCP).
@MainActor
final class ScanEngine: ObservableObject {
    @Published var results: [ProbeResult] = []
    @Published var calibration: CalibrationSnapshot?
    @Published var mode: NetworkMode = .unknown
    @Published var isRunning = false
    @Published var statusLine = ""

    // DNS
    @Published var dnsStatus: DNSStatus = .unknown
    @Published var systemDNS: [String] = []
    var dnsChoice: DNSChoice = .system

    var checkMode: CheckMode = .shape

    private let tcpConcurrency = 24

    func cancelAll() { isRunning = false }

    /// Прогон режима шейпа: список доменов не нужен — меряем встроенные эталоны
    /// (белый whitelisted сервер против чужих CDN) и судим о сети по ним.
    func runShapeCheck() async {
        isRunning = true
        results = []
        mode = .unknown
        calibration = nil

        await refreshDNS()
        statusLine = "Калибровка канала…"
        calibration = await Calibrator.run()

        computeNetworkMode()
        statusLine = ""
        isRunning = false
    }

    /// Проверка DNS выбранным резолвером (вызывается из UI до/без скана).
    func refreshDNS() async {
        dnsStatus = .checking
        systemDNS = DNSResolver.systemServers()
        let ok = await DNSResolver.health(via: dnsChoice)
        if ok {
            switch dnsChoice {
            case .system:          dnsStatus = .ok(via: systemDNS.first ?? "система")
            case .server(let ip):  dnsStatus = .ok(via: ip)
            }
        } else {
            dnsStatus = .failed
        }
    }

    /// Прогон режима блокировки: TCP-handshake по списку целей.
    func run(targets: [Target]) async {
        guard !targets.isEmpty else { return }
        isRunning = true
        results = targets.map { ProbeResult(target: $0) }
        mode = .unknown
        calibration = nil

        // 1) DNS health + резолвинг доменов выбранным резолвером
        await refreshDNS()
        let domains = results.filter { $0.target.kind == .domain }
        if !domains.isEmpty {
            statusLine = "Резолвинг доменов (\(dnsChoice.label))…"
            for r in domains {
                let ips = await DNSResolver.resolveA(r.target.host, via: dnsChoice)
                r.resolvedIP = ips.first
                if r.resolvedIP == nil { r.tcp = .dnsFail }
            }
        }

        // 2) TCP-пробы для всех целей
        statusLine = "TCP-пробы…"
        await runTCPPool()

        // 3) Классификация
        for r in results { classifyBlock(r) }

        computeNetworkMode()
        statusLine = ""
        isRunning = false
    }

    // MARK: - TCP pool

    private func probeHost(_ r: ProbeResult) -> String? {
        if r.target.kind == .domain { return r.resolvedIP } // домен → только по найденному IP
        return r.target.host
    }

    private func runTCPPool() async {
        let all = results
        // хосты считаем заранее на главном акторе (probeHost @MainActor)
        let hosts: [String?] = all.map { probeHost($0) }
        for i in all.indices where hosts[i] == nil && all[i].tcp == nil {
            all[i].tcp = .dnsFail
        }
        var index = 0
        await withTaskGroup(of: (Int, TCPResult).self) { group in
            var inFlight = 0
            func launch(_ i: Int) {
                guard let host = hosts[i] else { return }   // уже помечено dnsFail
                group.addTask { (i, await TCPProbe.probe(host: host)) }
                inFlight += 1
            }
            while index < all.count && inFlight < tcpConcurrency {
                launch(index); index += 1
            }
            while let (i, res) = await group.next() {
                all[i].tcp = res
                inFlight -= 1
                if index < all.count && isRunning {
                    launch(index); index += 1
                }
            }
        }
    }

    // MARK: - классификация

    private func classifyBlock(_ r: ProbeResult) {
        switch r.tcp {
        case .open(let ms): r.verdict = .reachable; r.detail = String(format: "connect %.0f мс", ms)
        case .rst:          r.verdict = .blocked; r.detail = "RST (refused)"
        case .drop:         r.verdict = .blocked; r.detail = "DROP (таймаут/blackhole)"
        case .dnsFail:      r.verdict = .inconclusive; r.detail = "DNS не резолвится"
        case .error(let e): r.verdict = .inconclusive; r.detail = e
        case .none:         r.verdict = .inconclusive; r.detail = "нет данных"
        }
    }

    // MARK: - режим сети

    private func computeNetworkMode() {
        // Шейп: режим определяется только эталонной калибровкой (белый whitelisted
        // сервер против чужих CDN) — список доменов в этом режиме не участвует.
        if checkMode == .shape {
            if let c = calibration, c.whiteBps > 0, c.foreignBps > 0 {
                mode = c.shaping ? .shaping : .open
            } else {
                mode = .unknown
            }
            return
        }

        // Блокировка: судим по строкам TCP-проб.
        let blocked = results.filter { $0.verdict == .blocked }.count
        let good    = results.filter { $0.verdict == .reachable }.count
        let total = blocked + good
        guard total > 0 else { mode = .unknown; return }
        mode = blocked >= max(1, total / 2) ? .blocklist : .open
    }

    static func human(_ b: Double) -> String {
        if b >= 1_048_576 { return String(format: "%.1f МБ/с", b/1_048_576) }
        if b >= 1024 { return String(format: "%.0f КБ/с", b/1024) }
        return String(format: "%.0f Б/с", b)
    }

    // MARK: - экспорт отчёта

    /// Есть ли что экспортировать/чем делиться.
    var canExport: Bool { !results.isEmpty || calibration != nil }

    /// Подробный человекочитаемый лог последней проверки — для шаринга через iOS.
    func exportReport() -> String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var L: [String] = []
        L.append("WhitelistChecker — отчёт о проверке")
        L.append("Версия: v\(v) · build \(b)")
        L.append("Дата: \(df.string(from: Date()))")
        L.append("Режим проверки: \(checkMode.rawValue)")
        L.append("DNS: \(dnsStatusText)")
        L.append("Резолвер проверок: \(dnsChoice.label)")
        L.append("Режим сети: \(mode.rawValue)")

        if let c = calibration {
            L.append("")
            L.append("— Калибровка эталонов —")
            L.append(anchorLine("белый", c.white))
            for f in c.foreign { L.append(anchorLine("чужой", f)) }
            if c.whiteBps > 0 && c.foreignBps > 0 {
                L.append(c.shaping
                    ? "Итог: чужой трафик медленнее белого в \(String(format: "%.0f", c.ratio))× — шейп"
                    : "Итог: чужой ≈ белый — шейпинга не видно")
            } else if c.whiteBps <= 0 {
                L.append("Итог: белый эталон не снялся — вывод по сети ненадёжен")
            }
        }

        if !results.isEmpty {
            L.append("")
            L.append("— Результаты (\(results.count)) —")
            for r in results {
                var parts = ["[\(r.verdict.rawValue)] \(r.target.raw)"]
                if r.target.kind == .domain, let ip = r.resolvedIP { parts.append("→ \(ip)") }
                if let tcp = r.tcp { parts.append("| TCP \(tcp.short)") }
                if let bps = r.speedBps { parts.append("| \(Self.human(bps))") }
                if !r.detail.isEmpty { parts.append("| \(r.detail)") }
                L.append(parts.joined(separator: " "))
            }
        }

        return L.joined(separator: "\n")
    }

    private func anchorLine(_ tag: String, _ s: AnchorSample) -> String {
        let speed = s.ok ? Self.human(s.bps) : "не отвечает"
        return "\(tag)  \(s.host)  \(speed)"
    }

    private var dnsStatusText: String {
        switch dnsStatus {
        case .ok(let via): return "ок (\(via))"
        case .failed:      return "не отвечает"
        case .checking:    return "проверка…"
        case .unknown:     return "—"
        }
    }
}
