import Foundation

// MARK: - Grundtypen

/// Eine Auswahloption eines Parameters: der Code im CAT-Protokoll und die Anzeigebezeichnung.
struct Choice: Identifiable, Hashable {
    /// Wert, wie ihn das Gerät sendet und erwartet (z. B. `"2"`).
    let code: String
    /// Text für die Benutzeroberfläche (z. B. `"USB"`).
    let label: String

    var id: String { code }
}

/// Art eines Parameters – bestimmt Anzeige, Bedienelement und Kodierung des Wertes.
enum ParamKind {
    /// Ein/Aus-Schalter mit den beiden Rohwerten.
    case toggle(off: String, on: String)
    /// Auswahl aus festen Optionen.
    case choice([Choice])
    /// Ganzzahl im Bereich `min…max`; angezeigt wird `Rohwert × scale + offset` mit Einheit.
    case number(min: Int, max: Int, step: Int, scale: Double, offset: Double, unit: String)
    /// Ganzzahl, deren Anzeigetext eine Funktion liefert (z. B. Filterbreite, Verzögerungen).
    case stepped(min: Int, max: Int, label: (Int) -> String)
    /// Ganzzahl mit Vorzeichen; im Protokoll als `+`/`-` und Ziffern kodiert.
    case signed(min: Int, max: Int, step: Int, unit: String)
    /// Nur-Lese-Text (z. B. Gerätekennung, Softwareversionen).
    case text

    /// Standardschalter mit den Rohwerten `"0"` (aus) und `"1"` (ein).
    static var onOff: ParamKind { .toggle(off: "0", on: "1") }

    /// Zahlenbereich; Kurzform für ``number(min:max:step:scale:offset:unit:)``.
    static func range(_ lo: Int, _ hi: Int, step: Int = 1, scale: Double = 1, offset: Double = 0, unit: String = "") -> ParamKind {
        .number(min: lo, max: hi, step: step, scale: scale, offset: offset, unit: unit)
    }

    /// Stufenwert mit Beschriftungsfunktion; Kurzform für ``stepped(min:max:label:)``.
    static func steps(_ lo: Int, _ hi: Int, _ label: @escaping (Int) -> String) -> ParamKind {
        .stepped(min: lo, max: hi, label: label)
    }

    /// Vorzeichenbehafteter Zahlenbereich; Kurzform für ``signed(min:max:step:unit:)``.
    static func signedRange(_ lo: Int, _ hi: Int, step: Int = 1, unit: String = "") -> ParamKind {
        .signed(min: lo, max: hi, step: step, unit: unit)
    }

    /// Codes "0", "1", "2" … in der Reihenfolge der Labels.
    static func choices(_ labels: [String]) -> ParamKind {
        .choice(labels.enumerated().map { Choice(code: String($0.offset), label: $0.element) })
    }

    /// Auswahl mit frei wählbaren Codes, z. B. `[("0", "Aus"), ("1", "Ein")]`.
    static func codes(_ pairs: [(String, String)]) -> ParamKind {
        .choice(pairs.map { Choice(code: $0.0, label: $0.1) })
    }
}

/// Beschreibung eines einstellbaren Werts des Funkgeräts (ein CAT-Befehl oder ein EX-Menüeintrag).
struct Param: Identifiable {
    /// Eindeutiger Schlüssel, z. B. `"AG"` oder `"EX0506"`.
    let id: String
    /// Gruppe für die Gliederung der Liste.
    let group: String
    /// Anzeigename.
    let name: String
    /// Komplettes Lesekommando inklusive `;`.
    let read: String
    /// Präfix der Antwort – zugleich Präfix des Set-Kommandos.
    let prefix: String
    /// Anzahl der Zeichen des Wertes im Protokoll.
    let width: Int
    /// Art des Wertes (bestimmt Bedienelement und Anzeige).
    let kind: ParamKind
    /// Optionaler Hinweis, der unter dem Namen angezeigt wird.
    var note: String? = nil
    /// Nur lesbar; die App schreibt den Wert nie.
    var readOnly = false
    /// Werte, die den Sender einschalten und deshalb die Sendefreigabe erfordern.
    var txValues: Set<String> = []
    /// Wird im Schnellzugriff angezeigt und zyklisch nachgelesen.
    var live = false
    /// Bringt abweichende Antwortformate auf den Rohwert des Katalogs (z. B. AGC-Varianten).
    var normalize: (String) -> String = { $0 }
    /// Menünummer wie am Gerät (`"05-06"`) – nur bei EX-Menüeinträgen.
    var menuNumber: String? = nil
}

extension Param {
    /// Präfix, mit dem die Antwort auf ``read`` erkannt wird (Lesekommando ohne `;`).
    var expectPrefix: String { String(read.dropLast()) }

    /// Extrahiert den Rohwert aus einer Antwort.
    /// - Parameter frame: Antwort des Geräts inklusive `;`, z. B. `AG0128;`.
    /// - Returns: Der normalisierte Rohwert (`"128"`) oder `nil`, wenn die Antwort nicht zu diesem Parameter gehört.
    func rawValue(from frame: String) -> String? {
        guard frame.hasPrefix(prefix), frame.hasSuffix(";") else { return nil }
        let v = String(frame.dropFirst(prefix.count).dropLast())
        return v.isEmpty ? nil : normalize(v)
    }

    /// Füllt eine Zahl links mit Nullen auf die Protokollbreite auf (`pad(5, 3)` → `"005"`).
    static func pad(_ v: Int, _ w: Int) -> String {
        let s = String(v)
        return String(repeating: "0", count: max(0, w - s.count)) + s
    }

