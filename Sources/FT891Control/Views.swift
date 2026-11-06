import SwiftUI

// MARK: - Root

/// Hauptfenster: Kopfzeile mit Logo (``BrandBar``), Verbindungsleiste, darunter die Reiter Live, Einstellungen, Menü (EX), Protokoll, Logbuch und Contest.
/// Zeigt außerdem Meldungen aus ``Radio/alertMessage`` als Hinweisdialog.
struct ContentView: View {
    @Environment(Radio.self) private var radio

    var body: some View {
        VStack(spacing: 0) {
            BrandBar()
            ConnectionBar()
            Divider()
            TabView {
                LiveView()
                    .tabItem { Label("Live", systemImage: "gauge.with.dots.needle.67percent") }
                SweepView()
                    .tabItem { Label("SWR-Sweep", systemImage: "waveform.path.ecg") }
                ParamListView(source: .cat)
                    .tabItem { Label("Einstellungen", systemImage: "slider.horizontal.3") }
                ParamListView(source: .menu)
                    .tabItem { Label("Menü (EX)", systemImage: "list.number") }
                LogView()
                    .tabItem { Label("Protokoll", systemImage: "terminal") }
                LogbookView()
                    .tabItem { Label("Logbuch", systemImage: "book.closed") }
                ContestView()
                    .tabItem { Label("Contest", systemImage: "list.clipboard") }
            }
        }
        .frame(minWidth: 1000, minHeight: 720)
        .alert("Hinweis",
               isPresented: Binding(get: { radio.alertMessage != nil },
                                    set: { if !$0 { radio.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(radio.alertMessage ?? "")
        }
    }
}

// MARK: - Verbindungsleiste

/// Leiste zur Verbindungssteuerung: Port, Baudrate, Stoppbits, Status sowie Verbinden, Trennen und Auto-Erkennung.
struct ConnectionBar: View {
    @Environment(Radio.self) private var radio

    /// Farbe der Statusanzeige: grün = verbunden, orange = verbunden aber keine Antwort, gelb = im Aufbau, rot = getrennt.
    private var statusColor: Color {
        switch radio.state {
        case .connected: return radio.noResponse ? .orange : .green
        case .connecting: return .yellow
        case .disconnected: return .red
        }
    }

    var body: some View {
        @Bindable var radio = radio
        HStack(spacing: 12) {
            Picker("Port", selection: $radio.selectedPort) {
                if radio.ports.isEmpty { Text("Kein Port gefunden").tag("") }
                ForEach(radio.ports, id: \.self) { p in
                    Text(p.replacingOccurrences(of: "/dev/", with: "")).tag(p)
                }
            }
            .frame(width: 320)
            .disabled(radio.state != .disconnected)

            Button {
                radio.refreshPorts()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Portliste aktualisieren")
            .disabled(radio.state != .disconnected)

            Picker("Baud", selection: $radio.baud) {
                ForEach([4800, 9600, 19200, 38400], id: \.self) { Text("\($0)").tag($0) }
            }
            .frame(width: 130)
            .disabled(radio.state != .disconnected)

            Toggle("2 Stoppbits", isOn: $radio.twoStopBits)
                .disabled(radio.state != .disconnected)

            Spacer()

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(radio.busyText ?? radio.statusText).lineLimit(1)
            }

            if radio.state == .connected {
                Button("Trennen") { radio.disconnect() }
            } else {
                Button("Verbinden") { radio.connect() }
                    .disabled(radio.selectedPort.isEmpty || radio.state == .connecting)
                Button("Auto-Erkennung") { radio.autoDetect() }
                    .disabled(radio.state == .connecting)
                    .help("Probiert alle Ports und Baudraten mit „ID;“ durch. Öffnet dabei kurz auch den zweiten (Standard-)Port des FT-891.")
            }
        }
        .padding(10)
    }
}

// MARK: - Parameterliste

/// Durchsuchbare, nach Gruppen gegliederte Liste aller Parameter – entweder der Standard-CAT-Befehle oder des EX-Menüs.
/// Mit Massenfunktionen zum Lesen sowie zum Sichern und Zurückschreiben.
struct ParamListView: View {
    /// Welcher Teil des Katalogs angezeigt wird.
    enum Source { case cat, menu }
    let source: Source

    @Environment(Radio.self) private var radio
    @State private var search = ""
    @State private var group = "Alle"

    /// Alle Parameter der gewählten Quelle.
    private var all: [Param] { source == .cat ? Catalog.standard : Catalog.menu }

    /// Gruppennamen für den Filter (bei Standardbefehlen in festgelegter Reihenfolge, beim Menü alphabetisch).
    private var groups: [String] {
        if source == .cat { return Catalog.standardGroups }
        return Array(Set(all.map { $0.group })).sorted()
    }

    /// Parameter nach Gruppe und Suchtext; gesucht wird in Name, Befehl und Menünummer.
    private var filtered: [Param] {
        all.filter { p in
            let groupOK = group == "Alle" || p.group == group
            let searchOK = search.isEmpty
                || p.name.localizedCaseInsensitiveContains(search)
                || p.id.localizedCaseInsensitiveContains(search)
                || (p.menuNumber ?? "").contains(search)
            return groupOK && searchOK
        }
    }

    /// Gruppen, die nach dem Filtern noch mindestens einen Eintrag haben.
    private var visibleGroups: [String] {
        groups.filter { g in filtered.contains { $0.group == g } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Suchen …", text: $search)
                    .frame(width: 220)
                Picker("Gruppe", selection: $group) {
                    Text("Alle").tag("Alle")
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 280)
                Spacer()
                if radio.bulkBusy {
                    ProgressView(value: radio.progress).frame(width: 160)
                    Button("Abbrechen") { radio.cancelBulkOperation() }
                } else {
                    Button("Angezeigte lesen") { radio.readAll(filtered) }
                        .disabled(!radio.isConnected)
                    Button("Alle lesen") { radio.readAll(Catalog.all) }
                        .disabled(!radio.isConnected)
                    Button("Sichern …") { radio.exportBackup() }
                    Button("Laden …") { radio.importBackup() }
                        .disabled(!radio.isConnected)
                }
            }
            .padding(8)
            Divider()
            List {
                ForEach(visibleGroups, id: \.self) { g in
                    Section(g) {
                        ForEach(filtered.filter { $0.group == g }) { p in
                            ParamRow(param: p)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .environment(\.defaultMinListRowHeight, 22)
        }
    }
}

// MARK: - Parameterzeile

/// Eine Zeile der Parameterliste mit dem passenden Bedienelement (Schalter, Auswahl, Regler oder Text).
///
/// Schreibvorgänge gehen sofort über ``Radio/write(_:raw:)``; Regler schreiben erst beim Loslassen.
struct ParamRow: View {
    let param: Param
    @Environment(Radio.self) private var radio
    @State private var draft: Double = 0
    @State private var dragging = false

    /// Aktueller Rohwert oder `nil`, solange der Parameter noch nicht gelesen wurde.
    private var raw: String? { radio.values[param.id] }

    /// Titel mit vorangestellter Menünummer (z. B. `05-06  CAT RATE`).
    private var title: String {
        if let n = param.menuNumber { return "\(n)  \(param.name)" }
        return param.name
    }

    /// Untertitel: CAT-Befehl und gegebenenfalls ein Hinweis.
    private var subtitle: String {
        if let note = param.note { return "\(param.id) · \(note)" }
        return param.id
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let n = param.menuNumber {
                Text(n)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
            }
            Text(param.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 230, alignment: .leading)
                .help(title + "\n" + subtitle)
            Text(param.id)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)

            control
                .controlSize(.small)

            if let note = param.note {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(note)
            }

            Spacer(minLength: 0)

            if let e = radio.errors[param.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(e)
            }
        }
        .onAppear { syncDraft() }
        .onChange(of: radio.values[param.id]) { _, _ in syncDraft() }
    }

    /// Bedienelement passend zur Art des Parameters; vor dem ersten Lesen nur eine „Lesen“-Schaltfläche.
    @ViewBuilder private var control: some View {
        if let raw {
            switch param.kind {
            case .toggle(let off, let on):
                Toggle("", isOn: Binding(get: { raw == on },
                                         set: { radio.write(param, raw: $0 ? on : off) }))
                    .labelsHidden()
                    .disabled(param.readOnly)
            case .choice(let options):
                Picker("", selection: Binding(get: { raw }, set: { radio.write(param, raw: $0) })) {
                    if !options.contains(where: { $0.code == raw }) {
                        Text("? (\(raw))").tag(raw)
                    }
                    ForEach(options) { o in
                        Text(o.label).tag(o.code)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                .disabled(param.readOnly)
            case .number(let lo, let hi, let step, _, _, _):
                numeric(lo: lo, hi: hi, step: step)
            case .stepped(let lo, let hi, _):
                numeric(lo: lo, hi: hi, step: 1)
            case .signed(let lo, let hi, let step, _):
                numeric(lo: lo, hi: hi, step: step)
            case .text:
                Text(param.display(raw))
                    .font(.system(.body, design: .monospaced))
            }
        } else {
            Button("Lesen") {
                Task { await radio.read(param) }
            }
            .disabled(!radio.isConnected)
        }
    }

    /// Regler mit Wertanzeige und Stepper für Zahlenparameter.
    /// Liegt der Gerätewert außerhalb des Katalogbereichs, wird der Bereich aufgeweitet.
    private func numeric(lo: Int, hi: Int, step: Int) -> some View {
        let current = Int(raw ?? "") ?? lo
        let lower = Swift.min(lo, current)
        let upper = Swift.max(hi, current)
        return HStack(spacing: 8) {
            Slider(value: $draft, in: Double(lower)...Double(upper), step: Double(step)) { editing in
                dragging = editing
                if !editing { commit(Int(draft.rounded())) }
            }
            .frame(width: 200)
            Text(radio.displayText(param, value: Int(draft.rounded())))
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
            Stepper("",
                    value: Binding(get: { Int(draft.rounded()) },
                                   set: { draft = Double($0); commit($0) }),
                    in: lower...upper, step: step)
                .labelsHidden()
        }
        .disabled(param.readOnly)
    }

    /// Schreibt einen Zahlenwert zum Gerät.
    private func commit(_ v: Int) {
        radio.write(param, raw: param.encode(v))
    }

    /// Übernimmt den Gerätewert in den Regler, sofern er nicht gerade bewegt wird.
    private func syncDraft() {
        guard !dragging, let raw, let v = Int(raw) else { return }
        draft = Double(v)
    }
}

// MARK: - Protokoll / Rohbefehle

/// Protokoll aller CAT-Frames mit Eingabefeld für Rohbefehle (z. B. `FA;`).
struct LogView: View {
    @Environment(Radio.self) private var radio
    @State private var command = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Rohbefehl, z. B.  FA;  oder  EX0506;", text: $command)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(send)
                Button("Senden", action: send)
                    .disabled(!radio.isConnected)
                Button("Protokoll leeren") { radio.log.removeAll() }
                Button("Kopieren") {
                    let text = radio.log.map { "\($0.direction.rawValue) \($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                List(radio.log) { line in
                    Text("\(line.time.formatted(date: .omitted, time: .standard))  \(line.direction.rawValue)  \(line.text)")
                        .font(.system(.caption, design: .monospaced))
                        .id(line.id)
                }
                .onChange(of: radio.log.count) { _, _ in
                    if let last = radio.log.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Sendet den eingegebenen Rohbefehl und leert das Eingabefeld.
    private func send() {
        radio.sendRaw(command)
        command = ""
    }
}
