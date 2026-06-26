import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = ScanEngine()
    @State private var inputText: String = "ya.ru\nvk.com\n8.8.8.8\ncodeload.github.com"
    @State private var mode: CheckMode = .shape
    @State private var parseErrors: [String] = []
    @State private var cidrPrompt: CIDRPrompt?
    @State private var showImporter = false
    @State private var importPreview: ImportPreview?
    @State private var shareItem: ShareItem?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                // фон-перехватчик тапа для скрытия клавиатуры
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .onTapGesture { inputFocused = false }

                ScrollView {
                    VStack(spacing: 0) {
                        inputSection
                        Divider()
                        dnsBar
                        if engine.isRunning || !engine.statusLine.isEmpty { statusBar }
                        if engine.mode != .unknown && !engine.isRunning { modeBanner(engine.mode) }
                        if let c = engine.calibration, !engine.isRunning { calibrationPanel(c) }
                        resultsContent
                        buildFooter
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Whitelist Checker")
            .navigationBarTitleDisplayMode(.inline)
            .task { await engine.refreshDNS() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        inputFocused = false
                        exportLog()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!engine.canExport || engine.isRunning)
                }
            }
        }
        .alert(item: $cidrPrompt) { prompt in
            Alert(title: Text("Большая подсеть"),
                  message: Text(prompt.message),
                  primaryButton: .destructive(Text("Развернуть всё")) { startScan(allowLargeCIDR: true) },
                  secondaryButton: .cancel(Text("Отмена")))
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.plainText, .text],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .sheet(item: $importPreview) { preview in
            importConfirmSheet(preview)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .onOpenURL { url in
            // .txt, открытый в приложение через Share/«Открыть в…» — маршрут в обход
            // системного Document Picker (надёжнее при переподписи сторонним сертификатом).
            mode = .block
            openTextFile(url)
        }
    }

    // MARK: - ввод

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Режим", selection: $mode) {
                ForEach(CheckMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            Text(mode.subtitle)
                .font(.caption2).foregroundStyle(.secondary)

            if mode == .block {
                HStack(spacing: 8) {
                    Text("IP · CIDR · домен (по одному в строке)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        inputFocused = false
                        pasteFromClipboard()
                    } label: {
                        Label("Вставить", systemImage: "doc.on.clipboard")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        inputFocused = false
                        showImporter = true
                    } label: {
                        Label("Импорт .txt", systemImage: "square.and.arrow.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                TextEditor(text: $inputText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 92)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($inputFocused)
            } else {
                Text("Скорость канала меряется по встроенным эталонам: белый whitelisted сервер (зеркало Яндекса) против чужих CDN (Cloudflare, Google, GitHub). Список доменов вводить не нужно.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                inputFocused = false
                startScan(allowLargeCIDR: false)
            } label: {
                Text(engine.isRunning ? "Проверяю…" : "Проверить")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine.isRunning)

            if mode == .block, !parseErrors.isEmpty {
                ForEach(parseErrors, id: \.self) { e in
                    Text("⚠ \(e)").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding()
    }

    // MARK: - DNS

    @ViewBuilder private var dnsBar: some View {
        switch engine.dnsStatus {
        case .ok(let via):
            HStack(spacing: 6) {
                Text("🟢 DNS: ок").font(.caption2)
                Text("(\(engine.dnsChoice.label == "Системный" ? "система: \(via)" : engine.dnsChoice.label))")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 5)
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text("⛔ Системный DNS не отвечает").font(.caption.bold()).foregroundStyle(.red)
                Text("Резолвить домены через (только для проверок в приложении):")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    dnsButton("Yandex \(KnownDNS.yandex)", choice: .server(KnownDNS.yandex))
                    if let op = engine.systemDNS.first {
                        dnsButton("Оператора \(op)", choice: .server(op))
                    }
                    dnsButton("Системный ↻", choice: .system)
                }
            }
            .padding(.horizontal).padding(.vertical, 6)
            .background(Color.red.opacity(0.08))
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Проверка DNS…").font(.caption2) }
                .padding(.horizontal).padding(.vertical, 5)
        case .unknown:
            EmptyView()
        }
    }

    private func dnsButton(_ title: String, choice: DNSChoice) -> some View {
        Button(title) {
            engine.dnsChoice = choice
            Task { await engine.refreshDNS() }
        }
        .font(.caption2)
        .buttonStyle(.bordered)
        .tint(engine.dnsChoice == choice ? .accentColor : .secondary)
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

    private func modeBanner(_ m: NetworkMode) -> some View {
        HStack {
            Text(bannerEmoji(m)).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Режим сети").font(.caption2).foregroundStyle(.secondary)
                Text(m.rawValue).font(.subheadline.bold())
            }
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(bannerColor(m).opacity(0.12))
    }

    // MARK: - что реально измерено (эталоны)

    /// Прозрачный вывод калибровки: фактическая скорость каждого эталона
    /// и итог по шейпу. Per-site точно мерить нельзя, поэтому показываем правду
    /// по тому, что измеримо — белый whitelisted сервер против чужих CDN.
    private func calibrationPanel(_ c: CalibrationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Что реально измерено").font(.caption2.bold()).foregroundStyle(.secondary)
            anchorRow(tag: "белый", s: c.white)
            ForEach(c.foreign) { f in anchorRow(tag: "чужой", s: f) }
            if c.whiteBps > 0 && c.foreignBps > 0 {
                Text(c.shaping
                     ? "→ чужой трафик медленнее белого в \(String(format: "%.0f", c.ratio))× — это шейп"
                     : "→ чужой ≈ белый — шейпинга не видно")
                    .font(.caption2.bold())
                    .foregroundStyle(c.shaping ? .orange : .green)
            } else if c.whiteBps <= 0 {
                Text("→ белый эталон не снялся — вывод по сети ненадёжен")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }

    private func anchorRow(tag: String, s: AnchorSample) -> some View {
        HStack(spacing: 8) {
            Text(tag)
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(s.host)
                .font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(s.ok ? ScanEngine.human(s.bps) : "не отвечает")
                .font(.caption2.bold())
                .foregroundStyle(s.ok ? .primary : .secondary)
        }
    }

    // Список — LazyVStack внутри общего ScrollView (а не отдельный List),
    // чтобы скроллился весь экран целиком, включая альбомную ориентацию.
    private var resultsContent: some View {
        LazyVStack(spacing: 0) {
            ForEach(engine.results) { r in
                RowView(result: r)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                Divider()
            }
        }
    }

    // MARK: - штамп сборки (чтобы на устройстве видеть, какая версия установлена)

    private var buildFooter: some View {
        Text(Self.buildStamp)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
    }

    static var buildStamp: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        if let date = info?["WLCBuildDate"] as? String, !date.isEmpty {
            return "v\(v) · build \(b) · \(date)"
        }
        return "v\(v) · build \(b)"
    }

    // MARK: - actions

    private func startScan(allowLargeCIDR: Bool) {
        // Шейп: доменов не вводим — гоняем встроенные эталоны.
        if mode == .shape {
            engine.checkMode = .shape
            Task { await engine.runShapeCheck() }
            return
        }
        if !allowLargeCIDR {
            for line in inputText.split(whereSeparator: \.isNewline) {
                let s = line.trimmingCharacters(in: .whitespaces)
                guard s.contains("/") else { continue }
                do { _ = try InputParser.parse(s, allowLargeCIDR: false) }
                catch let e as InputError { if case .cidrTooLarge = e {
                    cidrPrompt = CIDRPrompt(message: e.localizedDescription); return } }
                catch {}
            }
        }
        let (targets, errors) = InputParser.parseLines(inputText, allowLargeCIDR: allowLargeCIDR)
        parseErrors = errors
        guard !targets.isEmpty else { return }
        engine.checkMode = mode
        Task { await engine.run(targets: targets) }
    }

    // MARK: - импорт .txt

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            presentPreview(errorPreview(e.localizedDescription, file: ""))
        case .success(let urls):
            guard let url = urls.first else { return }
            presentPreview(buildPreview(from: url))
        }
    }

    /// Импорт файла, открытого в приложение через Share/«Открыть в…» (onOpenURL).
    private func openTextFile(_ url: URL) {
        presentPreview(buildPreview(from: url))
    }

    /// Вставка списка прямо из буфера обмена — работает при любой подписи,
    /// в обход системного Document Picker.
    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            presentPreview(errorPreview("В буфере обмена нет текста", file: "буфер обмена"))
            return
        }
        presentPreview(ImportPreview(report: InputParser.validate(text), fileName: "буфер обмена"))
    }

    private func buildPreview(from url: URL) -> ImportPreview {
        switch readText(url) {
        case .success(let text):
            return ImportPreview(report: InputParser.validate(text), fileName: url.lastPathComponent)
        case .failure(let f):
            return errorPreview(f.reason, file: url.lastPathComponent)
        }
    }

    private func errorPreview(_ reason: String, file: String) -> ImportPreview {
        ImportPreview(report: .init(validLines: [], invalid: [("", reason)]), fileName: file)
    }

    /// Презентуем лист предпросмотра ПОСЛЕ закрытия fileImporter — иначе SwiftUI
    /// «проглатывает» вторую презентацию (новый sheet поверх ещё закрывающегося).
    private func presentPreview(_ preview: ImportPreview) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            importPreview = preview
        }
    }

    /// Надёжное чтение текста: координированное чтение (NSFileCoordinator) +
    /// security-scope + запасные кодировки. Возвращает причину ошибки текстом,
    /// чтобы было видно, что именно пошло не так (важно при сторонней подписи).
    private func readText(_ url: URL) -> Result<String, ReadFailure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var coordErr: NSError?
        var data: Data?
        var readErr: String?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordErr) { u in
            do { data = try Data(contentsOf: u) }
            catch { readErr = error.localizedDescription }
        }
        if let coordErr { return .failure(.init(reason: "координация чтения: \(coordErr.localizedDescription)")) }
        guard let data else { return .failure(.init(reason: readErr ?? "файл недоступен (проверь подпись/доступ к Файлам)")) }
        guard !data.isEmpty else { return .failure(.init(reason: "файл пустой")) }

        for enc in [String.Encoding.utf8, .windowsCP1251, .isoLatin1, .ascii] {
            if let s = String(data: data, encoding: enc) { return .success(s) }
        }
        return .failure(.init(reason: "неизвестная кодировка (нужен текст UTF-8/CP1251)"))
    }

    struct ReadFailure: Error { let reason: String }

    private func importConfirmSheet(_ preview: ImportPreview) -> some View {
        let r = preview.report
        return NavigationStack {
            List {
                Section {
                    if !preview.fileName.isEmpty {
                        labelRow("Файл", preview.fileName)
                    }
                    labelRow("Распознано", "\(r.validLines.count)")
                    if r.ip > 0     { labelRow("• IP", "\(r.ip)") }
                    if r.cidr > 0   { labelRow("• CIDR", "\(r.cidr)") }
                    if r.domain > 0 { labelRow("• домены", "\(r.domain)") }
                    if !r.invalid.isEmpty {
                        labelRow("Пропущено (ошибки)", "\(r.invalid.count)")
                    }
                }
                if !r.invalid.isEmpty {
                    Section("Нераспознанные строки") {
                        ForEach(Array(r.invalid.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.line.isEmpty ? "—" : item.line)
                                    .font(.system(.caption, design: .monospaced))
                                Text(item.reason).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Импорт списка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { importPreview = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Menu("Импорт (\(r.validLines.count))") {
                        Button("Заменить ввод") { applyImport(r, append: false) }
                        Button("Добавить к вводу") { applyImport(r, append: true) }
                    }
                    .disabled(r.validLines.isEmpty)
                }
            }
        }
    }

    private func applyImport(_ r: InputParser.ValidationReport, append: Bool) {
        let imported = r.validLines.joined(separator: "\n")
        if append {
            let base = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            inputText = base.isEmpty ? imported : base + "\n" + imported
        } else {
            inputText = imported
        }
        parseErrors = []
        importPreview = nil
    }

    private func labelRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary) }
    }

    // MARK: - экспорт лога

    private func exportLog() {
        let text = engine.exportReport()
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let name = "whitelistchecker-\(df.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareItem(url: url)
        } catch {
            // если запись не удалась — делимся хотя бы текстом через временный путь не выйдет,
            // поэтому просто игнорируем (кнопка останется доступной для повтора)
        }
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

/// Предпросмотр импортируемого списка перед заливкой в поле ввода.
struct ImportPreview: Identifiable {
    let id = UUID()
    let report: InputParser.ValidationReport
    let fileName: String
}

/// Обёртка для презентации share-листа по файлу отчёта.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Системный share-лист iOS (UIActivityViewController) — «Поделиться».
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

#Preview { ContentView() }
