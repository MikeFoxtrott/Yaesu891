import SwiftUI

// MARK: - Reiter „Logbuch“

/// Reiter „Logbuch“ für normale QSOs: Eingabe mit RST, Name, QTH, Locator, Leistung und Bemerkung,
/// Frequenz und Modus kommen vom Gerät (oder werden von Hand eingetragen). Liste mit Suche,
/// Bearbeiten, Löschen und ADIF-Export.
struct LogbookView: View {
    @Environment(Radio.self) private var radio
    @Environment(Logbook.self) private var log

    @State private var call = ""
    @State private var rstSent = ""
    @State private var rstRcvd = ""
    @State private var name = ""
    @State private var qth = ""
    @State private var locator = ""
    @State private var power = ""
    @State private var comment = ""
    /// Frequenz in kHz von Hand; leer = vom Gerät.
    @State private var freqText = ""
    /// Betriebsart von Hand (z. B. „FT8“); leer = vom Gerät.
    @State private var modeText = ""

    @State private var search = ""
    @State private var showContest = false
    @State private var selection: UUID?
    @State private var editing: QSO?
    @State private var showStation = false
    @State private var confirmDelete = false
    @FocusState private var callFocused: Bool

    // MARK: Werte

    private var effectiveFreq: Int? {
        let t = freqText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let khz = Double(t), khz > 0 { return Int((khz * 1000).rounded()) }
        if radio.isConnected && radio.freqA > 0 { return radio.freqA }
        return nil
    }

    private var effectiveMode: String {
        let m = modeText.trimmingCharacters(in: .whitespaces).uppercased()
        if !m.isEmpty { return m }
        return radio.isConnected ? rigModeLabel(radio) : ""
    }

    private var defaultRST: String { ModeGroup.of(effectiveMode).defaultRST }

    private var canLog: Bool {
        call.count >= 3 && effectiveFreq != nil && !effectiveMode.isEmpty
    }

    private var rows: [QSO] {
        var l = showContest ? log.qsos : log.normalQSOs
        let s = search.trimmingCharacters(in: .whitespaces).uppercased()
        if !s.isEmpty {
            l = l.filter {
                $0.call.contains(s) || $0.name.uppercased().contains(s)
                    || $0.qth.uppercased().contains(s) || $0.locator.uppercased().contains(s)
                    || $0.comment.uppercased().contains(s)
            }
        }
        return l.reversed()
    }

