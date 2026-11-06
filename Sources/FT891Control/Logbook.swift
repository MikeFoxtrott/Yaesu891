import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

// MARK: - Bandplan

/// Ein Amateurfunkband mit Name und Bandgrenzen.
struct HamBand: Identifiable, Hashable {
    /// Bezeichnung in Metern, z. B. `"20m"`.
    let name: String
    /// Untere Bandgrenze in Hz.
    let lowHz: Int
    /// Obere Bandgrenze in Hz.
    let highHz: Int

    var id: String { name }
}

/// Bandplan der Amateurfunkbänder, die der FT-891 abdeckt.
enum BandPlan {
    /// Amateurfunkbänder (IARU Region 1), Grenzen in Hz, aufsteigend sortiert.
    static let bands: [HamBand] = [
        HamBand(name: "160m", lowHz: 1_810_000, highHz: 2_000_000),
        HamBand(name: "80m", lowHz: 3_500_000, highHz: 3_800_000),
        HamBand(name: "60m", lowHz: 5_351_500, highHz: 5_366_500),
        HamBand(name: "40m", lowHz: 7_000_000, highHz: 7_200_000),
        HamBand(name: "30m", lowHz: 10_100_000, highHz: 10_150_000),
        HamBand(name: "20m", lowHz: 14_000_000, highHz: 14_350_000),
        HamBand(name: "17m", lowHz: 18_068_000, highHz: 18_168_000),
        HamBand(name: "15m", lowHz: 21_000_000, highHz: 21_450_000),
        HamBand(name: "12m", lowHz: 24_890_000, highHz: 24_990_000),
        HamBand(name: "10m", lowHz: 28_000_000, highHz: 29_700_000),
        HamBand(name: "6m", lowHz: 50_000_000, highHz: 52_000_000)
    ]

    /// Findet das Amateurfunkband, in dem die Frequenz liegt.
    static func band(for hz: Int) -> HamBand? {
        bands.first { hz >= $0.lowHz && hz <= $0.highHz }
    }

    /// Bandname; Frequenzen außerhalb der Amateurbänder werden als `"GEN"` geführt.
    static func name(for hz: Int) -> String {
        band(for: hz)?.name ?? "GEN"
    }
}

/// Betriebsartgruppe, wie sie im Contest zählt: Telegrafie, Sprechfunk oder Digimodes.
enum ModeGroup: String, CaseIterable {
    case cw = "CW"
    case fonie = "Fonie"
    case digi = "Digi"

    /// Ordnet eine Betriebsart (Gerät, z. B. `"USB"`, oder von Hand, z. B. `"FT8"`) ihrer Gruppe zu.
    static func of(_ modeLabel: String) -> ModeGroup {
        let u = modeLabel.uppercased()
        if u.hasPrefix("CW") { return .cw }
        if u.isEmpty || ["LSB", "USB", "SSB", "AM", "AM-N", "FM", "FM-N", "PH"].contains(u) { return .fonie }
        return .digi
    }

    /// Markierungsfarbe in Bandleiste und Chips.
    var color: Color {
        switch self {
        case .cw: return .blue
        case .fonie: return .green
        case .digi: return .purple
        }
    }

    /// Welche Betriebsarten zur Gruppe gehören (für die Legende).
    var detail: String {
        switch self {
        case .cw: return "CW-U/CW-L"
        case .fonie: return "SSB/AM/FM"
        case .digi: return "RTTY/DATA"
        }
    }

    /// Übliches Rapport-Format: 59 bei Fonie, 599 bei CW und Digi.
    var defaultRST: String { self == .fonie ? "59" : "599" }
}

// MARK: - JSON-Hilfen

extension KeyedDecodingContainer {
    /// Text-Feld; fehlt es oder hat es den falschen Typ, gibt es `""` (robust gegen von Hand bearbeitete Dateien).
    func text(_ key: K) -> String {
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil { return s }
        if let i = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return String(i) }
        return ""
    }

    /// Ganzzahl-Feld; fehlt es, gibt es `0`. Zahlen als Text werden ebenfalls gelesen.
    func number(_ key: K) -> Int {
        if let i = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return i }
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil, let i = Int(s) { return i }
        return 0
    }
}

