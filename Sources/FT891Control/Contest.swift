import SwiftUI

// MARK: - Reiter „Contest“

/// Reiter „Contest“: Contest-Sitzung wählen oder anlegen, QSOs mit Exchange schnell per Tastatur loggen,
/// Dupe-Prüfung innerhalb der Sitzung, Cabrillo-Export.
///
/// Tastatur: Rufzeichen eingeben → Return springt ins Exchange-Feld (ist es schon gefüllt, wird geloggt) →
/// Return loggt. Esc leert die Eingabe.
struct ContestView: View {
    @Environment(Radio.self) private var radio
    @Environment(Logbook.self) private var log

    @State private var call = ""
    @State private var rstSent = ""
    @State private var rstRcvd = ""
    @State private var exch = ""
    @State private var selection: UUID?
    @State private var editing: QSO?
    @State private var sessionSheet: ContestSession?
    @State private var showStation = false
    @State private var confirmDelete = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case call, exch }

    private var modeLabel: String { rigModeLabel(radio) }
    private var defaultRST: String { ModeGroup.of(modeLabel).defaultRST }
    private var canLog: Bool { radio.isConnected && radio.freqA > 0 && call.count >= 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sessionBar
            LogMessages()
            Divider()
            if let s = log.activeContest {
                content(s)
            } else {
                emptyState
            }
        }
        .padding(20)
        .sheet(item: $editing) { q in QSOEditSheet(qso: q) }
        .sheet(item: $sessionSheet) { s in
            ContestSessionSheet(session: s, isNew: log.contest(id: s.id) == nil)
        }
        .sheet(isPresented: $showStation) { StationSheet() }
    }

    // MARK: Sitzung

    private var sessionBar: some View {
        HStack(spacing: 10) {
            Text("Contest:").font(.headline)
            Picker("Contest", selection: Binding(
                get: { log.activeContestID ?? "" },
                set: { log.setActiveContest($0.isEmpty ? nil : $0) })) {
                Text("– keiner –").tag("")
                ForEach(Array(log.contests.reversed())) { c in
                    Text("\(c.name.isEmpty ? "(ohne Namen)" : c.name) · \(log.qsos(inContest: c.id).count) QSOs").tag(c.id)
                }
            }
            .labelsHidden()
            .frame(width: 340)
            Button("Neuer Contest …") { sessionSheet = ContestSession() }
            Button("Einstellungen …") { sessionSheet = log.activeContest }
                .disabled(log.activeContest == nil)
            Spacer()
            Button("Station …") { showStation = true }
            Button("Cabrillo exportieren …") {
                if let s = log.activeContest { log.exportCabrillo(s) }
            }
            .disabled(log.activeContest == nil)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.clipboard").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Kein Contest gewählt").font(.title2)
            Text("Lege mit „Neuer Contest …“ eine Sitzung an (Vorlagen für CQ WW, WPX, IARU, ARRL DX, WAE, WAG) oder wähle oben eine bestehende. Contest-QSOs stehen zusätzlich im Logbuch.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button("Neuer Contest …") { sessionSheet = ContestSession() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Inhalt

    private func content(_ s: ContestSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 24) {
                frequencyBlock
                Spacer()
                TuningKnob(size: 100)
            }
            BandStrip(qsos: log.qsos(inContest: s.id), source: s.name)
            entryRow(s)
            statusLine(s)
            summary(s)
            table(s)
        }
        .onAppear { focus = .call }
    }

    private var frequencyBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(formatFrequency(radio.freqA))
                .font(.system(size: 40, weight: .medium, design: .monospaced))
            Text("MHz").font(.title3).foregroundStyle(.secondary)
            ChipTag(text: BandPlan.name(for: radio.freqA), color: Color.orange.opacity(0.25))
            ChipTag(text: modeLabel, color: Color.blue.opacity(0.2))
            if radio.txState != 0 {
                ChipTag(text: "TX", color: .red).foregroundStyle(.white)
            }
        }
    }

    private func sentText(_ s: ContestSession) -> String {
        s.isSerial ? String(format: "%03d", log.nextSerial(for: s.id)) : (s.exchangeSent.isEmpty ? "–" : s.exchangeSent)
    }

    private func entryRow(_ s: ContestSession) -> some View {
        let dupe = currentDupe(s)
        return HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rufzeichen").font(.caption).foregroundStyle(.secondary)
                TextField("Rufzeichen", text: $call)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .labelsHidden()
                    .focused($focus, equals: .call)
                    .frame(width: 260)
                    .onSubmit {
                        if exch.trimmingCharacters(in: .whitespaces).isEmpty { focus = .exch } else { logNow(s) }
                    }
                    .onExitCommand(perform: clearEntry)
                    .onChange(of: call) { _, new in
                        let c = cleanCall(new)
                        if c != new { call = c }
                    }
            }
            LabeledField(title: "RST gesendet", text: $rstSent, prompt: defaultRST, width: 70, mono: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.isSerial ? "Nr. gesendet" : "Gesendet").font(.caption).foregroundStyle(.secondary)
                Text(sentText(s))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 70, alignment: .leading)
            }
            LabeledField(title: "RST empfangen", text: $rstRcvd, prompt: defaultRST, width: 70, mono: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(s.exchangeLabel) empfangen").font(.caption).foregroundStyle(.secondary)
                TextField(s.exchangeLabel, text: $exch)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .labelsHidden()
                    .focused($focus, equals: .exch)
                    .frame(width: 140)
                    .onSubmit { logNow(s) }
                    .onExitCommand(perform: clearEntry)
                    .onChange(of: exch) { _, new in
                        let u = new.uppercased()
                        if u != new { exch = u }
                    }
            }
            Button { logNow(s) } label: {
                Label(dupe != nil ? "Log (Dupe)" : "Log", systemImage: "square.and.pencil")
                    .font(.title3.bold())
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(dupe != nil ? Color.orange : Color.accentColor)
            .controlSize(.large)
            .disabled(!canLog)
        }
    }

    private func currentDupe(_ s: ContestSession) -> QSO? {
        call.isEmpty ? nil : log.dupe(call: call, freqHz: radio.freqA, mode: modeLabel, contest: s.id)
    }

    @ViewBuilder private func statusLine(_ s: ContestSession) -> some View {
        if !radio.isConnected {
            Label("Funkgerät nicht verbunden – Frequenz und Modus unbekannt, Loggen gesperrt", systemImage: "bolt.horizontal.circle")
                .foregroundStyle(.secondary)
        } else if !call.isEmpty {
            let inContest = log.qsos(inContest: s.id).filter { $0.call == call }
            if let d = currentDupe(s) {
                Label("DUPE – \(call) bereits um \(d.timeText) UTC auf \(d.band) gearbeitet (\(d.group.rawValue), empf. \(d.exchRcvd))",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if !inContest.isEmpty {
                let list = inContest.map { "\($0.band) \($0.mode)" }.joined(separator: ", ")
                Label("\(call) im Contest schon auf: \(list) – hier neu", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if let prev = log.worked(call).last {
                Label("\(call) neu im Contest · im Logbuch zuletzt \(prev.dateText) \(prev.band)"
                      + (prev.name.isEmpty ? "" : " · \(prev.name)"), systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("\(call) – noch nicht gearbeitet", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        } else if let last = log.qsos(inContest: s.id).last {
            Label("Zuletzt: \(last.call) · \(last.sentExchangeText) / \(last.exchRcvd) · \(last.freqKHzText) kHz · \(last.mode) · \(last.timeText) UTC",
                  systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            Text("Noch keine QSOs in diesem Contest. Rufzeichen → Return → Exchange → Return.")
                .foregroundStyle(.secondary)
        }
    }

    private func summary(_ s: ContestSession) -> some View {
        let list = log.qsos(inContest: s.id)
        let names = BandPlan.bands.map(\.name) + ["GEN"]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("QSOs: \(list.count)").font(.headline)
                ForEach(names, id: \.self) { n in
                    let c = list.filter { $0.band == n }.count
                    if c > 0 {
                        Text("\(n): \(c)")
                            .font(.callout.monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                if !s.cabrillo.isEmpty {
                    Text("Cabrillo: \(s.cabrillo)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func table(_ s: ContestSession) -> some View {
        let rows = Array(log.qsos(inContest: s.id).reversed())
        return VStack(alignment: .leading, spacing: 6) {
            Table(rows, selection: $selection) {
                TableColumn("Nr.") { q in Text(q.serialSent > 0 ? String(q.serialSent) : "").monospacedDigit() }
                    .width(min: 36, ideal: 44, max: 60)
                TableColumn("Datum / UTC") { q in Text("\(q.dateText) \(q.timeText)").monospacedDigit() }
                    .width(min: 130, ideal: 150, max: 170)
                TableColumn("Rufzeichen") { q in
                    Text(q.call).font(.system(.body, design: .monospaced).bold())
                }
                TableColumn("kHz") { q in Text(q.freqKHzText).monospacedDigit() }
                    .width(min: 70, ideal: 90, max: 120)
                TableColumn("Band") { q in Text(q.band) }
                    .width(min: 40, ideal: 50, max: 70)
                TableColumn("Modus") { q in Text(q.mode) }
                    .width(min: 50, ideal: 70, max: 100)
                TableColumn("RST s") { q in Text(q.rstSentOrDefault).monospacedDigit() }
                    .width(min: 36, ideal: 44, max: 60)
                TableColumn("Gesendet") { q in Text(q.sentExchangeText).monospaced() }
                    .width(min: 50, ideal: 70, max: 100)
                TableColumn("RST r") { q in Text(q.rstRcvdOrDefault).monospacedDigit() }
                    .width(min: 36, ideal: 44, max: 60)
                TableColumn("Empfangen") { q in Text(q.exchRcvd).monospaced() }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first {
                    Button("Bearbeiten …") { editing = log.qsos.first { $0.id == id } }
                    Button("Frequenz einstellen") {
                        if let q = log.qsos.first(where: { $0.id == id }) { radio.setFrequencyA(hz: q.freqHz) }
                    }
                }
            } primaryAction: { ids in
                if let id = ids.first { editing = log.qsos.first { $0.id == id } }
            }
            .frame(minHeight: 160)
            HStack {
                Button("Bearbeiten …") { editing = log.qsos.first { $0.id == selection } }
                    .disabled(selection == nil)
                Button("Ausgewähltes QSO löschen …", role: .destructive) { confirmDelete = true }
                    .disabled(selection == nil)
                Spacer()
                Text("Neueste zuerst · Doppelklick zum Bearbeiten")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("QSO löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                if let id = selection {
                    log.remove(id: id)
                    selection = nil
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Eintrag wird aus dem Logbuch entfernt.")
        }
    }

    // MARK: Aktionen

    private func logNow(_ s: ContestSession) {
        guard canLog else { return }
        var q = QSO(call: call, freqHz: radio.freqA, mode: modeLabel)
        q.contest = s.id
        if s.isSerial {
            q.serialSent = log.nextSerial(for: s.id)
        } else {
            q.exchSent = s.exchangeSent
        }
        q.rstSent = rstSent.trimmingCharacters(in: .whitespaces).isEmpty ? defaultRST : rstSent
        q.rstRcvd = rstRcvd.trimmingCharacters(in: .whitespaces).isEmpty ? defaultRST : rstRcvd
        q.exchRcvd = exch.trimmingCharacters(in: .whitespaces)
        if log.add(q) { clearEntry() }
    }

    private func clearEntry() {
        call = ""
        exch = ""
        rstSent = ""
        rstRcvd = ""
        focus = .call
    }
}

// MARK: - Contest-Sitzung anlegen / bearbeiten

/// Dialog für eine Contest-Sitzung: Vorlage, Name, Cabrillo-Bezeichnung, Exchange-Regel und Kategorien.
struct ContestSessionSheet: View {
    @Environment(Logbook.self) private var log
    @Environment(\.dismiss) private var dismiss
    @State private var s: ContestSession
    @State private var template = ""
    @State private var confirmDelete = false
    let isNew: Bool

    init(session: ContestSession, isNew: Bool) {
        _s = State(initialValue: session)
        self.isNew = isNew
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Neuer Contest" : "Contest-Einstellungen").font(.title2.bold())
            Form {
                if isNew {
                    Picker("Vorlage", selection: $template) {
                        Text("– wählen –").tag("")
                        ForEach(ContestTemplate.all) { t in Text(t.title).tag(t.id) }
                    }
                    .onChange(of: template) { _, t in apply(t) }
                }
                TextField("Name", text: $s.name)
                TextField("Cabrillo CONTEST:", text: $s.cabrillo)
                Picker("Exchange", selection: $s.exchangeKind) {
                    Text("Laufende Nummer senden").tag("serial")
                    Text("Feste Angabe senden").tag("fixed")
                }
                if !s.isSerial {
                    TextField("Gesendet (Zone, DOK, Leistung …)", text: $s.exchangeSent)
                }
                TextField("Bezeichnung empfangenes Feld", text: $s.exchangeLabel)
                Section("Cabrillo-Kategorien") {
                    category("Operator", $s.catOperator, ["SINGLE-OP", "MULTI-OP", "CHECKLOG"])
                    category("Assisted", $s.catAssisted, ["NON-ASSISTED", "ASSISTED"])
                    category("Band", $s.catBand, ["ALL", "160M", "80M", "40M", "20M", "15M", "10M"])
                    category("Modus", $s.catMode, ["CW", "SSB", "RTTY", "DIGI", "FM", "MIXED"], auto: true)
                    category("Leistung", $s.catPower, ["QRP", "LOW", "HIGH"])
                    category("Station", $s.catStation, ["FIXED", "PORTABLE", "MOBILE", "EXPEDITION"])
                    category("Sender", $s.catTransmitter, ["ONE", "TWO", "LIMITED", "UNLIMITED", "SWL"])
                    TextField("LOCATION (z. B. DX)", text: $s.location)
                    TextField("OPERATORS (leer = eigenes Rufzeichen)", text: $s.operators)
                    TextField("SOAPBOX", text: $s.soapbox, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Contest löschen …", role: .destructive) { confirmDelete = true }
                        .disabled(!log.qsos(inContest: s.id).isEmpty)
                        .help("Nur möglich, solange der Contest keine QSOs enthält")
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Anlegen" : "Speichern") {
                    log.upsertContest(s)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(s.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 700)
        .confirmationDialog("Contest löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                log.removeContest(id: s.id)
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func category(_ title: String, _ binding: Binding<String>, _ options: [String], auto: Bool = false) -> some View {
        Picker(title, selection: binding) {
            if auto { Text("Automatisch").tag("") }
            ForEach(options, id: \.self) { o in Text(o).tag(o) }
        }
    }

    private func apply(_ id: String) {
        guard let t = ContestTemplate.all.first(where: { $0.id == id }) else { return }
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        s.name = t.cabrillo.isEmpty ? "" : "\(t.title) \(year)"
        s.cabrillo = t.cabrillo
        s.exchangeKind = t.serial ? "serial" : "fixed"
        s.exchangeSent = t.sent
        s.exchangeLabel = t.label
        s.catMode = t.mode
        s.location = t.location
    }
}