    /// Kodiert einen Zahlenwert für das Set-Kommando; vorzeichenbehaftete Werte bekommen `+`/`-` vorangestellt.
    func encode(_ v: Int) -> String {
        if case .signed = kind {
            return (v < 0 ? "-" : "+") + Param.pad(abs(v), width - 1)
        }
        return Param.pad(v, width)
    }

    /// Formatiert eine Zahl mit höchstens einer Nachkommastelle und optionaler Einheit.
    static func format(_ d: Double, _ unit: String) -> String {
        let s = d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
        return unit.isEmpty ? s : s + " " + unit
    }

    /// Anzeigetext für einen Rohwert (z. B. `"Ein"`, `"14 W"` oder `"V01-23"`).
    func display(_ raw: String) -> String {
        switch kind {
        case .toggle(_, let on):
            return raw == on ? "Ein" : "Aus"
        case .choice(let opts):
            return opts.first { $0.code == raw }?.label ?? raw
        case .number(_, _, _, let scale, let offset, let unit):
            guard let v = Int(raw) else { return raw }
            return Param.format(Double(v) * scale + offset, unit)
        case .stepped(_, _, let label):
            guard let v = Int(raw) else { return raw }
            return label(v)
        case .signed(_, _, _, let unit):
            guard let v = Int(raw) else { return raw }
            let s = (v > 0 ? "+" : "") + String(v)
            return unit.isEmpty ? s : s + " " + unit
        case .text:
            if id.hasPrefix("EX18"), raw.count == 4 {
                return "V\(raw.prefix(2))-\(raw.suffix(2))"
            }
            if id == "ID" { return raw == "0650" ? "0650 (FT-891)" : raw }
            return raw
        }
    }
}

// MARK: - Messwerte (Näherungen, Rohwert 0–255)

/// Umrechnung der Rohwerte (0–255) der Messinstrumente in anschauliche Größen.
///
/// Die Tabellen sind Näherungen; das Gerät liefert keine kalibrierten Werte.
enum Meter {
    private static let swrTable: [(Double, Double)] = [(0, 1.0), (26, 1.5), (52, 2.0), (103, 3.0), (255, 25.0)]
    private static let sTable: [(Double, Double)] = [
        (0, -54), (12, -48), (27, -42), (40, -36), (55, -30), (65, -24), (80, -18), (95, -12),
        (112, -6), (130, 0), (150, 10), (172, 20), (195, 30), (220, 40), (255, 50)
    ]

    /// Lineare Interpolation in einer nach `x` sortierten Stützstellentabelle; außerhalb werden die Randwerte gehalten.
    private static func interpolate(_ x: Double, _ table: [(Double, Double)]) -> Double {
        guard let first = table.first, let last = table.last else { return x }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for i in 1..<table.count {
            let a = table[i - 1]
            let b = table[i]
            if x <= b.0 {
                let t = (x - a.0) / (b.0 - a.0)
                return a.1 + t * (b.1 - a.1)
            }
        }
        return last.1
    }

    /// Stehwellenverhältnis (SWR) zum Rohwert, z. B. `1.5`.
    static func swr(_ raw: Int) -> Double { interpolate(Double(raw), swrTable) }

    /// S-Meter-Anzeige zum Rohwert, z. B. `S7` oder `S9+20`.
    static func sText(_ raw: Int) -> String {
        let db = interpolate(Double(raw), sTable) // dB relativ zu S9
        if db <= 0 {
            let s = max(0, Int((9 + db / 6).rounded()))
            return "S\(s)"
        }
        return "S9+\(Int(db.rounded()))"
    }
}

// MARK: - Filterbreiten-Tabelle (SH-Befehl)

/// Filterbreiten des Geräts (`SH`-Befehl).
///
/// Der Index bedeutet je nach Betriebsart und Schmalfilter (NAR) eine andere Bandbreite in Hz; die Tabellen folgen dem Referenzbuch.
enum Bandwidth {
    /// Bandbreite als Text.
    /// - Parameters:
    ///   - index: Wert des `SH`-Befehls.
    ///   - mode: Betriebsart als CAT-Code.
    ///   - narrow: Schmalfilter (NAR) eingeschaltet.
    /// - Returns: z. B. `"2400 Hz"`, oder `"Index n"` für Betriebsarten ohne Tabelle (FM, AM).
    static func label(index: Int, mode: String, narrow: Bool) -> String {
        let hz: Int?
        switch mode {
        case "1", "2": hz = narrow ? ssbNarrow[index] : ssbWide[index]
        case "3", "7": hz = narrow ? cwNarrow[index] : cwWide[index]
        case "6", "8", "9", "C": hz = narrow ? dataNarrow[index] : dataWide[index]
        default: hz = nil
        }
        if let hz { return "\(hz) Hz" }
        return "Index \(index)"
    }