/// Formatter mit festem Format in UTC.
enum UTCFormat {
    static func make(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = pattern
        return f
    }

    static let date = make("yyyy-MM-dd")
    static let time = make("HH:mm:ss")
    static let stamp = make("yyyy-MM-dd HH:mm:ss")
    static let adifDate = make("yyyyMMdd")
    static let adifTime = make("HHmmss")
    static let hhmm = make("HHmm")
}

// MARK: - QSO

/// Eine geloggte Funkverbindung. Normale QSOs haben ein leeres ``contest``-Feld,
/// Contest-QSOs tragen die Kennung ihrer ``ContestSession``.
struct QSO: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Zeitpunkt (UTC), in der Datei als `"utc": "2026-09-28T14:05:00Z"`.
    var time: Date
    var call: String
    var freqHz: Int
    var band: String
    var mode: String
    var rstSent = ""
    var rstRcvd = ""
    var name = ""
    var qth = ""
    var locator = ""
    /// Sendeleistung in Watt (Text, wie eingegeben).
    var power = ""
    var comment = ""
    /// Kennung der Contest-Sitzung; leer = normales QSO.
    var contest = ""
    /// Gesendete laufende Nummer (0 = keine).
    var serialSent = 0
    /// Gesendeter Exchange (feste Angabe wie Zone/DOK; bei Nummern-Contests leer).
    var exchSent = ""
    /// Empfangener Exchange (Nummer, Zone, DOK …).
    var exchRcvd = ""

    enum CodingKeys: String, CodingKey {
        case id, time = "utc", call, freqHz, band, mode, rstSent, rstRcvd, name, qth, locator, power, comment
        case contest, serialSent, exchSent, exchRcvd
    }

    init(time: Date = QSO.now(), call: String, freqHz: Int, mode: String) {
        self.time = time
        self.call = call.uppercased()
        self.freqHz = freqHz
        self.band = BandPlan.name(for: freqHz)
        self.mode = mode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        time = try c.decode(Date.self, forKey: .time)
        call = c.text(.call).uppercased()
        freqHz = c.number(.freqHz)
        let b = c.text(.band)
        band = b.isEmpty ? BandPlan.name(for: freqHz) : b
        mode = c.text(.mode)
        rstSent = c.text(.rstSent)
        rstRcvd = c.text(.rstRcvd)
        name = c.text(.name)
        qth = c.text(.qth)
        locator = c.text(.locator)
        power = c.text(.power)
        comment = c.text(.comment)
        contest = c.text(.contest)
        serialSent = c.number(.serialSent)
        exchSent = c.text(.exchSent)
        exchRcvd = c.text(.exchRcvd)
    }

    /// Aktuelle Zeit, auf ganze Sekunden gekürzt.
    static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    var group: ModeGroup { ModeGroup.of(mode) }
    var isContest: Bool { !contest.isEmpty }
    var dateText: String { UTCFormat.date.string(from: time) }
    var timeText: String { UTCFormat.time.string(from: time) }
    var freqKHzText: String { String(format: "%.2f", Double(freqHz) / 1000) }
    var freqMHzText: String { String(format: "%.3f", Double(freqHz) / 1_000_000) }
    /// Gesendeter Rapport, sonst der übliche Standardwert.
    var rstSentOrDefault: String { rstSent.isEmpty ? group.defaultRST : rstSent }
    var rstRcvdOrDefault: String { rstRcvd.isEmpty ? group.defaultRST : rstRcvd }
    /// Gesendeter Exchange zur Anzeige: laufende Nummer (3-stellig) oder feste Angabe.
    var sentExchangeText: String {
        serialSent > 0 ? String(format: "%03d", serialSent) : exchSent
    }

    /// Liest eine Zeile des alten Text-Logs (`Datum;UTC;Rufzeichen;Frequenz kHz;Band;Modus`).
    static func parseLegacy(_ line: String) -> QSO? {
        let p = line.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard p.count >= 6,
              let time = UTCFormat.stamp.date(from: p[0] + " " + p[1]),
              let khz = Double(p[3]), !p[2].isEmpty else { return nil }
        var q = QSO(time: time, call: p[2], freqHz: Int((khz * 1000).rounded()), mode: p[5])
        if !p[4].isEmpty { q.band = p[4] }
        return q
    }
}

