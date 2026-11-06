import SwiftUI

// MARK: - Schnellzugriff

/// Kompakter Schnellzugriff auf die Parameter, die im Betrieb ständig gebraucht werden.
///
/// Die Bedienelemente sind nach Aufgabe in drei Karten gruppiert:
/// **Empfang** (AF/RF/SQL, AGC, Vorstufe, ATT/NB/DNR/NAR), **Filter** (Bandbreite, IF-Shift, Notch)
/// und **Senden** (Leistung, Mikrofon, Prozessor, VOX). Schieberegler stehen einzeilig untereinander,
/// Ein/Aus-Funktionen sind als Schaltflächen in einem Raster angeordnet und Auswahlwerte als Segmente.
///
/// Alle Werte kommen aus ``Radio/values``; geschrieben wird über ``Radio/write(_:raw:)``.
/// Der Katalog (``Catalog/liveParams``) bestimmt weiterhin, welche Werte zyklisch nachgelesen werden.
struct QuickAccessView: View {
    @Environment(Radio.self) private var radio

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Schnellzugriff").font(.subheadline.bold())
                Spacer()
                Button("Neu lesen") { radio.readAll(Catalog.liveParams) }
                    .controlSize(.small)
            }
            HStack(alignment: .top, spacing: 12) {
                QuickCard(title: "Empfang") {
                    QuickSlider(id: "AG", title: "AF")
                    QuickSlider(id: "RG", title: "RF")
                    QuickSlider(id: "SQ", title: "SQL")
                    QuickChoice(id: "GT", title: "AGC")
                    QuickChoice(id: "PA", title: "Vorstufe")
                    QuickToggles(items: [
                        QuickItem("RA", "ATT"), QuickItem("NB", "NB"),
                        QuickItem("NR", "DNR"), QuickItem("NA", "NAR")
                    ])
                }
                QuickCard(title: "Filter") {
                    QuickSlider(id: "SH", title: "Breite")
                    QuickSlider(id: "IS", title: "Shift")
                    QuickToggles(items: [QuickItem("BC", "DNF")])
                }
                QuickCard(title: "Senden") {
                    QuickSlider(id: "PC", title: "Leistung")
                    QuickSlider(id: "MG", title: "Mikro")
                    QuickToggles(items: [QuickItem("PR0", "PROC"), QuickItem("VX", "VOX")])
                }
            }
        }
    }
}

/// Beschriftete Karte, die einen Themenblock des Schnellzugriffs zusammenfasst.
private struct QuickCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        } label: {
            Text(title).font(.subheadline.bold())
        }
        .frame(maxWidth: .infinity)
    }
}

/// Verweis auf einen Katalogeintrag (`id`, z. B. `"NB"`) mit der kurzen Beschriftung im Schnellzugriff.
private struct QuickItem: Identifiable {
    let id: String
    let title: String

    init(_ id: String, _ title: String) {
        self.id = id
        self.title = title
    }
}

// MARK: - Bausteine

/// Feste Breite der Beschriftung, damit alle Regler einer Karte bündig starten.
private let quickLabelWidth: CGFloat = 52

/// Schieberegler für einen numerischen Parameter (Zahl, Stufen oder vorzeichenbehaftet).
///
/// Der Wert wird erst beim Loslassen zum Funkgerät geschrieben, damit das Ziehen keine Befehlsflut auslöst.
/// Während des Ziehens zeigt der Regler den lokalen Entwurfswert (`draft`); Werte vom Gerät werden dann ignoriert.
private struct QuickSlider: View {
    let id: String
    let title: String

    @Environment(Radio.self) private var radio
    @State private var draft = 0.0
    @State private var dragging = false

    /// Wertebereich und Schrittweite des Parameters; `nil`, wenn er keinen Schieberegler erlaubt.
    private func bounds(_ p: Param) -> (lower: Double, upper: Double, step: Double)? {
        // Liegt der Gerätewert außerhalb des Katalogbereichs, wird der Bereich aufgeweitet.
        let current = Int(radio.values[p.id] ?? "")
        func widened(_ lo: Int, _ hi: Int, _ step: Int) -> (lower: Double, upper: Double, step: Double) {
            (Double(min(lo, current ?? lo)), Double(max(hi, current ?? hi)), Double(step))
        }
        switch p.kind {
        case .number(let lo, let hi, let step, _, _, _): return widened(lo, hi, step)
        case .stepped(let lo, let hi, _): return widened(lo, hi, 1)
        case .signed(let lo, let hi, let step, _): return widened(lo, hi, step)
        default: return nil
        }
    }

    var body: some View {
        if let p = Catalog.byID[id], let b = bounds(p) {
            let raw = radio.values[id]
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.bold())
                    .frame(width: quickLabelWidth, alignment: .leading)
                Slider(value: $draft, in: b.lower...b.upper, step: b.step) { editing in
                    dragging = editing
                    if !editing { radio.write(p, raw: p.encode(Int(draft.rounded()))) }
                }
                .controlSize(.small)
                Text(raw == nil ? "–" : radio.displayText(p, value: Int(draft.rounded())))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 64, alignment: .trailing)
            }
            .disabled(raw == nil || p.readOnly)
            .onAppear(perform: sync)
            .onChange(of: radio.values[id]) { _, _ in sync() }
        }
    }

    /// Übernimmt den Gerätewert in den Regler, sofern der Benutzer ihn nicht gerade bewegt.
    private func sync() {
        guard !dragging, let raw = radio.values[id], let v = Int(raw) else { return }
        draft = Double(v)
    }
}

/// Segmentierte Auswahl für einen Parameter mit festen Optionen (z. B. AGC, Vorstufe).
private struct QuickChoice: View {
    let id: String
    let title: String

    @Environment(Radio.self) private var radio

    var body: some View {
        if let p = Catalog.byID[id], case .choice(let options) = p.kind {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.bold())
                    .frame(width: quickLabelWidth, alignment: .leading)
                Picker(title, selection: Binding(get: { radio.values[id] ?? "" },
                                                 set: { radio.write(p, raw: $0) })) {
                    ForEach(options) { o in
                        Text(o.label).tag(o.code)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .disabled(radio.values[id] == nil || p.readOnly)
            }
        }
    }
}

/// Raster aus Ein/Aus-Schaltflächen; es passen so viele Spalten hinein, wie die Kartenbreite erlaubt.
private struct QuickToggles: View {
    let items: [QuickItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                QuickToggle(id: item.id, title: item.title)
            }
        }
    }
}

/// Ein/Aus-Schaltfläche für einen Parameter vom Typ ``ParamKind/toggle(off:on:)``; eingeschaltet ist sie hervorgehoben.
private struct QuickToggle: View {
    let id: String
    let title: String

    @Environment(Radio.self) private var radio

    var body: some View {
        if let p = Catalog.byID[id], case .toggle(let off, let on) = p.kind {
            let raw = radio.values[id]
            Toggle(title, isOn: Binding(get: { raw == on },
                                        set: { radio.write(p, raw: $0 ? on : off) }))
                .toggleStyle(.button)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .disabled(raw == nil || p.readOnly)
                .help(p.name)
        }
    }
}
