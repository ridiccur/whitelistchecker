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

    /// Главный прогон.
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

        // 2) Калибровка — только в режиме шейпа и если есть throughput-цели
        let needThroughput = checkMode == .shape && results.contains { !$0.target.blockOnly }
        if needThroughput {
            statusLine = "Калибровка канала…"
            calibration = await Calibrator.run()
        }

        // 3) TCP-пробы для всех целей
        statusLine = "TCP-пробы…"
        await runTCPPool()

        // 4) Классификация
        if checkMode == .shape {
            statusLine = "Замер скорости…"
            for r in results where !r.target.blockOnly {
                guard isRunning else { break }
                if case .open = r.tcp { await measureThroughput(r) }
                classifyShape(r)
            }
            for r in results where r.target.blockOnly { classifyShape(r) }
        } else {
            for r in results { classifyBlock(r) }
        }

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

    // MARK: - throughput (shape)

    private func measureThroughput(_ r: ProbeResult) async {
        let sni = r.target.host                       // домен или IP → SNI
        let dial = probeHost(r) ?? r.target.host      // куда коннектиться
        let res = await ThroughputProbe.measure(host: sni, path: "/", connectHost: dial, duration: 10.0)
        r.speedBps = res.bps
        r.detail = res.windowFilled ? "filled" : "short(\(res.bytes)B)"
    }

    // MARK: - классификация

    private func classifyShape(_ r: ProbeResult) {
        switch r.tcp {
        case .rst:     r.verdict = .blocked; r.detail = "TCP refused"; return
        case .drop:    r.verdict = .blocked; r.detail = "TCP timeout"; return
        case .dnsFail: r.verdict = .inconclusive; r.detail = "DNS не резолвится"; return
        case .error(let e): r.verdict = .inconclusive; r.detail = e; return
        case .open, .none: break
        }
        if r.target.blockOnly {           // CIDR в режиме шейпа — только доступность
            r.verdict = .reachable; r.detail = r.tcp?.short ?? ""; return
        }
        guard let bps = r.speedBps else { r.verdict = .inconclusive; r.detail = "нет данных"; return }
        let thr = calibration?.threshold ?? 524_288
        let filled = r.detail == "filled"
        if bps >= 524_288 { r.verdict = .white }
        else if filled { r.verdict = (bps >= thr) ? .white : .shaped }
        else { r.verdict = .inconclusive }
        if r.verdict != .inconclusive {
            r.detail = "\(r.speedHuman) (порог \(Self.human(thr)))"
        } else {
            r.detail = "мало данных: \(r.speedHuman)"
        }
    }

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
        let blocked = results.filter { $0.verdict == .blocked }.count
        let shaped  = results.filter { $0.verdict == .shaped }.count
        let good    = results.filter { $0.verdict == .white || $0.verdict == .reachable }.count
        let total = blocked + shaped + good
        guard total > 0 else { mode = .unknown; return }

        if blocked >= max(1, total / 2) { mode = .blocklist }
        else if shaped >= max(1, total / 3) { mode = .shaping }
        else if good == total { mode = .open }
        else if shaped > 0 { mode = .shaping }
        else { mode = .open }
    }

    static func human(_ b: Double) -> String {
        if b >= 1_048_576 { return String(format: "%.1f МБ/с", b/1_048_576) }
        if b >= 1024 { return String(format: "%.0f КБ/с", b/1024) }
        return String(format: "%.0f Б/с", b)
    }
}