// MARK: - Station

/// Eigene Stationsdaten für Cabrillo-Kopf und ADIF.
struct Station: Codable, Equatable {
    var callsign = ""
    var name = ""
    var locator = ""
    var address = ""
    var postcode = ""
    var city = ""
    var country = ""
    var email = ""
    var club = ""

    enum CodingKeys: String, CodingKey {
        case callsign, name, locator, address, postcode, city, country, email, club
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callsign = c.text(.callsign).uppercased()
        name = c.text(.name)
        locator = c.text(.locator)
        address = c.text(.address)
        postcode = c.text(.postcode)
        city = c.text(.city)
        country = c.text(.country)
        email = c.text(.email)
        club = c.text(.club)
    }
}

// MARK: - Contest-Sitzung

/// Ein Contest-Durchgang (z. B. „CQ WW SSB 2026“) mit Exchange-Regel und Cabrillo-Kategorien.
struct ContestSession: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    /// Anzeigename, z. B. „CQ WW DX SSB 2026“.
    var name = ""
    /// Wert für `CONTEST:` im Cabrillo-Kopf, z. B. `CQ-WW-SSB`.
    var cabrillo = ""
    var created = QSO.now()
    /// `"serial"` = laufende Nummer senden, `"fixed"` = feste Angabe (Zone, DOK, Leistung …) senden.
    var exchangeKind = "serial"
    /// Feste gesendete Angabe (nur bei `"fixed"`).
    var exchangeSent = ""
    /// Bezeichnung des Exchange-Felds, z. B. „CQ-Zone“ oder „DOK“.
    var exchangeLabel = "Nr."
    var catOperator = "SINGLE-OP"
    var catAssisted = "NON-ASSISTED"
    var catBand = "ALL"
    /// Leer = automatisch aus den QSOs bestimmen.
    var catMode = ""
    var catPower = "LOW"
    var catStation = "FIXED"
    var catTransmitter = "ONE"
    var location = ""
    var operators = ""
    var soapbox = ""

    enum CodingKeys: String, CodingKey {
        case id, name, cabrillo, created, exchangeKind, exchangeSent, exchangeLabel
        case catOperator, catAssisted, catBand, catMode, catPower, catStation, catTransmitter
        case location, operators, soapbox
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let i = c.text(.id)
        id = i.isEmpty ? UUID().uuidString : i
        name = c.text(.name)
        cabrillo = c.text(.cabrillo)
        created = (try? c.decode(Date.self, forKey: .created)) ?? QSO.now()
        let k = c.text(.exchangeKind)
        exchangeKind = k.isEmpty ? "serial" : k
        exchangeSent = c.text(.exchangeSent)
        let l = c.text(.exchangeLabel)
        exchangeLabel = l.isEmpty ? "Exchange" : l
        func or(_ key: CodingKeys, _ def: String) -> String {
            let v = c.text(key)
            return v.isEmpty ? def : v
        }
        catOperator = or(.catOperator, "SINGLE-OP")
        catAssisted = or(.catAssisted, "NON-ASSISTED")
        catBand = or(.catBand, "ALL")
        catMode = c.text(.catMode)
        catPower = or(.catPower, "LOW")
        catStation = or(.catStation, "FIXED")
        catTransmitter = or(.catTransmitter, "ONE")
        location = c.text(.location)
        operators = c.text(.operators)
        soapbox = c.text(.soapbox)
    }

    var isSerial: Bool { exchangeKind == "serial" }
}

/// Vorlage für gängige KW-Conteste; füllt beim Anlegen einer Sitzung die Felder vor.
struct ContestTemplate: Identifiable, Hashable {
    let title: String
    let cabrillo: String
    let serial: Bool
    let sent: String
    let label: String
    let mode: String
    let location: String

