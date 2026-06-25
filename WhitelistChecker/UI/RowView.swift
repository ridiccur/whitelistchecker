import SwiftUI

/// Одна строка результата проверки.
struct RowView: View {
    @ObservedObject var result: ProbeResult

    var body: some View {
        HStack(spacing: 10) {
            Text(result.verdict.emoji)
                .font(.title3)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.target.raw)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                if !result.detail.isEmpty {
                    Text(result.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(result.verdict == .pending ? "" : result.verdict.rawValue)
                    .font(.caption.bold())
                    .foregroundStyle(verdictColor)
                if let tcp = result.tcp {
                    Text(tcp.short)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if result.verdict == .pending {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var verdictColor: Color {
        switch result.verdict {
        case .white, .reachable: return .green
        case .shaped: return .orange
        case .blocked: return .red
        case .inconclusive: return .gray
        case .pending: return .secondary
        }
    }
}
