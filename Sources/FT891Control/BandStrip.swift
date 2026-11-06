import SwiftUI

// MARK: - Bandleiste mit gearbeiteten Stationen

/// Zeigt für das aktuell eingestellte Band die Bandbreite als Leiste: jedes QSO der übergebenen Liste ist eine
/// Markierung (Farbe = CW / Fonie / Digi), der rote Strich ist die aktuelle Frequenz. Darunter die Rufzeichen
/// als Chips – Klick stimmt das Gerät auf die Frequenz dieses QSOs ab.
struct BandStrip: View {
    @Environment(Radio.self) private var radio
    /// QSOs, die angezeigt werden (z. B. die der aktiven Contest-Sitzung).
    let qsos: [QSO]
    /// Kurzer Hinweis, woher die QSOs stammen.
    let source: String

    var body: some View {
        let band = BandPlan.band(for: radio.freqA)
        let list = band.map { b in qsos.filter { $0.band == b.name }.sorted { $0.freqHz < $1.freqHz } } ?? []
        return VStack(alignment: .leading, spacing: 6) {
            header(band: band, count: list.count)
            if let band {
                strip(band: band, list: list)
                chips(list)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func header(band: HamBand?, count: Int) -> some View {
        HStack(spacing: 8) {
            if let band {
                Text("Band \(band.name)").font(.headline)
                Text("· \(count) QSO\(count == 1 ? "" : "s") · \(source)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Außerhalb der Amateurbänder – keine QSO-Leiste")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(ModeGroup.allCases, id: \.self) { g in
                HStack(spacing: 4) {
                    Circle().fill(g.color).frame(width: 8, height: 8)
                    Text("\(g.rawValue) (\(g.detail))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func strip(band: HamBand, list: [QSO]) -> some View {
        let span = Double(band.highHz - band.lowHz)
        return VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.22))
                    ForEach(list) { q in
                        Rectangle()
                            .fill(q.group.color)
                            .frame(width: 3, height: 20)
                            .offset(x: w * CGFloat(Double(q.freqHz - band.lowHz) / span) - 1.5)
                            .help("\(q.call) · \(q.freqKHzText) kHz · \(q.mode) · \(q.timeText) UTC")
                    }
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2, height: 30)
                        .offset(x: w * CGFloat(min(max(Double(radio.freqA - band.lowHz) / span, 0), 1)) - 1)
                }
            }
            .frame(height: 30)
            HStack {
                Text(String(format: "%.3f MHz", Double(band.lowHz) / 1_000_000))
                Spacer()
                Text(String(format: "%.3f MHz", Double(band.highHz) / 1_000_000))
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private func chips(_ list: [QSO]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if list.isEmpty {
                    Text("Noch kein QSO auf diesem Band")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(list) { q in
                    Button {
                        radio.setFrequencyA(hz: q.freqHz)
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(q.group.color).frame(width: 6, height: 6)
                            Text(q.call).font(.caption.bold().monospaced())
                            Text(q.freqMHzText).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("\(q.mode) · \(q.timeText) UTC – klicken, um diese Frequenz einzustellen")
                }
            }
        }
    }
}

/// Bandleiste für den Live-Reiter: QSOs der aktiven Contest-Sitzung, sonst die heutigen QSOs.
struct LiveBandStrip: View {
    @Environment(Logbook.self) private var log

    var body: some View {
        if let c = log.activeContest {
            BandStrip(qsos: log.qsos(inContest: c.id), source: c.name)
        } else {
            BandStrip(qsos: log.todayQSOs, source: "heute (UTC)")
        }
    }
}

// MARK: - Gemeinsame Bausteine

/// Betriebsart des Geräts als Klartext (z. B. „USB“).
@MainActor
func rigModeLabel(_ radio: Radio) -> String {
    Catalog.modes.first { $0.code == radio.mode }?.label ?? radio.mode
}

/// Filtert Eingaben für Rufzeichen: Großbuchstaben, Ziffern und „/“.
func cleanCall(_ s: String) -> String {
    String(s.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/") })
}

/// Kleines farbiges Etikett (Band, Modus, TX).
struct ChipTag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.title3.bold())
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Beschriftetes Eingabefeld (Titel klein darüber).
struct LabeledField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""
    var width: CGFloat? = nil
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: $text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(mono ? .body.monospaced() : .body)
                .autocorrectionDisabled()
                .labelsHidden()
                .frame(width: width)
        }
    }
}

/// Meldungszeile für Fehler und Hinweise des Logbuchs.
struct LogMessages: View {
    @Environment(Logbook.self) private var log
    var body: some View {
        if let err = log.lastError {
            HStack {
                Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Spacer()
                Button("OK") { log.lastError = nil }.controlSize(.small)
            }
        } else if let info = log.info {
            HStack {
                Label(info, systemImage: "info.circle").foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("OK") { log.info = nil }.controlSize(.small)
            }
        }
    }
}