    var id: String { title }

    static let all: [ContestTemplate] = [
        ContestTemplate(title: "CQ WW DX SSB", cabrillo: "CQ-WW-SSB", serial: false, sent: "14", label: "CQ-Zone", mode: "SSB", location: "DX"),
        ContestTemplate(title: "CQ WW DX CW", cabrillo: "CQ-WW-CW", serial: false, sent: "14", label: "CQ-Zone", mode: "CW", location: "DX"),
        ContestTemplate(title: "CQ WW DX RTTY", cabrillo: "CQ-WW-RTTY", serial: false, sent: "14", label: "CQ-Zone", mode: "RTTY", location: "DX"),
        ContestTemplate(title: "CQ WPX SSB", cabrillo: "CQ-WPX-SSB", serial: true, sent: "", label: "Nr.", mode: "SSB", location: ""),
        ContestTemplate(title: "CQ WPX CW", cabrillo: "CQ-WPX-CW", serial: true, sent: "", label: "Nr.", mode: "CW", location: ""),
        ContestTemplate(title: "CQ WPX RTTY", cabrillo: "CQ-WPX-RTTY", serial: true, sent: "", label: "Nr.", mode: "RTTY", location: ""),
        ContestTemplate(title: "IARU HF Championship", cabrillo: "IARU-HF", serial: false, sent: "28", label: "ITU-Zone", mode: "MIXED", location: ""),
        ContestTemplate(title: "ARRL DX CW", cabrillo: "ARRL-DX-CW", serial: false, sent: "100", label: "Leistung/State", mode: "CW", location: "DX"),
        ContestTemplate(title: "ARRL DX SSB", cabrillo: "ARRL-DX-SSB", serial: false, sent: "100", label: "Leistung/State", mode: "SSB", location: "DX"),
        ContestTemplate(title: "WAE DX CW", cabrillo: "DARC-WAEDC-CW", serial: true, sent: "", label: "Nr.", mode: "CW", location: ""),
        ContestTemplate(title: "WAE DX SSB", cabrillo: "DARC-WAEDC-SSB", serial: true, sent: "", label: "Nr.", mode: "SSB", location: ""),
        ContestTemplate(title: "WAG (Worked All Germany)", cabrillo: "WAG", serial: false, sent: "", label: "DOK/Nr.", mode: "MIXED", location: ""),
        ContestTemplate(title: "Eigener Contest", cabrillo: "", serial: true, sent: "", label: "Nr.", mode: "", location: "")
    ]
}

// MARK: - Datei

/// Aufbau der JSON-Datei. Schlüssel sind sortiert und die Datei eingerückt, damit sie gut
/// mit Perl (`JSON::PP`) oder von Hand lesbar ist.
private struct LogFile: Codable {
    var format = "MikeFoxtrott-Logbuch"
    var version = 1
    var station = Station()
    var contests: [ContestSession] = []
    var qsos: [QSO] = []

    enum CodingKeys: String, CodingKey { case format, version, station, contests, qsos }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.text(.format)
        version = c.number(.version)
        station = (try c.decodeIfPresent(Station.self, forKey: .station)) ?? Station()
        contests = (try c.decodeIfPresent([ContestSession].self, forKey: .contests)) ?? []
        qsos = (try c.decodeIfPresent([QSO].self, forKey: .qsos)) ?? []
    }
}

// MARK: - Logbuch

/// Das gemeinsame Logbuch für normale QSOs und Contest-QSOs, gespeichert als eine JSON-Datei.
///
/// Jede Änderung schreibt die ganze Datei atomar neu (erst temporär, dann umbenennen) –
/// bei einem Absturz bleibt immer eine vollständige Datei übrig. Beim Start wird einmal eine
/// Sicherung `…json.bak` angelegt.
@MainActor
@Observable
final class Logbook {
    /// Alle QSOs, chronologisch.
    private(set) var qsos: [QSO] = []
    private(set) var contests: [ContestSession] = []
    private(set) var station = Station()
    /// Gewählte Contest-Sitzung (wird in den `UserDefaults` gemerkt).
    private(set) var activeContestID: String?
    private(set) var fileURL: URL
    var lastError: String?
    var info: String?