    private static let ssbNarrow: [Int: Int] = [0: 1500, 1: 200, 2: 400, 3: 600, 4: 850, 5: 1100, 6: 1350, 7: 1500, 8: 1650, 9: 1800]
    private static let ssbWide: [Int: Int] = [0: 2400, 9: 1800, 10: 1950, 11: 2100, 12: 2200, 13: 2300, 14: 2400, 15: 2500, 16: 2600, 17: 2700, 18: 2800, 19: 2900, 20: 3000, 21: 3200]
    private static let cwNarrow: [Int: Int] = [0: 500, 1: 50, 2: 100, 3: 150, 4: 200, 5: 250, 6: 300, 7: 350, 8: 400, 9: 450, 10: 500]
    private static let cwWide: [Int: Int] = [0: 2400, 10: 500, 11: 800, 12: 1200, 13: 1400, 14: 1700, 15: 2000, 16: 2400, 17: 3000]
    private static let dataNarrow: [Int: Int] = [0: 300, 1: 50, 2: 100, 3: 150, 4: 200, 5: 250, 6: 300, 7: 350, 8: 400, 9: 450, 10: 500]
    private static let dataWide: [Int: Int] = [0: 500, 10: 500, 11: 800, 12: 1200, 13: 1400, 14: 1700, 15: 2000, 16: 2400, 17: 3000]
}

// MARK: - Katalog

/// Der Katalog aller Parameter: Standard-CAT-Befehle und EX-Menü.
enum Catalog {
    /// Reihenfolge der Gruppen der Standardbefehle in der Oberfläche.
    static let standardGroups = ["Audio & Pegel", "Empfang", "Filter & DSP", "Senden", "CW", "VFO & Betrieb", "System"]

    /// Betriebsarten des FT-891 mit ihren CAT-Codes (Befehl `MD`).
    static let modes: [Choice] = [
        Choice(code: "1", label: "LSB"), Choice(code: "2", label: "USB"), Choice(code: "3", label: "CW-U"),
        Choice(code: "4", label: "FM"), Choice(code: "5", label: "AM"), Choice(code: "6", label: "RTTY-LSB"),
        Choice(code: "7", label: "CW-L"), Choice(code: "8", label: "DATA-LSB"), Choice(code: "9", label: "RTTY-USB"),
        Choice(code: "A", label: "DATA-FM"), Choice(code: "B", label: "FM-N"), Choice(code: "C", label: "DATA-USB"),
        Choice(code: "D", label: "AM-N")
    ]

    /// Standard-CAT-Befehle (AF-Pegel, Filter, Senden, CW …).
    static let standard: [Param] = makeStandard()
    /// Alle EX-Menüeinträge 01-01 … 16-23 sowie die Versionen 18-01 … 18-03.
    static let menu: [Param] = menuA + menuB + menuC + menuD + menuE
    /// Standardbefehle und Menü zusammen.
    static let all: [Param] = standard + menu
    /// Schneller Zugriff über die Parameter-ID.
    static let byID: [String: Param] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    /// Parameter des Schnellzugriffs; sie werden beim Verbinden gelesen und zyklisch aktualisiert.
    static let liveParams: [Param] = standard.filter { $0.live }
}

/// Namen der Menügruppen (zweistelliger Präfix der Menünummer).
private let menuGroupNames: [String: String] = [
    "01": "AGC", "02": "DISPLAY", "03": "DVS", "04": "KEYER", "05": "GENERAL", "06": "MODE AM",
    "07": "MODE CW", "08": "MODE DAT", "09": "MODE FM", "10": "MODE RTTY", "11": "MODE SSB",
    "12": "RX DSP", "13": "SCOPE", "14": "TUNING", "15": "TX AUDIO", "16": "TX GNRL", "18": "SOFTWARE VERSION"
]

/// CTCSS-Töne des Geräts in Hz, in der Reihenfolge der Gerätecodes 000…049.
private let ctcssTones: [String] = [
    "67.0", "69.3", "71.9", "74.4", "77.0", "79.7", "82.5", "85.4", "88.5", "91.5", "94.8", "97.4", "100.0",
    "103.5", "107.2", "110.9", "114.8", "118.8", "123.0", "127.3", "131.8", "136.5", "141.3", "146.2", "151.4",
    "156.7", "159.8", "162.2", "165.5", "167.9", "171.3", "173.8", "177.3", "179.9", "183.5", "186.2", "189.9",
    "192.8", "196.6", "199.5", "203.5", "206.5", "210.7", "218.1", "225.7", "229.1", "233.6", "241.8", "250.3", "254.1"
]

/// DCS-Codes des Geräts in der Reihenfolge der Gerätecodes 000…103.
private let dcsCodes: [String] = [
    "023", "025", "026", "031", "032", "036", "043", "047", "051", "053",
    "054", "065", "071", "072", "073", "074", "114", "115", "116", "122",
    "125", "131", "132", "134", "143", "145", "152", "155", "156", "162",
    "165", "172", "174", "205", "212", "223", "225", "226", "243", "244",
    "245", "246", "251", "252", "255", "261", "263", "265", "266", "271",
    "274", "306", "311", "315", "325", "331", "332", "343", "346", "351",
    "356", "364", "365", "371", "411", "412", "413", "423", "431", "432",
    "445", "446", "452", "454", "455", "462", "464", "465", "466", "503",
    "506", "516", "523", "526", "532", "546", "565", "606", "612", "624",
    "627", "631", "632", "654", "662", "664", "703", "712", "723", "731",
    "732", "734", "743", "754"
]

// MARK: - Standard-CAT-Befehle