    // MARK: Ansicht

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            fileBar
            LogMessages()
            Divider()
            frequencyRow
            entryGrid
            workedLine
            Divider()
            filterBar
            table
        }
        .padding(20)
        .onAppear { callFocused = true }
        .sheet(item: $editing) { q in QSOEditSheet(qso: q) }
        .sheet(isPresented: $showStation) { StationSheet() }
    }

    private var fileBar: some View {
        HStack(spacing: 10) {
            Text("Logbuch:").font(.headline)
            Text(log.fileURL.path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Öffnen …") { log.chooseExisting() }
            Button("Neu …") { log.chooseNew() }
            Button("Im Finder zeigen") { log.revealInFinder() }
            Button("Station …") { showStation = true }
        }
    }

    private var frequencyRow: some View {
        HStack(alignment: .bottom, spacing: 14) {
            if let f = effectiveFreq {
                Text(formatFrequency(f))
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                Text("MHz").foregroundStyle(.secondary)
                ChipTag(text: BandPlan.name(for: f), color: Color.orange.opacity(0.25))
            } else {
                Text("Keine Frequenz – Gerät verbinden oder Frequenz eintragen")
                    .foregroundStyle(.secondary)
            }
            if !effectiveMode.isEmpty {
                ChipTag(text: effectiveMode, color: Color.blue.opacity(0.2))
            }
            Spacer()
            LabeledField(title: "Frequenz kHz (leer = Gerät)", text: $freqText,
                         prompt: radio.isConnected ? String(format: "%.2f", Double(radio.freqA) / 1000) : "z. B. 14250",
                         width: 170, mono: true)
            LabeledField(title: "Modus (leer = Gerät)", text: $modeText,
                         prompt: radio.isConnected ? rigModeLabel(radio) : "z. B. FT8", width: 130, mono: true)
        }
    }

    private var entryGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rufzeichen").font(.caption).foregroundStyle(.secondary)
                    TextField("Rufzeichen", text: $call)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .labelsHidden()
                        .focused($callFocused)
                        .frame(width: 240)
                        .onExitCommand(perform: clearEntry)
                        .onChange(of: call) { _, new in
                            let c = cleanCall(new)
                            if c != new { call = c }
                        }
                }
                LabeledField(title: "RST gesendet", text: $rstSent, prompt: defaultRST, width: 80, mono: true)
                LabeledField(title: "RST empfangen", text: $rstRcvd, prompt: defaultRST, width: 80, mono: true)
                LabeledField(title: "Leistung W", text: $power, prompt: "100", width: 80, mono: true)
                Button(action: logNow) {
                    Label("Log", systemImage: "square.and.pencil")
                        .font(.title3.bold())
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canLog)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            HStack(alignment: .bottom, spacing: 12) {
                LabeledField(title: "Name", text: $name, width: 180)
                LabeledField(title: "QTH", text: $qth, width: 200)
                LabeledField(title: "Locator", text: $locator, prompt: "JN49", width: 100, mono: true)
                LabeledField(title: "Bemerkung", text: $comment)
            }
        }
        .onSubmit(logNow)
    }

    @ViewBuilder private var workedLine: some View {
        if call.count >= 3 {
            let earlier = log.worked(call)
            if earlier.isEmpty {
                Label("\(call) – noch nicht im Logbuch", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                let last = earlier.last!
                let extra = [last.name, last.qth, last.locator].filter { !$0.isEmpty }.joined(separator: " · ")
                Label("\(call) schon \(earlier.count)× gearbeitet, zuletzt \(last.dateText) \(last.band) \(last.mode)"
                      + (extra.isEmpty ? "" : " – \(extra)"), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Return oder ⌘Return loggt mit UTC-Zeit. Esc leert die Eingabe.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            TextField("Suchen (Rufzeichen, Name, QTH, Locator)", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            Toggle("Contest-QSOs zeigen", isOn: $showContest)
            Text("\(rows.count) QSOs").foregroundStyle(.secondary)
            Spacer()
            Button("Bearbeiten …") { editing = log.qsos.first { $0.id == selection } }
                .disabled(selection == nil)
            Button("Löschen …", role: .destructive) { confirmDelete = true }
                .disabled(selection == nil)
            Button("ADIF exportieren …") { log.exportADIF(rows.reversed()) }
                .disabled(rows.isEmpty)
                .help("Exportiert die angezeigten QSOs (Filter beachten) als ADIF-Datei")
        }
        .confirmationDialog("QSO löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                if let id = selection {
                    log.remove(id: id)
                    selection = nil
                }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Datum") { q in Text(q.dateText).monospacedDigit() }
                .width(min: 80, ideal: 90, max: 110)
            TableColumn("UTC") { q in Text(q.timeText).monospacedDigit() }
                .width(min: 60, ideal: 70, max: 90)
            TableColumn("Rufzeichen") { q in
                Text(q.call).font(.system(.body, design: .monospaced).bold())
            }
            .width(min: 80, ideal: 110)
            TableColumn("kHz") { q in Text(q.freqKHzText).monospacedDigit() }
                .width(min: 70, ideal: 90, max: 120)
            TableColumn("Band") { q in Text(q.band) }
                .width(min: 40, ideal: 50, max: 70)
            TableColumn("Modus") { q in Text(q.mode) }
                .width(min: 50, ideal: 70, max: 100)
            TableColumn("RST s/r") { q in Text("\(q.rstSentOrDefault)/\(q.rstRcvdOrDefault)").monospacedDigit() }
                .width(min: 60, ideal: 70, max: 90)
            TableColumn("Name") { q in Text(q.name) }
            TableColumn("QTH") { q in Text(q.qth) }
            TableColumn("Info") { q in Text(info(q)).foregroundStyle(.secondary) }
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
        .frame(minHeight: 180)
    }

    private func info(_ q: QSO) -> String {
        var parts: [String] = []
        if !q.locator.isEmpty { parts.append(q.locator) }
        if !q.power.isEmpty { parts.append("\(q.power) W") }
        if !q.comment.isEmpty { parts.append(q.comment) }
        if q.isContest { parts.append("Contest: \(log.contest(id: q.contest)?.name ?? "?")") }
        return parts.joined(separator: " · ")
    }

    // MARK: Aktionen

    private func logNow() {
        guard canLog, let f = effectiveFreq else { return }
        var q = QSO(call: call, freqHz: f, mode: effectiveMode)
        q.rstSent = rstSent.trimmingCharacters(in: .whitespaces).isEmpty ? defaultRST : rstSent
        q.rstRcvd = rstRcvd.trimmingCharacters(in: .whitespaces).isEmpty ? defaultRST : rstRcvd
        q.name = name.trimmingCharacters(in: .whitespaces)
        q.qth = qth.trimmingCharacters(in: .whitespaces)
        q.locator = locator.trimmingCharacters(in: .whitespaces).uppercased()
        q.power = power.trimmingCharacters(in: .whitespaces)
        q.comment = comment.trimmingCharacters(in: .whitespaces)
        if log.add(q) {
            clearEntry()
        }
    }

    /// Leert die QSO-Felder; Leistung sowie Frequenz/Modus von Hand bleiben stehen.
    private func clearEntry() {
        call = ""
        rstSent = ""
        rstRcvd = ""
        name = ""
        qth = ""
        locator = ""
        comment = ""
        callFocused = true
    }
}

// MARK: - QSO bearbeiten

/// Dialog zum Bearbeiten eines QSOs (normal oder Contest).
struct QSOEditSheet: View {
    @Environment(Logbook.self) private var log
    @Environment(\.dismiss) private var dismiss
    @State private var draft: QSO
    @State private var freqText: String
    @State private var serialText: String

    init(qso: QSO) {
        _draft = State(initialValue: qso)
        _freqText = State(initialValue: qso.freqKHzText)
        _serialText = State(initialValue: qso.serialSent > 0 ? String(qso.serialSent) : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("QSO bearbeiten").font(.title2.bold())
            Form {
                DatePicker("Datum / Zeit (UTC)", selection: $draft.time,
                           displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                TextField("Rufzeichen", text: $draft.call)
                TextField("Frequenz kHz", text: $freqText)
                TextField("Modus", text: $draft.mode)
                TextField("RST gesendet", text: $draft.rstSent)
                TextField("RST empfangen", text: $draft.rstRcvd)
                if draft.isContest {
                    TextField("Nr. gesendet", text: $serialText)
                    TextField("Exchange gesendet", text: $draft.exchSent)
                    TextField("Exchange empfangen", text: $draft.exchRcvd)
                }
                TextField("Name", text: $draft.name)
                TextField("QTH", text: $draft.qth)
                TextField("Locator", text: $draft.locator)
                TextField("Leistung W", text: $draft.power)
                TextField("Bemerkung", text: $draft.comment)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: draft.isContest ? 640 : 560)
    }

    private func save() {
        let t = freqText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let khz = Double(t), khz > 0 {
            draft.freqHz = Int((khz * 1000).rounded())
            draft.band = BandPlan.name(for: draft.freqHz)
        }
        draft.serialSent = Int(serialText.trimmingCharacters(in: .whitespaces)) ?? 0
        draft.locator = draft.locator.uppercased()
        draft.mode = draft.mode.uppercased()
        if log.update(draft) { dismiss() }
    }
}

// MARK: - Station

/// Dialog für die eigenen Stationsdaten (Cabrillo-Kopf, ADIF).
struct StationSheet: View {
    @Environment(Logbook.self) private var log
    @Environment(\.dismiss) private var dismiss
    @State private var s = Station()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Eigene Station").font(.title2.bold())
            Form {
                TextField("Rufzeichen", text: $s.callsign)
                TextField("Name", text: $s.name)
                TextField("Locator", text: $s.locator)
                TextField("Straße", text: $s.address)
                TextField("PLZ", text: $s.postcode)
                TextField("Ort", text: $s.city)
                TextField("Land", text: $s.country)
                TextField("E-Mail", text: $s.email)
                TextField("Club", text: $s.club)
            }
            .formStyle(.grouped)
            Text("Wird für den Cabrillo-Kopf und als STATION_CALLSIGN / MY_GRIDSQUARE im ADIF verwendet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") {
                    log.updateStation(s)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 560)
        .onAppear { s = log.station }
    }
}