    private static let pathKey = "logbookPath"
    private static let activeKey = "activeContestID"
    private static let legacyKey = "contestLogPath"

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Mike Foxtrott/logbuch.json")
    }

    init() {
        if let p = UserDefaults.standard.string(forKey: Self.pathKey) {
            fileURL = URL(fileURLWithPath: p)
        } else {
            fileURL = Self.defaultURL
        }
        activeContestID = UserDefaults.standard.string(forKey: Self.activeKey)
        load()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            importLegacyTextLog()
        }
        backupOnce()
    }

    // MARK: Laden / Speichern

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Liest die Datei neu ein; fehlt sie, ist das Logbuch leer.
    func load() {
        lastError = nil
        qsos = []
        contests = []
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            validateActive()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let f = try Self.decoder().decode(LogFile.self, from: data)
            station = f.station
            contests = f.contests
            qsos = f.qsos.sorted { $0.time < $1.time }
        } catch {
            lastError = "Logbuch konnte nicht gelesen werden: \(error.localizedDescription)"
        }
        validateActive()
    }

    private func validateActive() {
        if let a = activeContestID, !contests.contains(where: { $0.id == a }) {
            setActiveContest(nil)
        }
    }

    /// Schreibt die ganze Datei atomar.
    @discardableResult
    private func save() -> Bool {
        var f = LogFile()
        f.station = station
        f.contests = contests
        f.qsos = qsos
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var data = try Self.encoder().encode(f)
            data.append(0x0A)
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
            return true
        } catch {
            lastError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            return false
        }
    }

    /// Legt beim Start einmal eine Sicherungskopie `….json.bak` an.
    private func backupOnce() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let bak = fileURL.appendingPathExtension("bak")
        try? fm.removeItem(at: bak)
        try? fm.copyItem(at: fileURL, to: bak)
    }

    /// Übernimmt beim ersten Start das alte Text-Contest-Log als Contest-Sitzung „Import“.
    private func importLegacyTextLog() {
        let path = UserDefaults.standard.string(forKey: Self.legacyKey)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/FT891-Contest-Log.txt").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let old = text.split(whereSeparator: \.isNewline).compactMap { raw -> QSO? in
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
            return QSO.parseLegacy(s)
        }
        guard !old.isEmpty else { return }
        var session = ContestSession()
        session.name = "Import aus Text-Log"
        session.created = old.first?.time ?? QSO.now()
        contests.append(session)
        for (i, legacy) in old.enumerated() {
            var q = legacy
            q.contest = session.id
            q.serialSent = i + 1
            qsos.append(q)
        }
        qsos.sort { $0.time < $1.time }
        if save() {
            info = "\(old.count) QSOs aus \(path) als Contest „\(session.name)“ übernommen. Die Textdatei bleibt unverändert."
        }
    }

    // MARK: Datei wählen

    func chooseExisting() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Bestehende Logbuch-Datei (JSON) wählen"
        if panel.runModal() == .OK, let url = panel.url { setFile(url) }
    }

    /// Neue Datei; die Stationsdaten werden übernommen. Existiert die Datei schon, wird sie geöffnet.
    func chooseNew() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "logbuch.json"
        panel.message = "Name und Ort der neuen Logbuch-Datei"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            setFile(url)
        } else {
            let keep = station
            fileURL = url
            UserDefaults.standard.set(url.path, forKey: Self.pathKey)
            qsos = []
            contests = []
            station = keep
            setActiveContest(nil)
            save()
        }
    }

    private func setFile(_ url: URL) {
        fileURL = url
        UserDefaults.standard.set(url.path, forKey: Self.pathKey)
        load()
        backupOnce()
    }

    func revealInFinder() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
        }
    }

    // MARK: Änderungen

    /// Fügt ein QSO hinzu und speichert. Bei Fehler wird nichts übernommen.
    @discardableResult
    func add(_ q: QSO) -> Bool {
        let old = qsos
        qsos.append(q)
        qsos.sort { $0.time < $1.time }
        if save() { return true }
        qsos = old
        return false
    }

    /// Ersetzt ein QSO (gleiche `id`).
    @discardableResult
    func update(_ q: QSO) -> Bool {
        guard let i = qsos.firstIndex(where: { $0.id == q.id }) else { return false }
        let old = qsos
        var n = q
        n.call = n.call.uppercased()
        qsos[i] = n
        qsos.sort { $0.time < $1.time }
        if save() { return true }
        qsos = old
        return false
    }

    func remove(id: UUID) {
        let old = qsos
        qsos.removeAll { $0.id == id }
        if !save() { qsos = old }
    }

    func updateStation(_ s: Station) {
        let old = station
        var n = s
        n.callsign = n.callsign.uppercased()
        n.locator = n.locator.uppercased()
        station = n
        if !save() { station = old }
    }

    /// Legt eine Contest-Sitzung an oder ersetzt sie (gleiche `id`).
    func upsertContest(_ c: ContestSession) {
        let old = contests
        if let i = contests.firstIndex(where: { $0.id == c.id }) {
            contests[i] = c
        } else {
            contests.append(c)
        }
        if save() {
            setActiveContest(c.id)
        } else {
            contests = old
        }
    }

    /// Löscht eine Sitzung – nur möglich, wenn sie keine QSOs enthält.
    func removeContest(id: String) {
        guard qsos(inContest: id).isEmpty else {
            lastError = "Contest enthält noch QSOs und wird nicht gelöscht."
            return
        }
        let old = contests
        contests.removeAll { $0.id == id }
        if save() {
            if activeContestID == id { setActiveContest(nil) }
        } else {
            contests = old
        }
    }

    func setActiveContest(_ id: String?) {
        activeContestID = id
        UserDefaults.standard.set(id, forKey: Self.activeKey)
    }

    // MARK: Abfragen

    var activeContest: ContestSession? {
        guard let a = activeContestID else { return nil }
        return contests.first { $0.id == a }
    }

    func contest(id: String) -> ContestSession? {
        contests.first { $0.id == id }
    }

    /// Normale QSOs (ohne Contest).
    var normalQSOs: [QSO] { qsos.filter { !$0.isContest } }

    func qsos(inContest id: String) -> [QSO] {
        qsos.filter { $0.contest == id }
    }

    /// QSOs des heutigen UTC-Tages.
    var todayQSOs: [QSO] {
        let today = UTCFormat.date.string(from: Date())
        return qsos.filter { $0.dateText == today }
    }

    /// Nächste laufende Nummer in einer Sitzung.
    func nextSerial(for id: String) -> Int {
        (qsos(inContest: id).map(\.serialSent).max() ?? 0) + 1
    }

    /// Alle QSOs mit diesem Rufzeichen (ganzes Logbuch).
    func worked(_ call: String) -> [QSO] {
        qsos.filter { $0.call == call }
    }

    /// Dupe innerhalb einer Sitzung: gleiches Rufzeichen, Band und Betriebsartgruppe.
    func dupe(call: String, freqHz: Int, mode: String, contest id: String) -> QSO? {
        let band = BandPlan.name(for: freqHz)
        let group = ModeGroup.of(mode)
        return qsos.first { $0.contest == id && $0.call == call && $0.band == band && $0.group == group }
    }

    // MARK: Export

    /// Speichert Text über einen Sichern-Dialog.
    func saveText(_ text: String, suggestedName: String, type: UTType, message: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            info = "Gespeichert: \(url.path)"
            lastError = nil
        } catch {
            lastError = "Export fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func exportADIF(_ list: [QSO]) {
        let text = ADIF.export(list, station: station, contests: contests)
        let type = UTType(filenameExtension: "adi") ?? .plainText
        saveText(text, suggestedName: "logbuch.adi", type: type, message: "ADIF-Export (\(list.count) QSOs)")
    }

    func exportCabrillo(_ session: ContestSession) {
        guard !station.callsign.isEmpty else {
            lastError = "Für Cabrillo zuerst unter „Station …“ das eigene Rufzeichen eintragen."
            return
        }
        let list = qsos(inContest: session.id)
        let text = Cabrillo.export(session: session, qsos: list, station: station)
        let base = session.cabrillo.isEmpty ? "contest" : session.cabrillo
        let type = UTType(filenameExtension: "log") ?? .plainText
        let file = "\(station.callsign.replacingOccurrences(of: "/", with: "_"))-\(base).log"
        saveText(text, suggestedName: file, type: type, message: "Cabrillo-Export (\(list.count) QSOs)")
    }
}