/// Kurzform zum Anlegen eines Standard-CAT-Parameters.
/// - Parameters:
///   - id: Schlüssel und CAT-Befehl (z. B. `"AG"`).
///   - group: Gruppe in der Oberfläche.
///   - name: Anzeigename.
///   - read: Lesekommando inklusive `;`.
///   - prefix: Präfix von Antwort und Set-Kommando.
///   - width: Zeichen des Wertes.
///   - kind: Art des Wertes.
private func std(_ id: String, _ group: String, _ name: String, _ read: String, _ prefix: String, _ width: Int,
                 _ kind: ParamKind, note: String? = nil, live: Bool = false, readOnly: Bool = false,
                 tx: Set<String> = [], normalize: @escaping (String) -> String = { $0 }) -> Param {
    Param(id: id, group: group, name: name, read: read, prefix: prefix, width: width, kind: kind,
          note: note, readOnly: readOnly, txValues: tx, live: live, normalize: normalize)
}

/// Erzeugt die Liste der Standard-CAT-Befehle, gegliedert nach Aufgabe.
private func makeStandard() -> [Param] {
    let audio = "Audio & Pegel"
    let rx = "Empfang"
    let dsp = "Filter & DSP"
    let send = "Senden"
    let cw = "CW"
    let vfo = "VFO & Betrieb"
    let sys = "System"

    let toneCodes: [(String, String)] = ctcssTones.enumerated().map { (Param.pad($0.offset, 3), "\($0.element) Hz") }
    let dcsList: [(String, String)] = dcsCodes.enumerated().map { (Param.pad($0.offset, 3), "\($0.element)  (Nr. \($0.offset))") }

    return [
        std("AG", audio, "AF-Lautstärke (AF Gain)", "AG0;", "AG0", 3, .range(0, 255), live: true),
        std("RG", audio, "HF-Verstärkung (RF Gain)", "RG0;", "RG0", 3, .range(0, 30),
            note: "Laut Referenzbuch 0–30 (ältere Ausgabe: 0–100)", live: true),
        std("SQ", audio, "Squelch", "SQ0;", "SQ0", 3, .range(0, 100), live: true),
        std("ML0", audio, "Monitor (MONI)", "ML0;", "ML0", 3, .toggle(off: "000", on: "001")),
        std("ML1", audio, "Monitor-Pegel", "ML1;", "ML1", 3, .range(0, 100)),

        std("GT", rx, "AGC", "GT0;", "GT0", 1,
            .codes([("0", "AUS"), ("1", "FAST"), ("2", "MID"), ("3", "SLOW"), ("4", "AUTO")]),
            note: "AUTO wählt Fast/Mid/Slow je nach Betriebsart", live: true,
            normalize: { ["5", "6"].contains($0) ? "4" : $0 }),
        std("PA", rx, "Vorverstärker", "PA0;", "PA0", 1, .codes([("0", "IPO (aus)"), ("1", "AMP (ein)")]), live: true),
        std("RA", rx, "Abschwächer (ATT)", "RA0;", "RA0", 1, .onOff, live: true),
        std("NB", rx, "Störaustaster (NB)", "NB0;", "NB0", 1, .onOff, live: true),
        std("NL", rx, "NB-Pegel", "NL0;", "NL0", 3, .range(0, 10)),
        std("NR", rx, "Rauschminderung (DNR)", "NR0;", "NR0", 1, .onOff, live: true),
        std("RL", rx, "DNR-Pegel", "RL0;", "RL0", 2, .range(1, 15)),
        std("NA", rx, "Schmalfilter (NAR)", "NA0;", "NA0", 1, .onOff, live: true),

        std("SH", dsp, "Filterbreite (WIDTH)", "SH0;", "SH0", 2, .steps(0, 21) { String($0) },
            note: "Index laut Tabelle, Anzeige abhängig von Betriebsart und NAR", live: true),
        std("IS", dsp, "IF-Shift", "IS0;", "IS0", 5, .signedRange(-1200, 1200, step: 20, unit: "Hz"), live: true),
        std("BC", dsp, "Auto-Notch (DNF)", "BC0;", "BC0", 1, .onOff, live: true),
        std("BP00", dsp, "Manueller Notch", "BP00;", "BP00", 3, .toggle(off: "000", on: "001")),
        std("BP01", dsp, "Notch-Frequenz", "BP01;", "BP01", 3, .range(1, 320, scale: 10, unit: "Hz")),
        std("CO00", dsp, "Contour", "CO00;", "CO00", 4, .toggle(off: "0000", on: "0001")),
        std("CO01", dsp, "Contour-Frequenz", "CO01;", "CO01", 4, .range(10, 3200, unit: "Hz")),
        std("CO02", dsp, "APF", "CO02;", "CO02", 4, .toggle(off: "0000", on: "0001")),
        std("CO03", dsp, "APF-Frequenz", "CO03;", "CO03", 4, .range(0, 50, scale: 10, offset: -250, unit: "Hz")),

        std("PC", send, "Sendeleistung", "PC;", "PC", 3, .range(5, 100, unit: "W"),
            note: "AM: maximal 40 W", live: true),
        std("MG", send, "Mikrofonverstärkung (MIC-Gain)", "MG;", "MG", 3, .range(0, 100), live: true),
        std("PR0", send, "Sprachprozessor", "PR0;", "PR0", 1, .onOff, live: true),
        std("PL", send, "Sprachprozessor-Pegel", "PL;", "PL", 3, .range(0, 100)),
        std("PR1", send, "Parametrischer Mikrofon-EQ", "PR1;", "PR1", 1, .onOff),
        std("VX", send, "VOX", "VX;", "VX", 1, .onOff, live: true),
        std("VG", send, "VOX-Gain", "VG;", "VG", 3, .range(0, 100)),
        std("VD", send, "VOX-Verzögerung", "VD;", "VD", 4, .range(30, 3000, step: 10, unit: "ms")),
        std("MX", send, "MOX", "MX;", "MX", 1, .onOff, note: "Schaltet den Sender ein – nur mit Freigabe im Live-Tab", tx: ["1"]),

        std("KS", cw, "Tastgeschwindigkeit", "KS;", "KS", 3, .range(4, 60, unit: "WPM")),
        std("KP", cw, "CW-Tonhöhe (Pitch)", "KP;", "KP", 2, .range(0, 75, scale: 10, offset: 300, unit: "Hz")),
        std("KR", cw, "Keyer", "KR;", "KR", 1, .onOff),
        std("BI", cw, "Break-in", "BI;", "BI", 1, .onOff),
        std("SD", cw, "Semi-Break-in-Verzögerung", "SD;", "SD", 4, .range(30, 3000, step: 10, unit: "ms")),
        std("CS", cw, "CW-Spot (Nullschwebung)", "CS;", "CS", 1, .onOff),

        std("MD", vfo, "Betriebsart", "MD0;", "MD0", 1, .choice(Catalog.modes)),
        std("CF", vfo, "Clarifier (RIT/XIT)", "CF0;", "CF0", 2, .toggle(off: "00", on: "10")),
        std("FS", vfo, "Fast-Step", "FS;", "FS", 1, .onOff),
        std("LK", vfo, "Dial-Sperre", "LK;", "LK", 1, .onOff),
        std("SC", vfo, "Scan", "SC;", "SC", 1, .codes([("0", "Aus"), ("1", "Aufwärts"), ("2", "Abwärts")])),
        std("ST", vfo, "Split", "ST;", "ST", 1, .codes([("0", "Aus"), ("1", "Ein"), ("2", "Ein (+5 kHz)")])),
        std("OS", vfo, "Ablage (Relais-Shift)", "OS0;", "OS0", 1,
            .codes([("0", "Simplex"), ("1", "Plus"), ("2", "Minus")]), note: "Nur in FM einstellbar"),
        std("CT", vfo, "CTCSS / DCS", "CT0;", "CT0", 1,
            .codes([("0", "Aus"), ("1", "CTCSS Enc/Dec"), ("2", "CTCSS Enc"), ("3", "DCS")])),
        std("CN00", vfo, "CTCSS-Ton", "CN00;", "CN00", 3, .codes(toneCodes)),
        std("CN01", vfo, "DCS-Code", "CN01;", "CN01", 3, .codes(dcsList)),
        std("TS", vfo, "TX-Watch (TXW)", "TS;", "TS", 1, .onOff),
        std("MS", vfo, "Sendeanzeige (Meter-Auswahl)", "MS;", "MS", 1,
            .codes([("0", "COMP"), ("1", "ALC"), ("2", "PO"), ("3", "SWR"), ("4", "ID")])),
        std("AC", vfo, "Antennentuner", "AC;", "AC00", 1,
            .codes([("0", "Aus"), ("1", "Ein"), ("2", "Abstimmung läuft / starten")]),
            note: "„Starten“ sendet – nur mit Freigabe im Live-Tab", tx: ["2"]),

        std("AI", sys, "Auto-Information", "AI;", "AI", 1, .onOff, note: "Die App setzt AI beim Verbinden auf Aus"),
        std("RS", sys, "Gerätestatus", "RS;", "RS", 1, .codes([("0", "Normal"), ("1", "Menü-Modus")]), readOnly: true),
        std("UL", sys, "PLL", "UL;", "UL", 1, .codes([("0", "Eingerastet"), ("1", "Nicht eingerastet")]), readOnly: true),
        std("ID", sys, "Geräte-ID", "ID;", "ID", 4, .text, readOnly: true)
    ]
}

