import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

/// Zustand der Verbindung zum Funkgerät.
enum ConnectionState {
    /// Keine Schnittstelle offen.
    case disconnected
    /// Verbindungsaufbau oder Auto-Erkennung läuft.
    case connecting
    /// Schnittstelle offen, Gerät hat auf `ID;` geantwortet.
    case connected
}

/// Eine Zeile im Protokoll-Reiter.
struct LogLine: Identifiable {
    let id = UUID()
    /// Zeitpunkt des Eintrags (Ortszeit, nur zur Anzeige).
    let time = Date()
    /// Gesendet (`→`), empfangen (`←`) oder Information (`•`).
    let direction: LogDirection
    /// Der CAT-Frame bzw. der Informationstext.
    let text: String
}

/// Dateiformat der Geräte-Sicherung (JSON): Zeitstempel plus alle gelesenen Rohwerte.
private struct Backup: Codable {
    var radio: String
    var created: String
    var values: [String: String]
}

/// Zentrales Modell der App: Verbindung, Live-Werte und Parameter des FT-891.
///
/// `Radio` kapselt das CAT-Protokoll (Yaesu „FT-891 CAT Operation Reference Book“) und hält alle Werte als
/// beobachtbaren Zustand, den die SwiftUI-Ansichten direkt darstellen. Alles läuft auf dem Main-Actor;
/// ein zyklisches Polling (``startPolling()``) hält Frequenz, Betriebsart und Messwerte aktuell.
///
/// - Important: Senden (PTT, Tuner, MOX) ist gesperrt, solange ``allowTX`` nicht bewusst eingeschaltet wurde.
@MainActor
@Observable
final class Radio {
    // MARK: Verbindung

    /// Gefundene serielle Ports (`/dev/cu.*`).
    var ports: [String] = []
    /// Gewählter Port; wird beim Verbinden in den `UserDefaults` gemerkt.
    var selectedPort = ""
    /// Baudrate; muss zu Menü 05-06 CAT RATE des Geräts passen (Werkseinstellung 4800).
    var baud = 4800
    /// Zwei Stoppbits statt einem (selten nötig, wird bei der Auto-Erkennung mitprobiert).
    var twoStopBits = false
    /// Verbindungszustand der seriellen Schnittstelle.
    var state: ConnectionState = .disconnected
    /// Kurzer Statustext für die Verbindungsleiste.
    var statusText = "Nicht verbunden"
    /// Fortschrittstext während der Auto-Erkennung; überschreibt ``statusText``, solange er gesetzt ist.
    var busyText: String?
    /// Meldung für den Hinweisdialog; `nil` = kein Dialog. Wird vom Dialog selbst wieder gelöscht.
    var alertMessage: String?
    /// `true`, wenn das Gerät mehrfach nicht antwortet, obwohl der Port offen ist (z. B. ausgeschaltet).
    var noResponse = false
    /// Erkannte Gerätekennung (aus der Antwort auf `ID;`).
    var radioID = ""

    // MARK: Live-Werte

    /// Frequenz VFO A in Hz.
    var freqA = 0
    /// Frequenz VFO B in Hz (wird seltener aktualisiert).
    var freqB = 0
    /// Betriebsart als CAT-Code (`"1"` = LSB, `"2"` = USB …, siehe ``Catalog/modes``).
    var mode = "2"
    /// VFO-/Speicherstatus aus der IF-Antwort; `"0"` = VFO.
    var vfoState = "0"
    /// Speicherkanal (3 Ziffern) aus der IF-Antwort.
    var memChannel = "000"
    /// Clarifier (RIT/XIT) eingeschaltet.
    var clarOn = false
    /// Clarifier-Ablage in Hz.
    var clarOffset = 0
    /// Sendestatus: 0 = Empfang, 1 = per CAT gesendet, 2 = Gerät sendet (Taste/Mikrofon).
    var txState = 0
    /// Rohwerte der Messinstrumente (0–255); SWR, PO, ALC, COMP und ID liefert das Gerät nur beim Senden.
    var sRaw = 0
    var swrRaw = 0
    var poRaw = 0
    var alcRaw = 0
    var compRaw = 0
    var idRaw = 0
    /// Höchster SWR-Rohwert der laufenden bzw. letzten Sendung.
    var swrPeak = 0
    /// Das Gerät meldet HI-SWR.
    var hiSWR = false
    /// Sicherheitsschalter: Ohne Freigabe sendet die App weder PTT noch Tuner noch MOX.
    var allowTX = false
    /// Per CAT-Befehl (nicht am Gerät) eingeschaltetes Senden.
    var catTX = false
    /// Ein SWR-Sweep läuft (``SweepController``): Polling und Bedienung sind dann pausiert.
    var sweepRunning = false

