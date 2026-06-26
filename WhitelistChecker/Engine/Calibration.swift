import Foundation

/// Встроенные эталоны для калибровки текущего состояния канала.
/// Белый — заведомо в whitelist (полная скорость), чужой — заведомо шейпится.
enum Anchor {
    /// Белый эталон — заведомо в whitelist (полная скорость): зеркало Яндекса.
    static let white = (host: "mirror.yandex.ru", path: "/ubuntu/ls-lR.gz")

    /// Чужие эталоны — заведомо НЕ в whitelist. Берём несколько независимых CDN
    /// (Cloudflare / Google / GitHub): шейпинг душит их все, поэтому за «потолок
    /// чужого трафика» берём максимум — это страхует от случайно медленного сервера.
    static let foreign: [(host: String, path: String)] = [
        ("speed.cloudflare.com", "/__down?bytes=10000000"),
        ("dl.google.com",        "/go/go1.21.0.linux-amd64.tar.gz"),
        ("codeload.github.com",  "/git/git/tar.gz/refs/tags/v2.43.0"),
    ]
}

/// Замер одного эталона — для прозрачного вывода «что реально происходит внутри».
struct AnchorSample: Identifiable {
    let id = UUID()
    let host: String
    let bps: Double
    let ok: Bool        // удалось ли снять реальную скорость (взяли данные)
}

/// Снимок калибровки канала на момент проверки.
struct CalibrationSnapshot {
    let white: AnchorSample          // белый (whitelisted) эталон
    let foreign: [AnchorSample]      // чужие эталоны со своими скоростями

    var whiteBps: Double { white.bps }
    /// Потолок чужого трафика — максимум среди успешно снятых чужих эталонов.
    var foreignBps: Double { foreign.filter(\.ok).map(\.bps).max() ?? 0 }

    /// Порог разделения WHITE/SHAPED — геометрическое среднее эталонов.
    /// Если эталоны не снялись — запасной абсолют.
    var threshold: Double {
        if whiteBps > 0 && foreignBps > 0 {
            return (whiteBps * foreignBps).squareRoot()
        }
        return 524_288 // 0.5 МБ/с
    }

    /// Сеть душит чужой трафик: даже лучший чужой эталон заметно медленнее белого.
    var shaping: Bool {
        whiteBps > 0 && foreignBps > 0 && foreignBps < whiteBps * 0.5
    }

    /// Во сколько раз белый эталон быстрее потолка чужого трафика.
    var ratio: Double { foreignBps > 0 ? whiteBps / foreignBps : 0 }
}

/// Прогон эталонов через основную сеть телефона: белый против пачки чужих.
enum Calibrator {
    static func run() async -> CalibrationSnapshot {
        async let whiteR = ThroughputProbe.measure(host: Anchor.white.host,
                                                   path: Anchor.white.path, duration: 8.0)
        async let foreignS = foreignSamples()
        let (wr, fs) = await (whiteR, foreignS)
        let white = AnchorSample(host: Anchor.white.host, bps: wr.bps, ok: wr.trustworthy || wr.bytes > 0)
        return CalibrationSnapshot(white: white, foreign: fs)
    }

    /// Качаем все чужие эталоны параллельно, возвращаем замер по каждому
    /// (в порядке Anchor.foreign — для стабильного вывода).
    private static func foreignSamples() async -> [AnchorSample] {
        let order = Anchor.foreign.map(\.host)
        var out = await withTaskGroup(of: AnchorSample.self) { group in
            for a in Anchor.foreign {
                group.addTask {
                    let r = await ThroughputProbe.measure(host: a.host, path: a.path, duration: 8.0)
                    return AnchorSample(host: a.host, bps: r.bps, ok: r.trustworthy || r.bytes > 0)
                }
            }
            var acc: [AnchorSample] = []
            for await s in group { acc.append(s) }
            return acc
        }
        out.sort { (order.firstIndex(of: $0.host) ?? 0) < (order.firstIndex(of: $1.host) ?? 0) }
        return out
    }
}