// MARK: - EX-Menü

/// Kurzform zum Anlegen eines EX-Menüeintrags.
/// - Parameters:
///   - code: Vierstellige Menünummer ohne Bindestrich, z. B. `"0506"` für 05-06.
///   - name: Menüname wie am Gerät.
///   - kind: Art des Wertes.
///   - width: Zeichen des Wertes im Protokoll.
private func m(_ code: String, _ name: String, _ kind: ParamKind, _ width: Int,
               note: String? = nil, readOnly: Bool = false) -> Param {
    let g = String(code.prefix(2))
    return Param(id: "EX" + code,
                 group: "Menü \(g) \(menuGroupNames[g] ?? "")",
                 name: name,
                 read: "EX\(code);",
                 prefix: "EX" + code,
                 width: width,
                 kind: kind,
                 note: note,
                 readOnly: readOnly,
                 menuNumber: "\(g)-\(code.suffix(2))")
}

// Wiederkehrende Wertebereiche der Menüs, damit die Tabellen unten kurz bleiben.

/// DISABLE/ENABLE.
private func disEn() -> ParamKind { .choices(["DISABLE", "ENABLE"]) }
/// Eingang: Frontmikrofon (MIC) oder Buchse auf der Rückseite (REAR).
private func micRear() -> ParamKind { .choices(["MIC", "REAR"]) }
/// Flankensteilheit der Low-/High-Cut-Filter.
private func slope() -> ParamKind { .choices(["6 dB/oct", "18 dB/oct"]) }
/// Quelle der PTT-Steuerung: Datenbuchse (DAKY) oder RTS/DTR der USB-Schnittstelle.
private func daky() -> ParamKind { .choices(["DAKY", "RTS", "DTR"]) }
/// Normale oder umgekehrte (REV) Polarität.
private func norRev() -> ParamKind { .choices(["NOR", "REV"]) }
/// Seitenband: USB oder LSB.
private func usbLsb() -> ParamKind { .choices(["USB", "LSB"]) }
/// Pegel 0–100.
private func level100() -> ParamKind { .range(0, 100) }
/// Leistung in Watt, 5 W bis `hi`.
private func power(_ hi: Int) -> ParamKind { .range(5, hi, unit: "W") }
/// Verzögerung in Millisekunden (30–3000 ms in 10-ms-Schritten).
private func msDelay() -> ParamKind { .range(30, 3000, step: 10, unit: "ms") }
/// Equalizer-Pegel in dB (−20 … +10).
private func eqLevel() -> ParamKind { .signedRange(-20, 10, unit: "dB") }
/// Equalizer-Bandbreite 1–10.
private func eqBw() -> ParamKind { .range(1, 10) }
/// Untere Grenzfrequenz (LCUT): AUS oder 100 Hz aufwärts in 50-Hz-Schritten.
private func lcut() -> ParamKind { .steps(0, 19) { $0 == 0 ? "OFF" : "\(100 + ($0 - 1) * 50) Hz" } }
/// Obere Grenzfrequenz (HCUT): AUS oder 700 Hz aufwärts in 50-Hz-Schritten.
private func hcut() -> ParamKind { .steps(0, 67) { $0 == 0 ? "OFF" : "\(700 + ($0 - 1) * 50) Hz" } }
/// Mittenfrequenz eines Equalizer-Bandes: AUS oder `base + Stufe × 100 Hz`.
private func eqFreq(_ hi: Int, base: Int) -> ParamKind { .steps(0, hi) { $0 == 0 ? "OFF" : "\(base + $0 * 100) Hz" } }

