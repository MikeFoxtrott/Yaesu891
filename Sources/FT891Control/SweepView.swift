import SwiftUI
import Charts

/// Farbe für ein SWR: grün bis 1,5, gelb bis 2, orange bis 3, darüber rot.
func swrTint(_ s: Double) -> Color {
    if s < 1.5 { return .green }
    if s < 2.0 { return .yellow }
    if s < 3.0 { return .orange }
    return .red
}

/// Stufenlose Farbe für den Wasserfall: 1,0 grün → 3,0 und mehr rot.
private func swrHeat(_ s: Double) -> Color {
    let t = min(max((s - 1.0) / 2.0, 0), 1)
    return Color(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.9)
}

/// Reiter „SWR-Sweep“: Messbereich wählen, Kurve, Kennwerte und Verlauf als Wasserfall.
struct SweepView: View {
    @Environment(Radio.self) private var radio
    @Environment(SweepController.self) private var sweep
    @State private var confirmClear = false

    /// Angezeigter Durchlauf: der laufende, sonst der gewählte, sonst der neueste.
    private var shownRun: SweepRun? {
        if let r = sweep.liveRun { return r }
        if let id = sweep.selectedID, let r = sweep.runs.first(where: { $0.id == id }) { return r }
        return sweep.runs.last
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingsCard
                HStack(alignment: .top, spacing: 12) {
                    chartCard.frame(maxWidth: .infinity)
                    resultCard.frame(width: 250)
                }
                if let run = shownRun, sweep.compatibleRuns(run).count >= 2 {
                    WaterfallCard(runs: Array(sweep.compatibleRuns(run).suffix(40).reversed()),
                                  selectedID: run.id)
                }
            }
            .padding(14)
        }
        .confirmationDialog("Alle gespeicherten Sweeps löschen?", isPresented: $confirmClear) {
            Button("Löschen", role: .destructive) { sweep.clearHistory() }
        }
    }

    // MARK: Einstellungen

    private var settingsCard: some View {
        @Bindable var s = sweep
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        label("Band")
                        ForEach(BandPlan.bands) { b in
                            Toggle(b.name, isOn: Binding(get: { sweep.presetBand == b.name },
                                                         set: { _ in sweep.applyPreset(b) }))
                                .toggleStyle(.button)
                        }
                    }
                    HStack(spacing: 14) {
                        HStack(spacing: 4) {
                            label("Bereich")
                            TextField("Start", value: $s.startKHz, format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            Text("–")
                            TextField("Stopp", value: $s.stopKHz, format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            Text("kHz").foregroundStyle(.secondary)
                        }
                        Picker("Schritt", selection: $s.stepKHz) {
                            ForEach(SweepController.stepChoices, id: \.self) { v in
                                Text("\(fmtKHz(v)) kHz").tag(v)
                            }
                        }
                        .frame(width: 140)
                        Text("\(sweep.pointCount) Punkte · ca. \(sweep.estimatedSeconds) s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 14) {
                        HStack(spacing: 4) {
                            label("Senden")
                            Picker("Leistung", selection: $s.powerW) {
                                ForEach(SweepController.powerChoices, id: \.self) { Text("\($0) W").tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 70)
                        }
                        Picker("Träger", selection: $s.carrierMode) {
                            ForEach(SweepController.carrierModes) { Text($0.label).tag($0.code) }
                        }
                        .frame(width: 150)
                        .help("Betriebsart, in der das Gerät beim Senden einen Träger abgibt. Liefert eine Art kein Signal, bricht der Sweep mit einem Hinweis ab.")
                        Picker("Abbruch über SWR", selection: $s.abortSWR) {
                            ForEach(SweepController.abortChoices, id: \.self) { Text(fmtKHz($0)).tag($0) }
                        }
                        .frame(width: 180)
                        Toggle("Wiederholen alle", isOn: $s.repeatOn)
                        Stepper("\(sweep.repeatMinutes) min", value: $s.repeatMinutes, in: 1...120)
                            .disabled(!sweep.repeatOn)
                    }
                }
                .disabled(sweep.running)

                Divider()

                HStack(spacing: 10) {
                    Toggle("Bereich ist frei, Antenne oder Dummy Load angeschlossen", isOn: $s.confirmed)
                        .disabled(sweep.running)
                    Spacer()
                    if sweep.running {
                        ProgressView(value: sweep.progress).frame(width: 140)
                        Button("Stopp (Esc)") { sweep.stop() }
                            .keyboardShortcut(.cancelAction)
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    } else {
                        Button("Sweep starten") { sweep.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(sweep.validationMessage != nil)
                    }
                }
                statusLine
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("SWR-Sweep").font(.subheadline.bold())
        }
    }

    @ViewBuilder private var statusLine: some View {
        if !sweep.running, let msg = sweep.validationMessage {
            Label(msg, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !sweep.status.isEmpty {
            Text(sweep.status)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        if !sweep.running {
            Text("Pro Messpunkt sendet das Gerät ca. 0,4 s mit der gewählten Leistung. Frequenz, Betriebsart und Leistung werden danach wiederhergestellt.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func label(_ t: String) -> some View {
        Text(t)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }

    // MARK: Diagramm

    private var chartCard: some View {
        @Bindable var s = sweep
        return GroupBox {
            if let run = shownRun, !run.points.isEmpty {
                SweepChart(run: run, currentHz: sweep.currentHz)
                    .frame(height: 300)
            } else {
                ContentUnavailableView("Noch keine Messung", systemImage: "waveform.path.ecg",
                                       description: Text("Bereich wählen, bestätigen und „Sweep starten“."))
                    .frame(height: 300)
            }
        } label: {
            HStack {
                Text("SWR-Kurve").font(.subheadline.bold())
                Spacer()
                if !sweep.runs.isEmpty {
                    Picker("Messung", selection: $s.selectedID) {
                        Text("Neueste").tag(UUID?.none)
                        ForEach(sweep.runs.reversed()) { r in
                            Text(runLabel(r)).tag(UUID?.some(r.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 280)
                    .disabled(sweep.running)
                }
            }
        }
    }

    private func runLabel(_ r: SweepRun) -> String {
        "\(r.date.formatted(date: .abbreviated, time: .shortened)) · \(fmtKHz(Double(r.startHz) / 1000))–\(fmtKHz(Double(r.stopHz) / 1000)) kHz"
    }

    // MARK: Kennwerte

    private var resultCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let run = shownRun, let best = run.best {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        GridRow {
                            key("Minimum")
                            Text(String(format: "%.2f : 1", best.swr))
                                .font(.system(.title3, design: .monospaced).bold())
                                .foregroundStyle(swrTint(best.swr))
                        }
                        GridRow { key("bei"); val("\(fmtKHz(best.kHz)) kHz") }
                        GridRow { key("SWR ≤ 1,5"); val(spanText(run, 1.5)) }
                        GridRow { key("SWR ≤ 2,0"); val(spanText(run, 2.0)) }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow { key("Punkte"); val("\(run.points.count) · \(fmtKHz(Double(run.stepHz) / 1000)) kHz") }
                        GridRow { key("Leistung"); val("\(run.powerW) W") }
                        GridRow { key("Zeit"); val(run.date.formatted(date: .numeric, time: .shortened)) }
                    }
                    if let note = run.note {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    HStack {
                        Button("CSV …") { sweep.exportCSV(run) }
                        Button("Verlauf löschen …") { confirmClear = true }
                    }
                    .controlSize(.small)
                    .disabled(sweep.running)
                } else {
                    Text("Noch keine Werte.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Ergebnis").font(.subheadline.bold())
        }
    }

    private func key(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(.secondary)
    }

    private func val(_ t: String) -> some View {
        Text(t).font(.system(.callout, design: .monospaced)).monospacedDigit()
    }

    /// Bandbreite unter einer SWR-Grenze, z. B. `7.091–7.128 (37 kHz)`; „≥“, wenn sie über den Messbereich hinausgeht.
    private func spanText(_ run: SweepRun, _ limit: Double) -> String {
        guard let sp = run.span(below: limit) else { return "–" }
        let width = sp.hi - sp.lo
        let open = sp.openLo || sp.openHi
        return "\(fmtKHz(sp.lo))–\(fmtKHz(sp.hi))\n\(open ? "≥ " : "")\(fmtKHz(width)) kHz"
    }
}

// MARK: - Kurve

/// SWR über der Frequenz mit Grenzlinien 1,5 und 2,0, markiertem Minimum und der gerade gemessenen Frequenz.
struct SweepChart: View {
    let run: SweepRun
    let currentHz: Int?

    private var yMax: Double {
        let m = run.points.map(\.swr).max() ?? 1
        return min(5, max(3, m + 0.2))
    }

    var body: some View {
        let top = yMax
        let best = run.best
        Chart {
            RuleMark(y: .value("SWR", 1.5))
                .foregroundStyle(Color.green.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            RuleMark(y: .value("SWR", 2.0))
                .foregroundStyle(Color.orange.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(run.points) { p in
                LineMark(x: .value("Frequenz", p.kHz), y: .value("SWR", min(p.swr, top)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                PointMark(x: .value("Frequenz", p.kHz), y: .value("SWR", min(p.swr, top)))
                    .foregroundStyle(swrTint(p.swr))
                    .symbolSize(28)
            }
            if let best {
                PointMark(x: .value("Frequenz", best.kHz), y: .value("SWR", best.swr))
                    .foregroundStyle(Color.green.opacity(0.25))
                    .symbolSize(220)
                    .annotation(position: .top, spacing: 4) {
                        Text(String(format: "%.2f", best.swr) + " · " + fmtKHz(best.kHz))
                            .font(.caption.bold().monospacedDigit())
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.background, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
            if let c = currentHz {
                RuleMark(x: .value("Frequenz", Double(c) / 1000))
                    .foregroundStyle(Color.blue.opacity(0.5))
            }
        }
        .chartXScale(domain: Double(run.startHz) / 1000 ... Double(run.stopHz) / 1000)
        .chartYScale(domain: 1.0 ... top)
        .chartXAxisLabel("kHz")
        .chartYAxisLabel("SWR")
    }
}

// MARK: - Wasserfall

/// Wiederholte Sweeps desselben Bereichs untereinander (neueste oben); die Farbe zeigt das SWR.
struct WaterfallCard: View {
    let runs: [SweepRun]
    let selectedID: UUID
    private let rowH: CGFloat = 12

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(runs) { r in
                            Text(r.date.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(r.id == selectedID ? Color.primary : Color.secondary)
                                .frame(height: rowH)
                        }
                    }
                    .frame(width: 44, alignment: .trailing)
                    Canvas { ctx, size in
                        guard let first = runs.first, first.stepHz > 0 else { return }
                        let cols = max(1, (first.stopHz - first.startHz) / first.stepHz + 1)
                        let cw = size.width / CGFloat(cols)
                        for (ri, r) in runs.enumerated() {
                            for p in r.points {
                                let ci = (p.hz - r.startHz) / r.stepHz
                                let rect = CGRect(x: CGFloat(ci) * cw, y: CGFloat(ri) * rowH,
                                                  width: cw + 0.5, height: rowH - 1)
                                ctx.fill(Path(rect), with: .color(swrHeat(p.swr)))
                            }
                        }
                    }
                    .frame(height: CGFloat(runs.count) * rowH)
                }
                HStack {
                    if let f = runs.first {
                        Text("\(fmtKHz(Double(f.startHz) / 1000)) kHz")
                        Spacer()
                        Text("\(fmtKHz(Double(f.stopHz) / 1000)) kHz")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 50)
                HStack(spacing: 10) {
                    ForEach([1.0, 1.5, 2.0, 3.0], id: \.self) { v in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2).fill(swrHeat(v)).frame(width: 14, height: 8)
                            Text(v >= 3 ? "≥ 3" : fmtKHz(v)).font(.caption2)
                        }
                    }
                    Text("Fehlende Felder: Durchlauf vorzeitig beendet").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.leading, 50)
            }
        } label: {
            Text("Verlauf · \(runs.count) Durchläufe, neueste oben").font(.subheadline.bold())
        }
    }
}