    // MARK: Abstimmung (Drehregler)

    /// Zulässige Schrittweiten des Drehreglers in Hz.
    static let tuneSteps = [10, 100, 1_000, 10_000]
    /// Aktuelle Schrittweite des Drehreglers in Hz (eine Rastung = ein Schritt).
    var tuneStep = 100

    // MARK: Parameter

    /// Zuletzt gelesene bzw. geschriebene Rohwerte, Schlüssel = ``Param/id``.
    var values: [String: String] = [:]
    /// Fehlermeldungen je Parameter (Lesen/Schreiben fehlgeschlagen).
    var errors: [String: String] = [:]
    /// Ein Massenvorgang (alle lesen / Sicherung zurückschreiben) läuft; das Polling pausiert dann.
    var bulkBusy = false
    /// Fortschritt des Massenvorgangs, 0…1.
    var progress = 0.0
    /// Protokoll aller gesendeten und empfangenen CAT-Frames (die letzten ~500).
    var log: [LogLine] = []

    /// Serialisierter CAT-Zugriff auf die Schnittstelle.
    let client = CATClient()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Zähler der Poll-Durchläufe; steuert, welche seltener nötigen Werte reihum gelesen werden.
    @ObservationIgnored private var cycle = 0
    /// Aufeinanderfolgende fehlgeschlagene Abfragen; ab 3 gilt das Gerät als nicht antwortend.
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var cancelBulk = false
    /// Zeitpunkt der letzten lokalen Änderung je Parameter – kurz danach überschreibt das Polling den Wert nicht.
    @ObservationIgnored private var lastEdit: [String: Date] = [:]
    @ObservationIgnored private var catTXStart: Date?
    /// IS-Antwort enthält ON/OFF-Flag (neuere Handbuchausgabe).
    @ObservationIgnored private var isFlag = false
    /// Dito für SH (Flag-Zeichen der Antwort, falls vorhanden).
    @ObservationIgnored private var shFlag: String?
    @ObservationIgnored private var connectedStatus = ""
    /// Zuletzt gewünschte Frequenz, die noch nicht zum Gerät gesendet wurde.
    @ObservationIgnored private var pendingFreq: Int?
    /// Ein Sendevorgang für ``pendingFreq`` läuft (verhindert parallele FA-Befehle).
    @ObservationIgnored private var freqSending = false
    /// Zeitpunkt der letzten lokalen Frequenzänderung.
    @ObservationIgnored private var freqSetAt = Date.distantPast
    /// Kurz nach einer lokalen Änderung keine (veralteten) Frequenzwerte vom Gerät übernehmen.
    private var freqHold: Bool {
        pendingFreq != nil || Date().timeIntervalSince(freqSetAt) < 0.6
    }

    /// Ob die Schnittstelle offen und die Kennung bestätigt ist.
    var isConnected: Bool { state == .connected }