/// Menüs 01–05: AGC, Anzeige, DVS, Keyer, Allgemein.
private let menuA: [Param] = [
    m("0101", "AGC FAST DELAY", .range(20, 4000, step: 20, unit: "ms"), 4),
    m("0102", "AGC MID DELAY", .range(20, 4000, step: 20, unit: "ms"), 4),
    m("0103", "AGC SLOW DELAY", .range(20, 4000, step: 20, unit: "ms"), 4),
    m("0201", "LCD CONTRAST", .range(1, 15), 2),
    m("0202", "DIMMER BACKLIT", .range(1, 15), 2),
    m("0203", "DIMMER LCD", .range(1, 15), 2),
    m("0204", "DIMMER TX/BUSY", .range(1, 15), 2),
    m("0205", "PEAK HOLD", .choices(["OFF", "0.5 sec", "1.0 sec", "2.0 sec"]), 1),
    m("0206", "ZIN LED", disEn(), 1),
    m("0207", "POP-UP MENU", .choices(["UPPER", "LOWER"]), 1),
    m("0301", "DVS RX OUT LVL", level100(), 3),
    m("0302", "DVS TX OUT LVL", level100(), 3),
    m("0401", "KEYER TYPE", .choices(["OFF", "BUG", "ELEKEY-A", "ELEKEY-B", "ELEKEY-Y", "ACS"]), 1),
    m("0402", "KEYER DOT/DASH", norRev(), 1),
    m("0403", "CW WEIGHT", .range(25, 45, scale: 0.1, unit: ":1"), 2),
    m("0404", "BEACON INTERVAL", .steps(0, 690) { $0 == 0 ? "OFF" : "\($0) s" }, 3),
    m("0405", "NUMBER STYLE", .choices(["1290", "AUNO", "AUNT", "A2NO", "A2NT", "12NO", "12NT"]), 1),
    m("0406", "CONTEST NUMBER", .range(0, 9999), 4),
    m("0407", "CW MEMORY 1", .choices(["TEXT", "MESSAGE"]), 1),
    m("0408", "CW MEMORY 2", .choices(["TEXT", "MESSAGE"]), 1),
    m("0409", "CW MEMORY 3", .choices(["TEXT", "MESSAGE"]), 1),
    m("0410", "CW MEMORY 4", .choices(["TEXT", "MESSAGE"]), 1),
    m("0411", "CW MEMORY 5", .choices(["TEXT", "MESSAGE"]), 1),
    m("0501", "NB WIDTH", .choices(["1 msec", "3 msec", "10 msec"]), 1),
    m("0502", "NB REJECTION", .choices(["10 dB", "30 dB", "50 dB"]), 1),
    m("0503", "NB LEVEL", .range(0, 10), 2),
    m("0504", "BEEP LEVEL", level100(), 3),
    m("0505", "RF/SQL VR", .choices(["RF", "SQL"]), 1),
    m("0506", "CAT RATE", .choices(["4800 bps", "9600 bps", "19200 bps", "38400 bps"]), 1,
      note: "Ändert die Baudrate des Geräts – die App stellt sich automatisch um"),
    m("0507", "CAT TOT", .choices(["10 msec", "100 msec", "1000 msec", "3000 msec"]), 1),
    m("0508", "CAT RTS", disEn(), 1),
    m("0509", "MEM GROUP", disEn(), 1),
    m("0510", "FM SETTING", disEn(), 1),
    m("0511", "REC SETTING", disEn(), 1),
    m("0512", "ATAS SETTING", disEn(), 1),
    m("0513", "QUICK SPL FREQ", .signedRange(-20, 20, unit: "kHz"), 3),
    m("0514", "TX TOT", .steps(0, 30) { $0 == 0 ? "OFF" : "\($0) min" }, 2),
    m("0515", "MIC SCAN", disEn(), 1),
    m("0516", "MIC SCAN RESUME", .choices(["PAUSE", "TIME"]), 1),
    m("0517", "REF FREQ ADJ", .signedRange(-25, 25), 3, note: "Referenzfrequenz-Abgleich – nur ändern, wenn du weißt, was du tust"),
    m("0518", "CLAR SELECT", .choices(["RX", "TX", "TRX"]), 1),
    m("0519", "APO", .choices(["OFF", "1 h", "2 h", "4 h", "6 h", "8 h", "10 h", "12 h"]), 1),
    m("0520", "FAN CONTROL", .choices(["NORMAL", "CONTEST"]), 1)
]

