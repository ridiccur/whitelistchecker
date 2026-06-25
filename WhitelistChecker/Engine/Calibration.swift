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

/// Снимок калибровки канала на момент проверки.
struct CalibrationSnapshot {
    let whiteBps: Double
    let foreignBps: Double      // лучший (макс) из чужих эталонов = потолок чужого трафика

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
}

/// Прогон эталонов через основную сеть телефона: белый против пачки чужих.
enum Calibrator {
    static func run() async -> CalibrationSnapshot {
        async let whiteR = ThroughputProbe.measure(host: Anchor.white.host,
                                                   path: Anchor.white.path, duration: 8.0)
        async let foreignBest = bestForeignBps()
        let (wr, fb) = await (whiteR, foreignBest)
        return CalibrationSnapshot(whiteBps: wr.bps, foreignBps: fb)
    }

    /// Качаем все чужие эталоны параллельно, возвращаем максимальную скорость.
    private static func bestForeignBps() async -> Double {
        await withTaskGroup(of: Double.self) { group in
            for a in Anchor.foreign {
                group.addTask {
                    (await ThroughputProbe.measure(host: a.host, path: a.path, duration: 8.0)).bps
                }
            }
            var best = 0.0
            for await bps in group { best = max(best, bps) }
            return best
        }
    }
}
