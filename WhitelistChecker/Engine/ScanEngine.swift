import Foundation

/// Оркестратор: ведёт пробы для набора целей, классифицирует вердикт,
/// считает агрегатный режим сети. Наблюдаемый объект для SwiftUI.
@MainActor
final class ScanEngine: ObservableObject {
    @Published var results: [ProbeResult] = []
    @Published var calibration: CalibrationSnapshot?
    @Published var mode: NetworkMode = .unknown
    @Published var isRunning = false
    @Published var statusLine = ""

    var channel: Channel = .cellular

    /// Параллелизм TCP-проб (block-карта CIDR).
    private let tcpConcurrency = 24

    func cancelAll() { isRunning = false }

    /// Главный прогон.
    func run(targets: [Target]) async {
        guard !targets.isEmpty else { return }
        isRunning = true
        results = targets.map { ProbeResult(target: $0) }
        mode = .unknown

        // 1) Калибровка канала (если есть хоть одна цель, требующая throughput)
        let needThroughput = targets.contains { !$0.blockOnly }
        if needThroughput {
            statusLine = "Калибровка канала…"
            calibration = await Calibrator.run(channel: channel)
        }

        // 2) TCP-пробы для всех целей — параллельно, пулом
        statusLine = "TCP-пробы…"
        await runTCPPool()

        // 3) Throughput — только для не-blockOnly целей, у которых TCP=OPEN
        statusLine = "Замер скорости…"
        for r in results where !r.target.blockOnly {
            guard isRunning else { break }
            if case .open = r.tcp {
                await measureThroughput(r)
            }
            classify(r)
        }
        // для blockOnly целей вердикт чисто по TCP
        for r in results where r.target.blockOnly {
            classify(r)
        }

        // 4) Агрегатный режим сети
        computeNetworkMode()
        statusLine = ""
        isRunning = false
    }

    // MARK: - TCP pool

    private func runTCPPool() async {
        let channel = self.channel
        var index = 0
        let all = results
        await withTaskGroup(of: (Int, TCPResult).self) { group in
            var inFlight = 0
            func launch(_ i: Int) {
                let host = all[i].target.host
                group.addTask {
                    let res = await TCPProbe.probe(host: host, channel: channel)
                    return (i, res)
                }
            }
            while index < all.count && inFlight < tcpConcurrency {
                launch(index); index += 1; inFlight += 1
            }
            while let (i, res) = await group.next() {
                all[i].tcp = res
                inFlight -= 1
                if index < all.count && isRunning {
                    launch(index); index += 1; inFlight += 1
                }
            }
        }
    }

    // MARK: - throughput

    private func measureThroughput(_ r: ProbeResult) async {
        let res = await ThroughputProbe.measure(host: r.target.host, path: "/",
                                                channel: channel, duration: 10.0)
        r.speedBps = res.bps
        // запомним «заполнено ли окно» через detail для классификатора
        r.detail = res.windowFilled ? "filled" : "short(\(res.bytes)B)"
    }

    // MARK: - классификация одной цели

    private func classify(_ r: ProbeResult) {
        // BLOCK по TCP имеет приоритет
        switch r.tcp {
        case .rst:
            r.verdict = .blocked; r.detail = "TCP refused"; return
        case .drop:
            r.verdict = .blocked; r.detail = "TCP timeout (blackhole)"; return
        case .dnsFail:
            r.verdict = .inconclusive; r.detail = "DNS не резолвится"; return
        case .error(let e):
            r.verdict = .inconclusive; r.detail = e; return
        case .open, .none:
            break
        }

        // blockOnly (CIDR): вердикт только по TCP — OPEN значит «доступен»
        if r.target.blockOnly {
            r.verdict = .white   // в block-карте OPEN = не заблокирован
            r.detail = r.tcp?.short ?? ""
            return
        }

        // throughput-классификация
        guard let bps = r.speedBps else {
            r.verdict = .inconclusive; r.detail = "нет данных"; return
        }
        let thr = calibration?.threshold ?? 524_288
        let filled = r.detail == "filled"

        if bps >= 524_288 {                  // ≥0.5 МБ/с — точно белый
            r.verdict = .white
        } else if filled {                   // окно заполнено → bps = реальный потолок
            if bps <= 65_536 { r.verdict = .shaped }       // ≤64 КБ/с
            else if bps >= thr { r.verdict = .white }
            else { r.verdict = .shaped }
        } else {
            r.verdict = .inconclusive
        }
        r.detail = "\(r.speedHuman) (порог \(Self.human(thr)))"
    }

    // MARK: - режим сети

    private func computeNetworkMode() {
        // считаем только по «не-белым» целям (домены/IP, которые мы проверяли throughput'ом),
        // и по TCP-исходам блок-карты
        let blocked = results.filter { $0.verdict == .blocked }.count
        let shaped  = results.filter { $0.verdict == .shaped }.count
        let white   = results.filter { $0.verdict == .white }.count
        let total = blocked + shaped + white
        guard total > 0 else { mode = .unknown; return }

        if blocked >= max(1, total / 2) { mode = .blocklist }
        else if shaped >= max(1, total / 3) { mode = .shaping }
        else if white == total { mode = .open }
        else { mode = .shaping }
    }

    static func human(_ b: Double) -> String {
        if b >= 1_048_576 { return String(format: "%.1f МБ/с", b/1_048_576) }
        if b >= 1024 { return String(format: "%.0f КБ/с", b/1024) }
        return String(format: "%.0f Б/с", b)
    }
}