/// Menüs 06–09: Betriebsarten AM, CW, DATA und FM.
private let menuB: [Param] = [
    m("0601", "AM LCUT FREQ", lcut(), 2),
    m("0602", "AM LCUT SLOPE", slope(), 1),
    m("0603", "AM HCUT FREQ", hcut(), 2),
    m("0604", "AM HCUT SLOPE", slope(), 1),
    m("0605", "AM MIC SELECT", micRear(), 1),
    m("0606", "AM OUT LEVEL", level100(), 3),
    m("0607", "AM PTT SELECT", daky(), 1),
    m("0701", "CW LCUT FREQ", lcut(), 2),
    m("0702", "CW LCUT SLOPE", slope(), 1),
    m("0703", "CW HCUT FREQ", hcut(), 2),
    m("0704", "CW HCUT SLOPE", slope(), 1),
    m("0705", "CW OUT LEVEL", level100(), 3),
    m("0706", "CW AUTO MODE", .choices(["OFF", "50M", "ON"]), 1),
    m("0707", "CW BFO", .choices(["USB", "LSB", "AUTO"]), 1),
    m("0708", "CW BK-IN TYPE", .choices(["SEMI", "FULL"]), 1),
    m("0709", "CW BK-IN DELAY", msDelay(), 4),
    m("0710", "CW WAVE SHAPE", .codes([("1", "2 msec"), ("2", "4 msec")]), 1),
    m("0711", "CW FREQ DISPLAY", .choices(["FREQ", "PITCH"]), 1),
    m("0712", "PC KEYING", .choices(["OFF", "DAKY", "RTS", "DTR"]), 1),
    m("0713", "QSK DELAY TIME", .choices(["15 msec", "20 msec", "25 msec", "30 msec"]), 1),
    m("0801", "DATA MODE", .choices(["PSK", "OTHERS"]), 1),
    m("0802", "PSK TONE", .choices(["1000 Hz", "1500 Hz", "2000 Hz"]), 1),
    m("0803", "OTHER DISP", .signedRange(-3000, 3000, step: 10, unit: "Hz"), 5),
    m("0804", "OTHER SHIFT", .signedRange(-3000, 3000, step: 10, unit: "Hz"), 5),
    m("0805", "DATA LCUT FREQ", lcut(), 2),
    m("0806", "DATA LCUT SLOPE", slope(), 1),
    m("0807", "DATA HCUT FREQ", hcut(), 2),
    m("0808", "DATA HCUT SLOPE", slope(), 1),
    m("0809", "DATA IN SELECT", micRear(), 1),
    m("0810", "DATA PTT SELECT", daky(), 1),
    m("0811", "DATA OUT LEVEL", level100(), 3),
    m("0812", "DATA BFO", usbLsb(), 1),
    m("0901", "FM MIC SELECT", micRear(), 1),
    m("0902", "FM OUT LEVEL", level100(), 3),
    m("0903", "PKT PTT SELECT", daky(), 1),
    m("0904", "RPT SHIFT 28MHz", .range(0, 1000, step: 10, unit: "kHz"), 4),
    m("0905", "RPT SHIFT 50MHz", .range(0, 4000, step: 10, unit: "kHz"), 4),
    m("0906", "DCS POLARITY", .choices(["Tn-Rn", "Tn-Riv", "Tiv-Rn", "Tiv-Riv"]), 1)
]

/// Menüs 10–13: RTTY, SSB, Empfangs-DSP und Scope.
private let menuC: [Param] = [
    m("1001", "RTTY LCUT FREQ", lcut(), 2),
    m("1002", "RTTY LCUT SLOPE", slope(), 1),
    m("1003", "RTTY HCUT FREQ", hcut(), 2),
    m("1004", "RTTY HCUT SLOPE", slope(), 1),
    m("1005", "RTTY SHIFT PORT", .choices(["SHIFT", "DTR", "RTS"]), 1),
    m("1006", "RTTY POLARITY-R", norRev(), 1),
    m("1007", "RTTY POLARITY-T", norRev(), 1),
    m("1008", "RTTY OUT LEVEL", level100(), 3),
    m("1009", "RTTY SHIFT FREQ", .choices(["170 Hz", "200 Hz", "425 Hz", "850 Hz"]), 1),
    m("1010", "RTTY MARK FREQ", .choices(["1275 Hz", "2125 Hz"]), 1),
    m("1011", "RTTY BFO", usbLsb(), 1),
    m("1101", "SSB LCUT FREQ", lcut(), 2),
    m("1102", "SSB LCUT SLOPE", slope(), 1),
    m("1103", "SSB HCUT FREQ", hcut(), 2),
    m("1104", "SSB HCUT SLOPE", slope(), 1),
    m("1105", "SSB MIC SELECT", micRear(), 1),
    m("1106", "SSB OUT LEVEL", level100(), 3),
    m("1107", "SSB BFO", .choices(["USB", "LSB", "AUTO"]), 1),
    m("1108", "SSB PTT SELECT", daky(), 1),
    m("1109", "SSB TX BPF", .choices(["100-3000", "100-2900", "200-2800", "300-2700", "400-2600"]), 1),
    m("1201", "APF WIDTH", .choices(["NARROW", "MEDIUM", "WIDE"]), 1),
    m("1202", "CONTOUR LEVEL", .signedRange(-40, 20, unit: "dB"), 3),
    m("1203", "CONTOUR WIDTH", .range(1, 11), 2),
    m("1204", "IF NOTCH WIDTH", .choices(["NARROW", "WIDE"]), 1),
    m("1301", "SCP START CYCLE", .choices(["OFF", "3 sec", "5 sec", "10 sec"]), 1),
    m("1302", "SCP SPAN FREQ", .choices(["37.5 kHz", "75 kHz", "150 kHz", "375 kHz", "750 kHz"]), 1)
]