// MARK: - ADIF

/// ADIF-3-Export (für LoTW, QRZ.com, eQSL, Clublog …).
enum ADIF {
    /// Wandelt Umlaute usw. in ASCII um (ADIF-Textfelder sind ASCII).
    static func ascii(_ s: String) -> String {
        let r = s.replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue").replacingOccurrences(of: "Ä", with: "Ae")
            .replacingOccurrences(of: "Ö", with: "Oe").replacingOccurrences(of: "Ü", with: "Ue")
        let stripped = r.applyingTransform(.stripDiacritics, reverse: false) ?? r
        return String(stripped.unicodeScalars.filter { $0.isASCII && $0.value >= 32 }.map(Character.init))
    }

    static func field(_ name: String, _ value: String) -> String {
        let v = ascii(value).trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return "" }
        return "<\(name):\(v.utf8.count)>\(v) "
    }

    /// Betriebsart → ADIF MODE / SUBMODE.
    static func mode(_ m: String) -> (String, String?) {
        let u = m.uppercased()
        switch u {
        case "USB": return ("SSB", "USB")
        case "LSB": return ("SSB", "LSB")
        case "SSB": return ("SSB", nil)
        case "CW", "CW-U", "CW-L": return ("CW", nil)
        case "AM", "AM-N": return ("AM", nil)
        case "FM", "FM-N": return ("FM", nil)
        case "RTTY", "RTTY-USB", "RTTY-LSB": return ("RTTY", nil)
        case "FT8": return ("FT8", nil)
        case "FT4": return ("MFSK", "FT4")
        case "JS8": return ("MFSK", "JS8")
        case "PSK31": return ("PSK", "PSK31")
        case "PSK63": return ("PSK", "PSK63")
        default: return (u, nil)
        }
    }

    static func export(_ list: [QSO], station: Station, contests: [ContestSession]) -> String {
        var out = "Mike Foxtrott ADIF-Export \(UTCFormat.stamp.string(from: Date())) UTC\n"
        out += field("ADIF_VER", "3.1.4") + field("PROGRAMID", "Mike Foxtrott") + "<EOH>\n\n"
        for q in list.sorted(by: { $0.time < $1.time }) {
            var r = field("CALL", q.call)
            r += field("QSO_DATE", UTCFormat.adifDate.string(from: q.time))
            r += field("TIME_ON", UTCFormat.adifTime.string(from: q.time))
            if q.band != "GEN" { r += field("BAND", q.band.lowercased()) }
            r += field("FREQ", String(format: "%.6f", Double(q.freqHz) / 1_000_000))
            let (m, sub) = mode(q.mode)
            r += field("MODE", m)
            if let sub { r += field("SUBMODE", sub) }
            r += field("RST_SENT", q.rstSentOrDefault)
            r += field("RST_RCVD", q.rstRcvdOrDefault)
            r += field("NAME", q.name)
            r += field("QTH", q.qth)
            r += field("GRIDSQUARE", q.locator)
            let pwr = q.power.filter { $0.isNumber || $0 == "." }
            r += field("TX_PWR", pwr)
            r += field("COMMENT", q.comment)
            r += field("STATION_CALLSIGN", station.callsign)
            r += field("MY_GRIDSQUARE", station.locator)
            if q.isContest {
                let c = contests.first { $0.id == q.contest }
                r += field("CONTEST_ID", c?.cabrillo ?? "")
                if q.serialSent > 0 { r += field("STX", String(q.serialSent)) }
                r += field("STX_STRING", q.exchSent)
                if let n = Int(q.exchRcvd) { r += field("SRX", String(n)) }
                r += field("SRX_STRING", q.exchRcvd)
            }
            out += r + "<EOR>\n"
        }
        return out
    }
}