    /// Richtet die Rückrufe des CAT-Clients ein, lädt gemerkte Einstellungen und sorgt dafür,
    /// dass beim Beenden der App ein laufendes CAT-Senden abgeschaltet wird.
    init() {
        client.onLog = { [weak self] dir, text in
            self?.appendLog(dir, text)
        }
        client.onFrame = { [weak self] frame in
            self?.handleUnsolicited(frame)
        }
        client.onHangup = { [weak self] in
            self?.connectionLost()
        }
        refreshPorts()
        loadDefaults()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emergencyTXOff()
            }
        }
    }

    // MARK: - Ports & Einstellungen

    /// Liest die verfügbaren Ports neu ein und wählt bevorzugt den USB-Port des FT-891 (Silicon Labs CP210x).
    func refreshPorts() {
        ports = SerialPort.availablePorts()
        if !ports.contains(selectedPort) {
            selectedPort = ports.first(where: { $0.contains("usbserial") || $0.contains("SLAB") }) ?? ports.first ?? ""
        }
    }

    /// Lädt Port, Baudrate und Stoppbits aus den `UserDefaults`.
    private func loadDefaults() {
        let d = UserDefaults.standard
        if let p = d.string(forKey: "port"), ports.contains(p) { selectedPort = p }
        let b = d.integer(forKey: "baud")
        if [4800, 9600, 19200, 38400].contains(b) { baud = b }
        twoStopBits = d.bool(forKey: "twoStop")
    }

    /// Merkt sich die zuletzt erfolgreich genutzten Verbindungseinstellungen.
    private func saveDefaults() {
        let d = UserDefaults.standard
        d.set(selectedPort, forKey: "port")
        d.set(baud, forKey: "baud")
        d.set(twoStopBits, forKey: "twoStop")
    }

    // MARK: - Verbinden

    /// Verbindet mit dem gewählten Port und der eingestellten Baudrate.
    ///
    /// Das Gerät muss innerhalb von 900 ms auf `ID;` mit `ID0650;` antworten; sonst erscheint ein Hinweis mit möglichen Ursachen.
    func connect() {
        guard state == .disconnected, !selectedPort.isEmpty else { return }
        state = .connecting
        statusText = "Verbinde …"
        let path = selectedPort
        let b = baud
        let s = twoStopBits
        Task {
            do {
                if let answer = try await probe(path: path, baud: b, twoStop: s, timeoutMs: 900) {
                    await finishConnect(idAnswer: answer)
                } else {
                    state = .disconnected
                    statusText = "Nicht verbunden"
                    alertMessage = "Keine Antwort vom Funkgerät auf „ID;“. Prüfe: Gerät eingeschaltet, richtiger Port (das FT-891 hat zwei), Baudrate = Menü 05-06 CAT RATE."
                }
            } catch {
                state = .disconnected
                statusText = "Nicht verbunden"
                alertMessage = error.localizedDescription
            }
        }
    }

    /// Probiert alle Ports, Baudraten und Stoppbit-Varianten mit `ID;` durch, bis ein FT-891 antwortet.
    ///
    /// - Note: Öffnet dabei kurz auch den zweiten (Standard-)Port des Geräts.
    func autoDetect() {
        guard state == .disconnected else { return }
        state = .connecting
        refreshPorts()
        let ordered = ports.sorted { rank($0) < rank($1) }
        var bauds = [38400, 19200, 9600, 4800]
        if let i = bauds.firstIndex(of: baud) {
            bauds.remove(at: i)
            bauds.insert(baud, at: 0)
        }
        Task {
            for twoStop in [false, true] {
                for path in ordered {
                    for b in bauds {
                        busyText = "Prüfe \(path.replacingOccurrences(of: "/dev/", with: "")) @ \(b) bps \(twoStop ? "(2 Stoppbits) " : "")…"
                        let answer: String? = try? await probe(path: path, baud: b, twoStop: twoStop, timeoutMs: 350)
                        if let answer, answer == "ID0650;" {
                            selectedPort = path
                            baud = b
                            twoStopBits = twoStop
                            busyText = nil
                            await finishConnect(idAnswer: answer)
                            return
                        }
                    }
                }
            }
            client.close()
            busyText = nil
            state = .disconnected
            statusText = "Nicht verbunden"
            alertMessage = "Kein FT-891 gefunden. Ist das Gerät an und der USB-Treiber (Silicon Labs CP210x) installiert?"
        }
    }

    /// Sortierschlüssel für die Auto-Erkennung: USB-Ports des FT-891 (`usbserial`/`SLAB`) zuerst.
    private func rank(_ path: String) -> Int {
        (path.contains("usbserial") || path.contains("SLAB")) ? 0 : 1
    }

    /// Öffnet den Port und fragt die Geräte-ID ab.
    /// - Parameters:
    ///   - path: Gerätedatei, z. B. `/dev/cu.SLAB_USBtoUART`.
    ///   - baud: Baudrate.
    ///   - twoStop: Zwei Stoppbits verwenden.
    ///   - timeoutMs: Wartezeit auf die Antwort in Millisekunden.
    /// - Returns: Die Antwort (z. B. `ID0650;`) oder `nil`; bei `nil` ist der Port wieder geschlossen.
    /// - Throws: `SerialError`, wenn der Port nicht geöffnet werden kann.
    private func probe(path: String, baud: Int, twoStop: Bool, timeoutMs: Int) async throws -> String? {
        try client.open(path: path, baud: baud, twoStop: twoStop)
        try? await Task.sleep(nanoseconds: 400_000_000)
        do {
            if let r = try await client.transact("ID;", expect: "ID", timeoutMs: timeoutMs) {
                return r
            }
        } catch {
            // Keine (gültige) Antwort → Port wieder schließen
        }
        client.close()
        return nil
    }

    /// Schließt den Verbindungsaufbau ab: Auto-Information ausschalten, Grundzustand (IF) und alle Live-Parameter
    /// einmal lesen und das Polling starten.
    /// - Parameter idAnswer: Die Antwort auf `ID;`.
    private func finishConnect(idAnswer: String) async {
        radioID = idAnswer == "ID0650;" ? "FT-891" : "Unbekannte ID \(idAnswer)"
        state = .connected
        let short = selectedPort.replacingOccurrences(of: "/dev/", with: "")
        connectedStatus = "Verbunden – \(short) @ \(baud) bps"
        statusText = connectedStatus
        failures = 0
        noResponse = false
        saveDefaults()
        _ = try? await client.transact("AI0;", expect: nil, timeoutMs: 100)
        let ifFrame: String? = try? await client.transact("IF;", expect: "IF", timeoutMs: 500)
        if let ifFrame { parseIF(ifFrame) }
        for p in Catalog.liveParams { await read(p) }
        startPolling()
    }

    /// Trennt die Verbindung (schaltet vorher ein per CAT ausgelöstes Senden ab).
    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        emergencyTXOff()
        client.close()
        catTX = false
        catTXStart = nil
        state = .disconnected
        statusText = "Nicht verbunden"
        busyText = nil
        txState = 0
        noResponse = false
        failures = 0
        bulkBusy = false
    }

    /// Reaktion auf einen unerwarteten Abbruch (Kabel gezogen, Gerät aus): Zustand zurücksetzen und den Benutzer informieren.
    private func connectionLost() {
        guard state != .disconnected else { return }
        pollTask?.cancel()
        pollTask = nil
        catTX = false
        catTXStart = nil
        txState = 0
        bulkBusy = false
        state = .disconnected
        statusText = "Verbindung verloren"
        alertMessage = "Die serielle Verbindung wurde getrennt (USB-Kabel gezogen oder Funkgerät ausgeschaltet?)."
    }

    /// Schaltet ein per CAT eingeschaltetes Senden sofort und ohne Warten auf Antwort ab (auch beim Beenden der App).
    private func emergencyTXOff() {
        if catTX {
            _ = try? client.port.write("TX0;")
        }
    }

    // MARK: - Polling

    /// Startet die Abfrageschleife: Solange verbunden, wird ``pollOnce()`` wiederholt (40 ms Pause, bei
    /// ausbleibender Antwort 1 s). Während eines Massenvorgangs pausiert sie.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .connected else { break }
                if self.bulkBusy || self.sweepRunning {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    continue
                }
                await self.pollOnce()
                let pause: UInt64 = self.noResponse ? 1_000_000_000 : 40_000_000
                try? await Task.sleep(nanoseconds: pause)
            }
        }
    }

    /// Ein Abfragedurchlauf: erst der Sendestatus, dann je nach Zustand die Sende- oder Empfangswerte.
    /// Beendet außerdem CAT-Senden nach 2 Minuten automatisch.
    private func pollOnce() async {
        if catTX, let s = catTXStart, Date().timeIntervalSince(s) > 120 {
            setPTT(false)
            alertMessage = "CAT-Senden wurde nach 2 Minuten automatisch beendet."
        }
        do {
            if let tx = try await client.transact("TX;", expect: "TX", timeoutMs: 400, quiet: true) {
                markResponding()
                updateTX(tx)
            }
            if txState != 0 {
                try await pollTXMeters()
            } else {
                try await pollRX()
            }
        } catch CATError.notConnected {
            return
        } catch {
            pollFailed()
        }
    }

    /// Empfangsdurchlauf: IF (Frequenz, Modus, VFO), S-Meter, gelegentlich VFO B und reihum ein Live-Parameter.
    private func pollRX() async throws {
        cycle &+= 1
        if let f = try await client.transact("IF;", expect: "IF", timeoutMs: 400, quiet: true) {
            parseIF(f)
        }
        if let f = try await client.transact("SM0;", expect: "SM0", timeoutMs: 400, quiet: true),
           let v = Int(f.dropFirst(3).dropLast()) {
            if sRaw != v { sRaw = v }
        }
        if cycle % 8 == 0,
           let f = try await client.transact("FB;", expect: "FB", timeoutMs: 400, quiet: true),
           let v = Int(f.dropFirst(2).dropLast()) {
            if freqB != v { freqB = v }
        }
        let live = Catalog.liveParams
        if !live.isEmpty {
            await read(live[cycle % live.count], quiet: true)
        }
    }

    /// Sendedurchlauf: SWR, PO und ALC bei jedem Durchlauf; COMP, ID und HI-SWR jeden zweiten.
    private func pollTXMeters() async throws {
        cycle &+= 1
        if let v = try await meter("RM6;") {
            swrRaw = v
            if v > swrPeak { swrPeak = v }
        }
        if let v = try await meter("RM5;") { poRaw = v }
        if let v = try await meter("RM4;") { alcRaw = v }
        if cycle % 2 == 0 {
            if let v = try await meter("RM3;") { compRaw = v }
            if let v = try await meter("RM7;") { idRaw = v }
            if let f = try await client.transact("RI0;", expect: "RI0", timeoutMs: 400, quiet: true) {
                hiSWR = f.dropFirst(3).first == "1"
            }
        }
    }

    /// Liest ein Messinstrument (z. B. `RM6;` für SWR).
    /// - Parameter cmd: Lesebefehl inklusive `;`.
    /// - Returns: Rohwert 0–255 oder `nil`, wenn keine Antwort kam.
    private func meter(_ cmd: String) async throws -> Int? {
        let expect = String(cmd.dropLast())
        guard let f = try await client.transact(cmd, expect: expect, timeoutMs: 400, quiet: true) else { return nil }
        return Int(f.dropFirst(3).dropLast())
    }

    /// Wertet die Antwort auf `TX;` aus; setzt beim Wechsel Spitzen- und Messwerte zurück.
    private func updateTX(_ frame: String) {
        let n = Int(String(frame.dropFirst(2).prefix(1))) ?? 0
        if n != 0 && txState == 0 { swrPeak = 0 }
        if n == 0 && txState != 0 {
            poRaw = 0; alcRaw = 0; compRaw = 0; idRaw = 0; swrRaw = 0
        }
        if n != txState { txState = n }
    }

    /// Vermerkt, dass das Gerät antwortet, und nimmt eine „Keine Antwort“-Meldung zurück.
    private func markResponding() {
        failures = 0
        if noResponse {
            noResponse = false
            statusText = connectedStatus
        }
    }

    /// Zählt einen Fehlschlag; nach drei in Folge wird „Keine Antwort vom Funkgerät“ angezeigt.
    private func pollFailed() {
        failures += 1
        if failures >= 3 && !noResponse {
            noResponse = true
            statusText = "Keine Antwort vom Funkgerät – eingeschaltet? CAT RATE passend?"
        }
    }

    // MARK: - Antworten auswerten

    /// Wertet die IF-Antwort aus (Grundzustand des Geräts in einem Frame).
    ///
    /// Aufbau (28 Zeichen): `IF PPP FFFFFFFFF ±CCCC C 0 M V T 00 S ;` – Speicherkanal, Frequenz A, Clarifier-Ablage,
    /// Clarifier ein/aus, Betriebsart, VFO/Speicher. Die Frequenz wird nicht übernommen, solange eine lokale
    /// Änderung noch nicht beim Gerät angekommen ist (``freqHold``).
    /// - Parameter frame: Die vollständige Antwort inklusive `;`.
    private func parseIF(_ frame: String) {
        let c = Array(frame)
        guard c.count == 28, c[0] == "I", c[1] == "F" else { return }
        func sub(_ a: Int, _ b: Int) -> String { String(c[a...b]) }
        if let f = Int(sub(5, 13)), f != freqA, !freqHold { freqA = f }
        let ch = sub(2, 4)
        if ch != memChannel { memChannel = ch }
        let off = Int(sub(15, 18)) ?? 0
        let signed = c[14] == "-" ? -off : off
        if signed != clarOffset { clarOffset = signed }
        let on = c[19] == "1"
        if on != clarOn { clarOn = on }
        let md = String(c[21])
        if md != mode { mode = md }
        let vs = String(c[22])
        if vs != vfoState { vfoState = vs }
    }

    /// Verarbeitet Frames, die zu keiner laufenden Abfrage gehören (z. B. Auto-Information des Geräts).
    private func handleUnsolicited(_ frame: String) {
        if frame.hasPrefix("IF"), frame.count == 28 {
            parseIF(frame)
        } else if frame.hasPrefix("FA"), let v = Int(frame.dropFirst(2).dropLast()) {
            if !freqHold { freqA = v }
        } else if frame.hasPrefix("FB"), let v = Int(frame.dropFirst(2).dropLast()) {
            freqB = v
        } else if frame.hasPrefix("MD0"), frame.count == 5 {
            mode = String(frame.dropFirst(3).prefix(1))
        }
    }

    /// Hängt eine Zeile an das Protokoll an und begrenzt dessen Länge.
    private func appendLog(_ dir: LogDirection, _ text: String) {
        log.append(LogLine(direction: dir, text: text))
        if log.count > 600 { log.removeFirst(log.count - 500) }
    }

    // MARK: - Parameter lesen / schreiben

    /// Extrahiert den Rohwert aus einer Antwort und berücksichtigt Formatunterschiede zwischen den Handbuchausgaben
    /// (IS und SH mit oder ohne ON/OFF-Flag).
    private func parse(_ p: Param, frame: String) -> String? {
        guard var v = p.rawValue(from: frame) else { return nil }
        switch p.id {
        case "IS":
            if v.count == 6 {
                isFlag = true
                v.removeFirst()
            } else if v.count == 5 {
                isFlag = false
            }
        case "SH":
            if v.count == 3 {
                shFlag = String(v.removeFirst())
            } else {
                shFlag = nil
            }
        default:
            break
        }
        return v
    }

    /// Baut den Set-Befehl für einen Parameter, passend zum erkannten Format (IS/SH).
    private func setCommand(_ p: Param, raw: String) -> String {
        switch p.id {
        case "IS" where isFlag:
            let on = (Int(raw) ?? 0) != 0
            return "IS0" + (on ? "1" : "0") + raw + ";"
        case "SH" where shFlag != nil:
            return "SH0" + (shFlag ?? "1") + raw + ";"
        default:
            return p.prefix + raw + ";"
        }
    }

    /// Liest einen Parameter vom Gerät und speichert den Wert in ``values``.
    /// - Parameters:
    ///   - p: Der Parameter.
    ///   - quiet: Nicht ins Protokoll schreiben (für das Polling). Ein stiller Lesevorgang überschreibt keinen
    ///     Wert, der in den letzten 1,5 s lokal geändert wurde.
    func read(_ p: Param, quiet: Bool = false) async {
        guard client.isOpen else { return }
        do {
            guard let frame = try await client.transact(p.read, expect: p.expectPrefix, timeoutMs: 500, quiet: quiet),
                  let v = parse(p, frame: frame) else { return }
            if quiet, let t = lastEdit[p.id], Date().timeIntervalSince(t) < 1.5 { return }
            if values[p.id] != v { values[p.id] = v }
            if errors[p.id] != nil { errors[p.id] = nil }
        } catch CATError.notConnected {
            return
        } catch {
            errors[p.id] = error.localizedDescription
        }
    }

    /// Schreibt einen Parameter zum Gerät und liest ihn zur Kontrolle zurück.
    ///
    /// Der Wert wird sofort lokal übernommen (flüssige Bedienung). Werte, die den Sender einschalten
    /// (``Param/txValues``), werden ohne ``allowTX`` abgewiesen.
    /// - Parameters:
    ///   - p: Der Parameter.
    ///   - raw: Neuer Rohwert wie im CAT-Protokoll (z. B. `"015"`).
    func write(_ p: Param, raw: String) {
        guard state == .connected, !p.readOnly else { return }
        if p.txValues.contains(raw) && !allowTX {
            alertMessage = "Sendefunktionen sind gesperrt. Aktiviere im Live-Tab „Sendefunktionen freigeben“."
            return
        }
        lastEdit[p.id] = Date()
        values[p.id] = raw
        Task {
            do {
                try await client.transact(setCommand(p, raw: raw), expect: nil, timeoutMs: 200)
                errors[p.id] = nil
                if p.id == "EX0506" {
                    applyNewBaud(raw)
                } else {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    await read(p)
                }
            } catch CATError.notConnected {
                return
            } catch {
                errors[p.id] = error.localizedDescription
                await read(p)
            }
        }
    }

    /// Stellt die Schnittstelle um, nachdem CAT RATE (Menü 05-06) am Gerät geändert wurde.
    /// - Parameter code: Menüwert `"0"`…`"3"` = 4800, 9600, 19200, 38400 bps.
    private func applyNewBaud(_ code: String) {
        let map = ["0": 4800, "1": 9600, "2": 19200, "3": 38400]
        guard let b = map[code] else { return }
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            do {
                try client.port.setBaud(b, twoStopBits: twoStopBits)
                baud = b
                let short = selectedPort.replacingOccurrences(of: "/dev/", with: "")
                connectedStatus = "Verbunden – \(short) @ \(b) bps"
                statusText = connectedStatus
                saveDefaults()
                alertMessage = "CAT RATE geändert – die Verbindung läuft jetzt mit \(b) bps."
            } catch {
                alertMessage = "Baudrate konnte nicht umgestellt werden: \(error.localizedDescription)"
            }
        }
    }

    /// Anzeigetext für einen Zahlenwert; die Filterbreite (SH) hängt von Betriebsart und NAR ab.
    func displayText(_ p: Param, value: Int) -> String {
        if p.id == "SH" {
            return Bandwidth.label(index: value, mode: mode, narrow: values["NA"] == "1")
        }
        return p.display(p.encode(value))
    }

    /// Liest eine Liste von Parametern nacheinander (mit Fortschritt und Abbruchmöglichkeit).
    func readAll(_ list: [Param]) {
        guard state == .connected, !bulkBusy, !list.isEmpty else { return }
        bulkBusy = true
        cancelBulk = false
        progress = 0
        Task {
            var n = 0
            for p in list {
                if cancelBulk { break }
                await read(p)
                n += 1
                progress = Double(n) / Double(list.count)
            }
            bulkBusy = false
        }
    }

    /// Bricht einen laufenden Massenvorgang nach dem aktuellen Parameter ab.
    func cancelBulkOperation() {
        cancelBulk = true
    }

    // MARK: - Bedienung

    /// Stellt VFO A auf eine Frequenz (Eingabefeld, Schrittknöpfe, Bandleiste).
    /// - Parameter hz: Frequenz in Hz, erlaubt sind 30 kHz bis 56 MHz.
    /// - Note: Während des Sendens wird die Änderung ignoriert.
    func setFrequencyA(hz: Int) {
        guard state == .connected else { return }
        guard hz >= 30_000, hz <= 56_000_000 else {
            alertMessage = "Frequenz außerhalb von 0,03–56 MHz."
            return
        }
        guard txState == 0 else { return }
        setFrequencyLive(hz)
    }

    /// Drehregler: `steps` Rastungen (positiv = höher) mit der eingestellten Schrittweite.
    func tuneBy(steps: Int) {
        guard state == .connected, txState == 0, steps != 0 else { return }
        let hz = min(max(freqA + steps * tuneStep, 30_000), 56_000_000)
        setFrequencyLive(hz)
    }

    /// Setzt die Anzeige sofort und sendet nur den jeweils neuesten Wert (schnelles Drehen erzeugt keine Befehlsflut).
    private func setFrequencyLive(_ hz: Int) {
        guard !sweepRunning else { return }
        freqA = hz
        pendingFreq = hz
        freqSetAt = Date()
        guard !freqSending else { return }
        freqSending = true
        Task {
            while let f = pendingFreq, state == .connected {
                pendingFreq = nil
                _ = try? await client.transact("FA" + Param.pad(f, 9) + ";", expect: nil, timeoutMs: 100)
                freqSetAt = Date()
            }
            pendingFreq = nil
            freqSending = false
        }
    }

    /// Wählt die Betriebsart.
    /// - Parameter code: CAT-Code, siehe ``Catalog/modes``.
    func setMode(_ code: String) {
        mode = code
        sendSimple("MD0" + code + ";")
    }

    /// Wechselt per Bandtaste das Band (`BS`-Befehl).
    /// - Parameter code: Bandcode des Geräts (0 = 160 m … 10 = 6 m, 11 = GEN, 12 = MW).
    func selectBand(_ code: Int) {
        sendSimple("BS" + Param.pad(code, 2) + ";")
    }

    /// Sendet einen Befehl ohne Antwort („Fire and forget“), z. B. `AB;`.
    func sendSimple(_ cmd: String) {
        guard state == .connected, !sweepRunning else { return }
        Task {
            _ = try? await client.transact(cmd, expect: nil, timeoutMs: 100)
        }
    }

    /// Schaltet die Sendefreigabe; das Zurücknehmen beendet ein laufendes CAT-Senden.
    func setAllowTX(_ on: Bool) {
        allowTX = on
        if !on && catTX { setPTT(false) }
    }

    /// Schaltet Senden per CAT ein oder aus (`TX1;`/`TX0;`). Erfordert die Sendefreigabe.
    func setPTT(_ on: Bool) {
        guard state == .connected, !sweepRunning else { return }
        if on && !allowTX { return }
        catTX = on
        catTXStart = on ? Date() : nil
        sendSimple(on ? "TX1;" : "TX0;")
    }

    /// Startet die Abstimmung des Antennentuners (`AC002;`). Erfordert die Sendefreigabe, da der Sender kurz aktiv wird.
    func tune() {
        guard state == .connected, allowTX else { return }
        sendSimple("AC002;")
    }

    /// Sendet einen Rohbefehl aus dem Protokoll-Reiter.
    ///
    /// Großschreibung und das abschließende `;` werden ergänzt. `EX1701` (RESET) wird grundsätzlich blockiert,
    /// sendende Befehle nur mit Sendefreigabe.
    func sendRaw(_ text: String) {
        var cmd = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !cmd.isEmpty, state == .connected else { return }
        if !cmd.hasSuffix(";") { cmd += ";" }
        if cmd.hasPrefix("EX1701") {
            alertMessage = "EX1701 (RESET) wird aus Sicherheitsgründen nicht gesendet."
            return
        }
        let risky = ["TX1;", "TX2;", "MX1;", "AC002;"]
        if risky.contains(cmd) && !allowTX {
            alertMessage = "Sendefunktionen sind gesperrt (Live-Tab → „Sendefunktionen freigeben“)."
            return
        }
        Task {
            do {
                try await client.transact(cmd, expect: nil, timeoutMs: 150)
            } catch {
                appendLog(.info, error.localizedDescription)
            }
        }
    }

    // MARK: - Sicherung

    /// Speichert alle gelesenen Werte als JSON-Sicherung. Vorher sollte „Alle lesen“ ausgeführt werden.
    func exportBackup() {
        if values.count < Catalog.all.count / 2 {
            alertMessage = "Es sind erst \(values.count) von \(Catalog.all.count) Parametern gelesen. Bitte zuerst „Alle lesen“ ausführen."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "FT-891-Backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let backup = Backup(radio: "FT-891", created: ISO8601DateFormatter().string(from: Date()), values: values)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(backup).write(to: url)
            alertMessage = "\(values.count) Werte gesichert."
        } catch {
            alertMessage = "Sichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Lädt eine JSON-Sicherung und schreibt abweichende Werte zurück zum Gerät.
    func importBackup() {
        guard state == .connected else {
            alertMessage = "Zum Zurückschreiben muss das Funkgerät verbunden sein."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let backup = try JSONDecoder().decode(Backup.self, from: data)
            restore(backup.values)
        } catch {
            alertMessage = "Laden fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Schreibt die abweichenden Werte einer Sicherung zurück.
    ///
    /// Ausgenommen sind schreibgeschützte Parameter, CAT RATE (würde die Verbindung trennen), Auto-Information und
    /// sendeauslösende Werte. Danach werden die betroffenen Parameter zur Kontrolle neu gelesen.
    /// - Parameter saved: Rohwerte je Parameter-ID.
    private func restore(_ saved: [String: String]) {
        guard state == .connected, !bulkBusy else { return }
        let skip: Set<String> = ["EX0506", "AI"]
        var todo: [(Param, String)] = []
        for entry in saved {
            guard let p = Catalog.byID[entry.key], !p.readOnly, !skip.contains(entry.key),
                  !p.txValues.contains(entry.value), values[entry.key] != entry.value else { continue }
            todo.append((p, entry.value))
        }
        todo.sort { $0.0.id < $1.0.id }
        if todo.isEmpty {
            alertMessage = "Keine Unterschiede zur Sicherung – nichts zu schreiben."
            return
        }
        bulkBusy = true
        progress = 0
        Task {
            var ok = 0
            var failed = 0
            for (i, item) in todo.enumerated() {
                do {
                    try await client.transact(setCommand(item.0, raw: item.1), expect: nil, timeoutMs: 200)
                    ok += 1
                } catch {
                    failed += 1
                    errors[item.0.id] = error.localizedDescription
                }
                progress = Double(i + 1) / Double(todo.count)
            }
            bulkBusy = false
            alertMessage = "Zurückgeschrieben: \(ok), fehlgeschlagen: \(failed). Die Werte werden jetzt zur Kontrolle neu gelesen."
            readAll(todo.map { $0.0 })
        }
    }
}