/// Menüs 14–15: Abstimmung und Sende-Equalizer.
private let menuD: [Param] = [
    m("1401", "QUICK DIAL", .choices(["50 kHz", "100 kHz", "500 kHz"]), 1),
    m("1402", "SSB DIAL STEP", .choices(["2 Hz", "5 Hz", "10 Hz"]), 1),
    m("1403", "AM DIAL STEP", .choices(["10 Hz", "100 Hz"]), 1),
    m("1404", "FM DIAL STEP", .choices(["10 Hz", "100 Hz"]), 1),
    m("1405", "DIAL STEP", .choices(["2 Hz", "5 Hz", "10 Hz"]), 1),
    m("1406", "AM CH STEP", .choices(["2.5 kHz", "5 kHz", "9 kHz", "10 kHz", "12.5 kHz", "25 kHz"]), 1),
    m("1407", "FM CH STEP", .choices(["5 kHz", "6.25 kHz", "10 kHz", "12.5 kHz", "15 kHz", "20 kHz", "25 kHz"]), 1),
    m("1501", "EQ1 FREQ", eqFreq(7, base: 0), 2),
    m("1502", "EQ1 LEVEL", eqLevel(), 3),
    m("1503", "EQ1 BWTH", eqBw(), 2),
    m("1504", "EQ2 FREQ", eqFreq(9, base: 600), 2),
    m("1505", "EQ2 LEVEL", eqLevel(), 3),
    m("1506", "EQ2 BWTH", eqBw(), 2),
    m("1507", "EQ3 FREQ", eqFreq(18, base: 1400), 2),
    m("1508", "EQ3 LEVEL", eqLevel(), 3),
    m("1509", "EQ3 BWTH", eqBw(), 2),
    m("1510", "P-EQ1 FREQ", eqFreq(7, base: 0), 2),
    m("1511", "P-EQ1 LEVEL", eqLevel(), 3),
    m("1512", "P-EQ1 BWTH", eqBw(), 2),
    m("1513", "P-EQ2 FREQ", eqFreq(9, base: 600), 2),
    m("1514", "P-EQ2 LEVEL", eqLevel(), 3),
    m("1515", "P-EQ2 BWTH", eqBw(), 2),
    m("1516", "P-EQ3 FREQ", eqFreq(18, base: 1400), 2),
    m("1517", "P-EQ3 LEVEL", eqLevel(), 3),
    m("1518", "P-EQ3 BWTH", eqBw(), 2)
]

/// Menü 16 (Sendeleistung, Verstärkung, VOX, Tuner) und die Softwareversionen 18-01 … 18-03 (nur lesbar).
private let menuE: [Param] = [
    m("1601", "HF SSB PWR", power(100), 3),
    m("1602", "HF AM PWR", power(40), 3),
    m("1603", "HF PWR", power(100), 3),
    m("1604", "50M SSB PWR", power(100), 3),
    m("1605", "50M AM PWR", power(40), 3),
    m("1606", "50M PWR", power(100), 3),
    m("1607", "SSB MIC GAIN", level100(), 3),
    m("1608", "AM MIC GAIN", level100(), 3),
    m("1609", "FM MIC GAIN", level100(), 3),
    m("1610", "DATA MIC GAIN", level100(), 3),
    m("1611", "SSB DATA GAIN", level100(), 3),
    m("1612", "AM DATA GAIN", level100(), 3),
    m("1613", "FM DATA GAIN", level100(), 3),
    m("1614", "DATA DATA GAIN", level100(), 3),
    m("1615", "TUNER SELECT", .choices(["OFF", "EXTERNAL", "ATAS", "LAMP"]), 1),
    m("1616", "VOX SELECT", .choices(["MIC", "DATA"]), 1),
    m("1617", "VOX GAIN", level100(), 3),
    m("1618", "VOX DELAY", msDelay(), 4),
    m("1619", "ANTI VOX GAIN", level100(), 3),
    m("1620", "DATA VOX GAIN", level100(), 3),
    m("1621", "DATA VOX DELAY", msDelay(), 4),
    m("1622", "ANTI DVOX GAIN", level100(), 3),
    m("1623", "EMERGENCY FREQ", disEn(), 1),
    m("1801", "MAIN VERSION", .text, 4, readOnly: true),
    m("1802", "DSP VERSION", .text, 4, readOnly: true),
    m("1803", "LCD VERSION", .text, 4, readOnly: true)
]
