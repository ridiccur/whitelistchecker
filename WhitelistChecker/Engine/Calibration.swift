import Foundation

/// Встроенные эталоны для калибровки текущего состояния канала.
/// Белый — заведомо в whitelist (полная скорость), чужой — заведомо шейпится.
enum Anchor {
    /// (host, path) с заведомо крупным объектом для скачивания.
    static let white = (host: "mirror.yandex.ru", path: "/ubuntu/ls-lR.gz")
    static let foreign = (host: "codeload.github.com", path: "/git/git/tar.gz/refs/tags/v2.43.0")
}

/// Снимок калибровки канала на момент проверки.
struct CalibrationSnapshot {
    let whiteBps: Double
    let foreignBps: Double

    /// Порог разделения WHITE/SHAPED — геометрическое среднее эталонов
    /// Если эталоны не снялись — запасной абсолют.
    var threshold: Double {
        if whiteBps > 0 && foreignBps > 0 {
            return (whiteBps * foreignBps).squareRoot()
        }
        return 524_288 // 0.5 МБ/с
    }
}

/// Прогон обоих эталонов через основную сеть телефона.
enum Calibrator {
    static func run() async -> CalibrationSnapshot {
        async let w = ThroughputProbe.measure(host: Anchor.white.host, path: Anchor.white.path,
                                              duration: 8.0)
        async let f = ThroughputProbe.measure(host: Anchor.foreign.host, path: Anchor.foreign.path,
                                              duration: 8.0)
        let (wr, fr) = await (w, f)
        return CalibrationSnapshot(whiteBps: wr.bps, foreignBps: fr.bps)
    }
}
