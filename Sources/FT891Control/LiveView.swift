import SwiftUI

/// Formatiert eine Frequenz mit Punkten als Tausendertrennung in MHz, z. B. `14.250.000`.
/// - Parameter hz: Frequenz in Hz.
func formatFrequency(_ hz: Int) -> String {
    let mhz = hz / 1_000_000
    let khz = (hz / 1_000) % 1_000
    let rest = hz % 1_000
    return String(format: "%ld.%03ld.%03ld", mhz, khz, rest)
}

/// Waagerechter Balken für ein Messinstrument mit Titel links und Wert rechts.
struct MeterBar: View {
    let title: String
    let value: Double        // 0...1
    let text: String
    var tint: Color = .green

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.bold())
                .frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 10)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 110, alignment: .trailing)
        }
    }
}

/// Bandtaste: Beschriftung, Bandcode des Geräts (`BS`-Befehl) und Bandname im ``BandPlan``.
private struct BandButton: Identifiable {
    let label: String
    let code: Int
    let plan: String
    var id: String { label }
}

/// Schrittknopf: Beschriftung und Frequenzänderung in Hz.
private struct StepButton: Identifiable {
    let label: String
    let delta: Int
    var id: String { label }
}

/// Schmaler Messbalken ohne Beschriftung (für das Messwert-Raster).
private struct MeterTrack: View {
    let value: Double   // 0...1
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// Live-Reiter: Bandleiste, Frequenz mit Drehregler, Messwerte, Sendesteuerung und Schnellzugriff.
///
/// Aufbau (kompakt, von oben nach unten): Frequenzzeile mit Betriebsart und Status-Etiketten, Eingabe- und
/// Schrittzeile, Betriebsart/VFO, Bandtasten (aktuelles Band hervorgehoben); darunter die Messwerte als Raster
/// (Titel · Balken · Wert · Zusatz) und daneben die Sendesteuerung.
struct LiveView: View {
    @Environment(Radio.self) private var radio
    @State private var freqText = ""

    /// Bandtasten mit den Bandcodes des Geräts (`BS`-Befehl); Code 2 (5 MHz) ist hier nicht belegt.
    private let bands: [BandButton] = [
        BandButton(label: "160m", code: 0, plan: "160m"), BandButton(label: "80m", code: 1, plan: "80m"),
        BandButton(label: "40m", code: 3, plan: "40m"), BandButton(label: "30m", code: 4, plan: "30m"),
        BandButton(label: "20m", code: 5, plan: "20m"), BandButton(label: "17m", code: 6, plan: "17m"),
        BandButton(label: "15m", code: 7, plan: "15m"), BandButton(label: "12m", code: 8, plan: "12m"),
        BandButton(label: "10m", code: 9, plan: "10m"), BandButton(label: "6m", code: 10, plan: "6m"),
        BandButton(label: "GEN", code: 11, plan: "GEN"), BandButton(label: "MW", code: 12, plan: "MW")
    ]

    /// Schrittknöpfe neben dem Frequenzfeld.
    private let steps: [StepButton] = [
        StepButton(label: "−10k", delta: -10_000), StepButton(label: "−1k", delta: -1_000),
        StepButton(label: "−100", delta: -100), StepButton(label: "+100", delta: 100),
        StepButton(label: "+1k", delta: 1_000), StepButton(label: "+10k", delta: 10_000)
    ]

    /// Name der aktuellen Betriebsart (z. B. `USB`).
    private var modeLabel: String {
        Catalog.modes.first { $0.code == radio.mode }?.label ?? radio.mode
    }

    /// Band der aktuellen Frequenz in der Schreibweise der Bandtasten.
    private var currentBand: String {
        let f = radio.freqA
        if let b = BandPlan.band(for: f) { return b.name }
        if f >= 520_000 && f <= 1_710_000 { return "MW" }
        return "GEN"
    }

