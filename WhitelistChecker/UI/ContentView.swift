import SwiftUI

struct ContentView: View {
    @StateObject private var engine = ScanEngine()
    @State private var inputText: String = "ya.ru\nvk.com\n8.8.8.8\ncodeload.github.com"
    @State private var channel: Channel = .cellular
    @State private var parseErrors: [String] = []
    @State private var cidrPrompt: CIDRPrompt?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inputSection
                Divider()
                if engine.isRunning || !engine.statusLine.isEmpty {
                    statusBar
                }
                if let mode = engine.mode as NetworkMode?, !engine.results.isEmpty, !engine.isRunning {
                    modeBanner(mode)
                }
                resultsList
            }
            .navigationTitle("Whitelist Checker")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert(item: $cidrPrompt) { prompt in
            Alert(
                title: Text("Большая подсеть"),
                message: Text(prompt.message),
                primaryButton: .destructive(Text("Развернуть всё")) {
                    startScan(allowLargeCIDR: true)
                },
                secondaryButton: .cancel(Text("Отмена"))
            )
        }
    }

    // MARK: - ввод

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IP · CIDR · домен (по одному в строке)")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $inputText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 96)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            HStack {
                Picker("Канал", selection: $channel) {
                    ForEach(Channel.allCases) { c in Text(c.rawValue).tag(c) }
                }
                .pickerStyle(.segmented)

                Button {
                    startScan(allowLargeCIDR: false)
                } label: {
                    Text(engine.isRunning ? "…" : "Проверить")
                        .frame(maxWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.isRunning)
            }

            if !parseErrors.isEmpty {
                ForEach(parseErrors, id: \.self) { e in
                    Text("⚠ \(e)").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding()
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if engine.isRunning { ProgressView().controlSize(.small) }
            Text(engine.statusLine.isEmpty ? "Готово" : engine.statusLine)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let c = engine.calibration {
                Text("эталон: \(ScanEngine.human(c.whiteBps)) / \(ScanEngine.human(c.foreignBps))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    private func modeBanner(_ mode: NetworkMode) -> some View {
        HStack {
            Text(bannerEmoji(mode)).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Режим сети").font(.caption2).foregroundStyle(.secondary)
                Text(mode.rawValue).font(.subheadline.bold())
            }
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(bannerColor(mode).opacity(0.12))
    }

    private var resultsList: some View {
        List(engine.results) { r in
            RowView(result: r)
        }
        .listStyle(.plain)
    }

    // MARK: - actions

    private func startScan(allowLargeCIDR: Bool) {
        let (targets, errors) = InputParser.parseLines(inputText, allowLargeCIDR: allowLargeCIDR)
        // отдельно ловим «слишком большой CIDR», чтобы показать подтверждение
        if !allowLargeCIDR {
            for line in inputText.split(whereSeparator: \.isNewline) {
                let s = line.trimmingCharacters(in: .whitespaces)
                guard s.contains("/") else { continue }
                do { _ = try InputParser.parse(s, allowLargeCIDR: false) }
                catch let e as InputError {
                    if case .cidrTooLarge = e {
                        cidrPrompt = CIDRPrompt(message: e.localizedDescription)
                        return
                    }
                } catch {}
            }
        }
        parseErrors = errors
        guard !targets.isEmpty else { return }
        engine.channel = channel
        Task { await engine.run(targets: targets) }
    }

    private func bannerEmoji(_ m: NetworkMode) -> String {
        switch m {
        case .blocklist: return "⛔"; case .shaping: return "🟡"
        case .open: return "🟢"; case .unknown: return "⚪"
        }
    }
    private func bannerColor(_ m: NetworkMode) -> Color {
        switch m {
        case .blocklist: return .red; case .shaping: return .yellow
        case .open: return .green; case .unknown: return .gray
        }
    }
}

struct CIDRPrompt: Identifiable {
    let id = UUID()
    let message: String
}

#Preview {
    ContentView()
}