// MARK: - Cabrillo

/// Cabrillo-3.0-Export einer Contest-Sitzung.
enum Cabrillo {
    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    static func padLeft(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }

    /// Betriebsart → Cabrillo-Kürzel (PH, CW, RY, DG, FM).
    static func mode(_ m: String) -> String {
        let u = m.uppercased()
        if u.hasPrefix("CW") { return "CW" }
        if u.hasPrefix("RTTY") { return "RY" }
        if u.hasPrefix("FM") { return "FM" }
        if ModeGroup.of(u) == .fonie { return "PH" }
        return "DG"
    }

    /// CATEGORY-MODE aus den QSOs, wenn in der Sitzung „automatisch“ gewählt ist.
    static func categoryMode(_ list: [QSO]) -> String {
        let set = Set(list.map { mode($0.mode) })
        if set.isEmpty { return "MIXED" }
        if set == ["CW"] { return "CW" }
        if set.isSubset(of: ["PH"]) { return "SSB" }
        if set == ["FM"] { return "FM" }
        if set == ["RY"] { return "RTTY" }
        if set.isSubset(of: ["RY", "DG"]) { return "DIGI" }
        return "MIXED"
    }

    static func clean(_ s: String) -> String {
        ADIF.ascii(s).replacingOccurrences(of: " ", with: "").uppercased()
    }