    private var isTX: Bool { radio.txState != 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LiveBandStrip()
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        frequencyHeader
                        entryRow
                        modeRow
                        bandRow
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    TuningKnob(size: 120)
                }
                HStack(alignment: .top, spacing: 12) {
                    metersCard.frame(maxWidth: .infinity)
                    txCard.frame(width: 270)
                }
                QuickAccessView()
            }
            .padding(14)
            .disabled(!radio.isConnected || radio.sweepRunning)
        }
    }

    // MARK: Frequenz

    /// Kleines Etikett (Betriebsart, TX, Sweep).
    private func tag(_ text: String, fill: Color, fg: Color = .primary) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(fill, in: RoundedRectangle(cornerRadius: 5))
    }

    /// Hauptfrequenz, Betriebsart, Status-Etiketten und VFO B.
    private var frequencyHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(formatFrequency(radio.freqA))
                .font(.system(size: 44, weight: .medium, design: .monospaced))
                .monospacedDigit()
            Text("MHz").font(.callout).foregroundStyle(.secondary)
            tag(modeLabel, fill: Color.blue.opacity(0.2))
            if radio.vfoState != "0" {
                Text("M-CH \(radio.memChannel)").font(.callout).foregroundStyle(.secondary)
            }
            if radio.clarOn {
                Text("CLAR \(radio.clarOffset >= 0 ? "+" : "")\(radio.clarOffset) Hz")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if isTX { tag("TX", fill: .red, fg: .white) }
            if radio.sweepRunning { tag("SWEEP", fill: Color.orange.opacity(0.35)) }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text("VFO B").font(.caption2).foregroundStyle(.secondary)
                Text(formatFrequency(radio.freqB))
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
            }
        }
    }

    /// Frequenzeingabe und Schrittknöpfe.
    private var entryRow: some View {
        HStack(spacing: 6) {
            TextField("MHz, z. B. 14,250", text: $freqText)
                .frame(width: 150)
                .onSubmit(applyFrequency)
            Button("Setzen", action: applyFrequency)
            Divider().frame(height: 16)
            ForEach(steps) { s in
                Button(s.label) { radio.setFrequencyA(hz: radio.freqA + s.delta) }
            }
        }
        .controlSize(.small)
    }

    /// Betriebsart und VFO-Tasten.
    private var modeRow: some View {
        HStack(spacing: 6) {
            Picker("Betriebsart", selection: Binding(get: { radio.mode }, set: { radio.setMode($0) })) {
                ForEach(Catalog.modes) { m in
                    Text(m.label).tag(m.code)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            Divider().frame(height: 16)
            Button("A=B") { radio.sendSimple("AB;") }
            Button("A/B") { radio.sendSimple("SV;") }
            Button("B→A") { radio.sendSimple("BA;") }
        }
        .controlSize(.small)
    }

    /// Bandtasten; das Band der aktuellen Frequenz ist hervorgehoben.
    private var bandRow: some View {
        HStack(spacing: 4) {
            ForEach(bands) { b in
                Toggle(b.label, isOn: Binding(get: { currentBand == b.plan },
                                              set: { _ in radio.selectBand(b.code) }))
                    .toggleStyle(.button)
            }
        }
        .controlSize(.small)
    }

    /// Übernimmt die Eingabe im Frequenzfeld.
    ///
    /// Akzeptiert MHz mit Komma oder Punkt (`14,2500`), Werte ab 1000 als Hz sowie Schreibweisen mit
    /// Tausenderpunkten (`14.250.000`).
    private func applyFrequency() {
        let cleaned = freqText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let hz: Int
        if cleaned.filter({ $0 == "." }).count > 1, let v = Int(cleaned.replacingOccurrences(of: ".", with: "")) {
            hz = v
        } else if let d = Double(cleaned) {
            hz = d >= 1000 ? Int(d) : Int((d * 1_000_000).rounded())
        } else {
            return
        }
        radio.setFrequencyA(hz: hz)
        freqText = ""
    }

    // MARK: Messwerte

    /// Prozent vom Skalenendwert.
    private func pct(_ raw: Int) -> String { "\(raw * 100 / 255) %" }

    /// Messwerte als Raster: S-Meter (Empfang), dann PO, SWR, ALC, COMP, ID (nur beim Senden).
    /// Nicht aktive Instrumente sind abgeblendet.
    private var metersCard: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                meterRow("S", raw: radio.sRaw, text: isTX ? "–" : Meter.sText(radio.sRaw), tint: .green, active: !isTX)
                Divider().gridCellUnsizedAxes(.horizontal)
                meterRow("PO", raw: radio.poRaw, text: isTX ? pct(radio.poRaw) : "–", tint: .blue, active: isTX)
                meterRow("SWR", raw: radio.swrRaw,
                         text: isTX ? String(format: "%.1f", Meter.swr(radio.swrRaw)) : "–",
                         tint: swrTint(Meter.swr(radio.swrRaw)), active: isTX,
                         extra: radio.hiSWR ? "HI-SWR!" : (radio.swrPeak > 0 ? String(format: "Spitze %.1f", Meter.swr(radio.swrPeak)) : ""),
                         extraColor: radio.hiSWR ? .red : .secondary,
                         alwaysShowExtra: true)
                meterRow("ALC", raw: radio.alcRaw, text: isTX ? pct(radio.alcRaw) : "–", tint: .purple, active: isTX)
                meterRow("COMP", raw: radio.compRaw, text: isTX ? pct(radio.compRaw) : "–", tint: .teal, active: isTX)
                meterRow("ID", raw: radio.idRaw, text: isTX ? pct(radio.idRaw) : "–", tint: .gray, active: isTX)
            }
            .padding(.vertical, 2)
        } label: {
            Text("Messwerte").font(.subheadline.bold())
                .help("S-Meter beim Empfang; PO, SWR, ALC, COMP und ID liefert das Gerät nur beim Senden. Prozent = Anteil vom Skalenendwert. Das SWR ist aus dem Rohwert (0–255) genähert.")
        }
    }

    /// Eine Zeile im Messwert-Raster.
    private func meterRow(_ title: String, raw: Int, text: String, tint: Color, active: Bool,
                          extra: String = "", extraColor: Color = .secondary,
                          alwaysShowExtra: Bool = false) -> some View {
        GridRow {
            Text(title)
                .font(.caption.bold())
                .frame(width: 40, alignment: .leading)
                .opacity(active ? 1 : 0.45)
            MeterTrack(value: active ? Double(raw) / 255 : 0, tint: tint)
                .frame(minWidth: 120, maxWidth: .infinity)
                .opacity(active ? 1 : 0.45)
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
                .opacity(active ? 1 : 0.45)
            Text(extra)
                .font(.caption.monospacedDigit())
                .foregroundStyle(extraColor)
                .frame(width: 84, alignment: .leading)
                .opacity(active || alwaysShowExtra ? 1 : 0.45)
        }
    }

    // MARK: Senden

    /// Sendesteuerung: Freigabeschalter, Tuner und PTT (nur nach Freigabe).
    private var txCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Sendefunktionen freigeben",
                       isOn: Binding(get: { radio.allowTX }, set: { radio.setAllowTX($0) }))
                    .toggleStyle(.switch)
                HStack {
                    Button("Tuner abstimmen") { radio.tune() }
                        .disabled(!radio.allowTX)
                    Button(radio.catTX ? "PTT AUS" : "PTT EIN") { radio.setPTT(!radio.catTX) }
                        .tint(radio.catTX ? Color.red : nil)
                        .disabled(!radio.allowTX)
                }
                Text("Nur mit Antenne oder Dummy Load. CAT-PTT endet nach 2 min automatisch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Senden").font(.subheadline.bold())
        }
    }
}
