import Foundation

/// Тип распознанного ввода.
enum TargetKind: Equatable {
    case ip        // одиночный IPv4
    case cidr      // подсеть a.b.c.d/nn
    case domain    // доменное имя
}

/// Одна цель для проверки.
struct Target: Identifiable, Equatable {
    let id = UUID()
    let raw: String        // что показывать в UI (для CIDR — конкретный IP)
    let host: String       // куда реально подключаться: IP или домен
    let kind: TargetKind
    /// true для адресов, развёрнутых из CIDR — для них меряем только TCP (block-карта).
    let blockOnly: Bool

    init(raw: String, host: String, kind: TargetKind, blockOnly: Bool = false) {
        self.raw = raw; self.host = host; self.kind = kind; self.blockOnly = blockOnly
    }
}

enum InputError: LocalizedError {
    case empty
    case badFormat(String)
    case cidrTooLarge(prefix: Int, count: Int)

    var errorDescription: String? {
        switch self {
        case .empty: return "Пустой ввод"
        case .badFormat(let s): return "Не распознано: \(s)"
        case .cidrTooLarge(let p, let n):
            return "Подсеть /\(p) = \(n) адресов — слишком много. Используй /\(maxAutoPrefix) или мельче, либо подтверди вручную."
        }
    }
}

/// Дефолтный потолок авторазворота CIDR: /24 (256 адресов).
let maxAutoPrefix = 24

struct InputParser {
    /// Разобрать одну строку ввода в список целей.
    /// allowLargeCIDR=true снимает лимит /24 (после подтверждения пользователем).
    static func parse(_ input: String, allowLargeCIDR: Bool = false) throws -> [Target] {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw InputError.empty }

        // CIDR?
        if s.contains("/") {
            return try expandCIDR(s, allowLarge: allowLargeCIDR)
        }
        // голый IPv4?
        if isIPv4(s) {
            return [Target(raw: s, host: s, kind: .ip)]
        }
        // иначе — домен (грубая валидация: есть точка, допустимые символы)
        if looksLikeDomain(s) {
            return [Target(raw: s, host: s, kind: .domain)]
        }
        throw InputError.badFormat(s)
    }

    /// Разобрать многострочный ввод (по одной цели в строке, # — комментарий).
    static func parseLines(_ text: String, allowLargeCIDR: Bool = false) -> (targets: [Target], errors: [String]) {
        var targets: [Target] = []
        var errors: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            do { targets.append(contentsOf: try parse(line, allowLargeCIDR: allowLargeCIDR)) }
            catch { errors.append(error.localizedDescription) }
        }
        return (targets, errors)
    }

    // MARK: - валидация импорта (без разворота CIDR)

    /// Итог проверки импортируемого списка: что распознано и что нет.
    struct ValidationReport {
        var validLines: [String]                       // распознанные строки (raw, без разворота CIDR)
        var invalid: [(line: String, reason: String)]  // нераспознанные строки с причиной
        var ip = 0, cidr = 0, domain = 0               // счётчики по типам

        var total: Int { validLines.count + invalid.count }
        var isEmpty: Bool { total == 0 }
    }

    /// Синтаксическая проверка одной строки БЕЗ разворота подсети — для предпросмотра
    /// импорта (большой CIDR не должен раздуваться в тысячи целей до подтверждения).
    static func validateLine(_ s: String) throws -> TargetKind {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { throw InputError.empty }
        if t.contains("/") {
            let parts = t.split(separator: "/")
            guard parts.count == 2, let p = Int(parts[1]), p >= 0, p <= 32,
                  isIPv4(String(parts[0])) else { throw InputError.badFormat(t) }
            return .cidr
        }
        if isIPv4(t) { return .ip }
        if looksLikeDomain(t) { return .domain }
        throw InputError.badFormat(t)
    }

    /// Провалидировать многострочный текст из импортируемого .txt
    /// (по одной цели в строке, `#` — комментарий).
    static func validate(_ text: String) -> ValidationReport {
        var r = ValidationReport(validLines: [], invalid: [])
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            do {
                switch try validateLine(line) {
                case .ip:     r.ip += 1
                case .cidr:   r.cidr += 1
                case .domain: r.domain += 1
                }
                r.validLines.append(line)
            } catch {
                r.invalid.append((line, error.localizedDescription))
            }
        }
        return r
    }

    // MARK: - CIDR

    static func expandCIDR(_ s: String, allowLarge: Bool) throws -> [Target] {
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]), prefix >= 0, prefix <= 32,
              isIPv4(String(parts[0])),
              let base = ipToUInt32(String(parts[0]))
        else { throw InputError.badFormat(s) }

        let hostBits = 32 - prefix
        let count = hostBits >= 32 ? Int(UInt32.max) : (1 << hostBits)

        if !allowLarge && prefix < maxAutoPrefix {
            throw InputError.cidrTooLarge(prefix: prefix, count: count)
        }

        // нормализуем к сетевому адресу
        let mask: UInt32 = hostBits == 32 ? 0 : ~UInt32(0) << UInt32(hostBits)
        let network = base & mask

        var out: [Target] = []
        out.reserveCapacity(count)
        for i in 0..<UInt32(count) {
            let ip = uint32ToIP(network &+ i)
            out.append(Target(raw: ip, host: ip, kind: .cidr, blockOnly: true))
        }
        return out
    }

    // MARK: - helpers

    static func isIPv4(_ s: String) -> Bool {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for o in octets {
            guard let v = Int(o), v >= 0, v <= 255, String(v) == String(o) else { return false }
        }
        return true
    }

    static func looksLikeDomain(_ s: String) -> Bool {
        guard s.contains("."), !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func ipToUInt32(_ s: String) -> UInt32? {
        let o = s.split(separator: ".").compactMap { UInt32($0) }
        guard o.count == 4 else { return nil }
        return (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3]
    }

    static func uint32ToIP(_ v: UInt32) -> String {
        "\((v >> 24) & 0xff).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
    }
}