    static func export(session: ContestSession, qsos: [QSO], station: Station) -> String {
        let list = qsos.sorted { $0.time < $1.time }
        var h: [String] = ["START-OF-LOG: 3.0", "CREATED-BY: Mike Foxtrott (FT-891)"]
        func add(_ key: String, _ value: String) {
            let v = ADIF.ascii(value).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { h.append("\(key): \(v)") }
        }
        add("CONTEST", session.cabrillo)
        add("CALLSIGN", station.callsign)
        add("LOCATION", session.location)
        add("CATEGORY-OPERATOR", session.catOperator)
        add("CATEGORY-ASSISTED", session.catAssisted)
        add("CATEGORY-BAND", session.catBand)
        add("CATEGORY-MODE", session.catMode.isEmpty ? categoryMode(list) : session.catMode)
        add("CATEGORY-POWER", session.catPower)
        add("CATEGORY-STATION", session.catStation)
        add("CATEGORY-TRANSMITTER", session.catTransmitter)
        add("GRID-LOCATOR", station.locator)
        add("CLUB", station.club)
        add("OPERATORS", session.operators.isEmpty ? station.callsign : session.operators)
        add("NAME", station.name)
        add("ADDRESS", station.address)
        add("ADDRESS-CITY", station.city)
        add("ADDRESS-POSTALCODE", station.postcode)
        add("ADDRESS-COUNTRY", station.country)
        add("EMAIL", station.email)
        for line in session.soapbox.split(whereSeparator: \.isNewline) {
            add("SOAPBOX", String(line))
        }
        let my = clean(station.callsign)
        for q in list {
            let khz = String(Int((Double(q.freqHz) / 1000).rounded()))
            let sent = clean(q.serialSent > 0 ? String(format: "%03d", q.serialSent) : q.exchSent)
            let rcvd = clean(q.exchRcvd)
            let parts = [
                "QSO:", padLeft(khz, 5), mode(q.mode),
                UTCFormat.date.string(from: q.time), UTCFormat.hhmm.string(from: q.time),
                pad(my, 13), pad(clean(q.rstSentOrDefault), 3), pad(sent.isEmpty ? "-" : sent, 6),
                pad(clean(q.call), 13), pad(clean(q.rstRcvdOrDefault), 3), pad(rcvd.isEmpty ? "-" : rcvd, 6)
            ]
            h.append(parts.joined(separator: " ").trimmingCharacters(in: .whitespaces))
        }
        h.append("END-OF-LOG:")
        return h.joined(separator: "\n") + "\n"
    }
}
