import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

// MARK: - Daten

/// Ein Messpunkt des SWR-Sweeps: Frequenz und die beim kurzen Senden gelesenen Rohwerte.
struct SweepPoint: Codable, Hashable, Identifiable {
    /// Frequenz in Hz.
    let hz: Int
    /// SWR-Rohwert (`RM6`, 0–255), Median aus drei Ablesungen.
    let swrRaw: Int
    /// Leistungs-Rohwert (`RM5`, 0–255), höchste Ablesung.
    let poRaw: Int

    var id: Int { hz }
    /// SWR als Verhältnis (Näherung aus dem Rohwert, siehe ``Meter/swr(_:)``).
    var swr: Double { Meter.swr(swrRaw) }
    /// Frequenz in kHz (für die Diagrammachse).
    var kHz: Double { Double(hz) / 1000 }
}

/// Ein kompletter Sweep-Durchlauf.
struct SweepRun: Codable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    var startHz: Int
    var stopHz: Int
    var stepHz: Int
    var powerW: Int
    var points: [SweepPoint]
    /// Abbruchgrund; `nil` = vollständig gemessen.
    var note: String?

    /// Schlüssel für gleiche Messbereiche (nur diese stehen gemeinsam im Wasserfall).
    var rangeKey: String { "\(startHz)-\(stopHz)-\(stepHz)" }

    /// Punkt mit dem kleinsten SWR.
    var best: SweepPoint? { points.min { $0.swr < $1.swr } }

    /// Zusammenhängender Bereich um das Minimum, in dem das SWR höchstens `limit` beträgt (in kHz, linear interpoliert).
    /// - Returns: Grenzen und ob der Bereich am Rand des Messbereichs endet (dann ist er in Wirklichkeit evtl. breiter).
    func span(below limit: Double) -> (lo: Double, hi: Double, openLo: Bool, openHi: Bool)? {
        let pts = points
        guard let iMin = pts.indices.min(by: { pts[$0].swr < pts[$1].swr }), pts[iMin].swr <= limit else { return nil }
        var l = iMin
        while l > 0 && pts[l - 1].swr <= limit { l -= 1 }
        var h = iMin
        while h < pts.count - 1 && pts[h + 1].swr <= limit { h += 1 }
        /// Schnittpunkt der Verbindungslinie a→b mit `limit` (a liegt darüber, b darunter).
        func cross(_ a: SweepPoint, _ b: SweepPoint) -> Double {
            let d = b.swr - a.swr
            if d == 0 { return b.kHz }
            let f = (limit - a.swr) / d
            return a.kHz + f * (b.kHz - a.kHz)
        }
        let lo = l > 0 ? cross(pts[l - 1], pts[l]) : pts[l].kHz
        let hi = h < pts.count - 1 ? cross(pts[h + 1], pts[h]) : pts[h].kHz
        return (lo, hi, l == 0, h == pts.count - 1)
    }
}

/// Formatiert kHz nach Systemsprache, z. B. `7.088,5`.
func fmtKHz(_ v: Double) -> String {
    v.formatted(.number.precision(.fractionLength(0...1)))
}

// MARK: - Steuerung

/// Führt SWR-Sweeps über einen Frequenzbereich durch.
///
/// Ablauf je Messpunkt: Frequenz setzen (`FA`), kurz senden (`TX1`), SWR (`RM6`) und Leistung (`RM5`) dreimal lesen,
/// Senden beenden (`TX0`). Vorher werden Frequenz, Betriebsart und Leistung gemerkt und danach wiederhergestellt.
///
/// - Important: Der FT-891 misst SWR nur beim Senden. Der Sweep läuft daher nur mit ``Radio/allowTX``, nur
///   innerhalb eines Amateurfunkbands und bricht ab, sobald das SWR die Abbruchgrenze überschreitet.
@MainActor
@Observable
final class SweepController {
    @ObservationIgnored private let radio: Radio

    // Einstellungen
    var startKHz = 7080.0
    var stopKHz = 7140.0
    var stepKHz = 5.0
    var powerW = 5
    /// Betriebsart, in der beim Senden ein Träger entsteht (CAT-Code).
    var carrierMode = "4"
    var abortSWR = 3.0
    var repeatOn = false
    var repeatMinutes = 10
    /// Bestätigung „Bereich frei, Antenne/Dummy Load dran“; gilt nur bis zum Beenden der App.
    var confirmed = false

    static let stepChoices: [Double] = [1, 2, 5, 10, 25, 50]
    static let powerChoices = [5, 10]
    static let abortChoices: [Double] = [2, 3, 5]
    static let carrierModes: [Choice] = [
        Choice(code: "4", label: "FM"), Choice(code: "5", label: "AM"), Choice(code: "6", label: "RTTY-LSB")
    ]
    /// Höchstzahl der Messpunkte je Durchlauf.
    static let maxPoints = 101

    // Zustand
    private(set) var running = false
    /// Der gerade laufende Durchlauf (wächst Punkt für Punkt).
    private(set) var liveRun: SweepRun?
    private(set) var currentHz: Int?
    private(set) var progress = 0.0
    private(set) var status = ""
    private(set) var nextRunAt: Date?
    /// Gespeicherte Durchläufe, älteste zuerst.
    var runs: [SweepRun] = []
    /// Angezeigter Durchlauf; `nil` = der neueste.
    var selectedID: UUID?

    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(radio: Radio) {
        self.radio = radio
        loadSettings()
        load()
    }

    // MARK: Abgeleitete Werte

    var startHz: Int { Int((startKHz * 1000).rounded()) }
    var stopHz: Int { Int((stopKHz * 1000).rounded()) }
    var stepHz: Int { Int((stepKHz * 1000).rounded()) }

    var pointCount: Int {
        guard stepHz > 0, stopHz > startHz else { return 0 }
        return (stopHz - startHz) / stepHz + 1
    }

    /// Geschätzte Dauer eines Durchlaufs in Sekunden.
    var estimatedSeconds: Int { Int((Double(pointCount) * 0.75).rounded()) }

    /// Band, in dem der Startwert liegt.
    var presetBand: String? { BandPlan.band(for: startHz)?.name }

    /// Grund, warum gerade nicht gestartet werden kann; `nil` = Start möglich.
    var validationMessage: String? {
        if !radio.isConnected { return "Nicht verbunden." }
        if stopHz <= startHz { return "Stopp muss über Start liegen." }
        guard let b = BandPlan.band(for: startHz), stopHz <= b.highHz else {
            return "Start und Stopp müssen im selben Amateurfunkband liegen."
        }
        if pointCount > Self.maxPoints {
            return "\(pointCount) Messpunkte sind zu viele (höchstens \(Self.maxPoints)). Schrittweite erhöhen."
        }
        if !radio.allowTX { return "Sendefunktionen sind gesperrt: Live-Tab → „Sendefunktionen freigeben“." }
        if !confirmed { return "Bitte bestätigen, dass der Bereich frei und eine Antenne oder Dummy Load angeschlossen ist." }
        return nil
    }

    /// Durchläufe mit demselben Messbereich wie `run` (für den Wasserfall), älteste zuerst.
    func compatibleRuns(_ run: SweepRun) -> [SweepRun] {
        runs.filter { $0.rangeKey == run.rangeKey }
    }

    // MARK: Voreinstellungen

    /// Füllt Bereich und Schrittweite für ein Band vor.
    func applyPreset(_ band: HamBand) {
        let steps: [String: Double] = [
            "160m": 5, "80m": 10, "60m": 1, "40m": 5, "30m": 2, "20m": 10,
            "17m": 5, "15m": 10, "12m": 5, "10m": 25, "6m": 50
        ]
        startKHz = Double(band.lowHz) / 1000
        stopKHz = Double(band.highHz) / 1000
        stepKHz = steps[band.name] ?? 10
        while pointCount > Self.maxPoints, let next = Self.stepChoices.first(where: { $0 > stepKHz }) {
            stepKHz = next
        }
    }

    // MARK: Start / Stopp

    func start() {
        guard !running, validationMessage == nil else { return }
        running = true
        stopRequested = false
        saveSettings()
        task = Task { await loop() }
    }

    /// Bricht ab; ein laufendes Senden wird sofort beendet.
    func stop() {
        stopRequested = true
        status = "Wird gestoppt …"
        if radio.catTX {
            try? radio.client.port.write("TX0;")
        }
    }

    private func loop() async {
        while true {
            nextRunAt = nil
            let run = await performSweep()
            if let run, !run.points.isEmpty {
                runs.append(run)
                if runs.count > 300 { runs.removeFirst(runs.count - 300) }
                selectedID = nil
                save()
            }
            liveRun = nil
            if stopRequested || !repeatOn || run?.note != nil { break }
            let until = Date().addingTimeInterval(Double(repeatMinutes) * 60)
            nextRunAt = until
            status = "Nächster Durchlauf um \(until.formatted(date: .omitted, time: .shortened))"
            while Date() < until && !stopRequested {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if stopRequested { break }
            if let msg = validationMessage {
                status = "Wiederholung beendet: \(msg)"
                break
            }
        }
        if stopRequested { status = "Gestoppt." }
        nextRunAt = nil
        currentHz = nil
        running = false
    }

    /// Ein Durchlauf über den eingestellten Bereich.
    private func performSweep() async -> SweepRun? {
        let c = radio.client
        let total = pointCount
        var run = SweepRun(date: Date(), startHz: startHz, stopHz: stopHz, stepHz: stepHz,
                           powerW: powerW, points: [], note: nil)
        liveRun = run
        progress = 0
        radio.sweepRunning = true
        // Laufenden Poll-Durchlauf ausklingen lassen.
        try? await Task.sleep(nanoseconds: 200_000_000)

        var savedFreq: String?
        var savedMode: String?
        var savedPC: String?
        do {
            savedFreq = try await c.transact("FA;", expect: "FA", timeoutMs: 500)
            savedMode = try await c.transact("MD0;", expect: "MD0", timeoutMs: 500)
            savedPC = try await c.transact("PC;", expect: "PC", timeoutMs: 500)
            try await c.transact("MD0" + carrierMode + ";", timeoutMs: 120)
            try await c.transact("PC" + Param.pad(powerW, 3) + ";", timeoutMs: 120)

            var hz = run.startHz
            var n = 0
            while hz <= run.stopHz {
                if stopRequested { run.note = "Vom Benutzer gestoppt."; break }
                if !radio.allowTX { run.note = "Sendefreigabe wurde zurückgenommen."; break }
                currentHz = hz
                status = "Messe \(fmtKHz(Double(hz) / 1000)) kHz …"
                try await c.transact("FA" + Param.pad(hz, 9) + ";", timeoutMs: 60)
                radio.freqA = hz
                try await Task.sleep(nanoseconds: 60_000_000)
                let p = try await measure(at: hz)
                run.points.append(p)
                liveRun = run
                n += 1
                progress = Double(n) / Double(max(total, 1))
                if p.poRaw < 8 {
                    run.note = "Kein Sendesignal gemessen. Andere Träger-Betriebsart wählen oder Gerät prüfen."
                    break
                }
                if p.swr > abortSWR {
                    run.note = String(format: "Abgebrochen: SWR %.1f bei ", p.swr) + fmtKHz(p.kHz) + " kHz."
                    break
                }
                hz += run.stepHz
            }
        } catch CATError.notConnected {
            run.note = "Verbindung unterbrochen."
        } catch {
            run.note = error.localizedDescription
        }
        await keyOff()

        // Ausgangszustand wiederherstellen (Antworten haben dasselbe Format wie die Set-Befehle).
        for saved in [savedPC, savedMode, savedFreq] {
            if let s = saved { _ = try? await c.transact(s, timeoutMs: 100) }
        }
        currentHz = nil
        radio.sweepRunning = false
        progress = 1
        status = run.note ?? "Fertig: \(run.points.count) Messpunkte."
        return run
    }

    /// Sendet kurz und liest SWR und Leistung.
    private func measure(at hz: Int) async throws -> SweepPoint {
        let c = radio.client
        radio.catTX = true
        radio.txState = 1
        do {
            try await c.transact("TX1;", timeoutMs: 60)
            try await Task.sleep(nanoseconds: 250_000_000)
            var swr: [Int] = []
            var po = 0
            for _ in 0..<3 {
                if let v = try await meter("RM6;") { swr.append(v) }
                if let v = try await meter("RM5;") { po = max(po, v) }
            }
            await keyOff()
            swr.sort()
            let median = swr.isEmpty ? 255 : swr[swr.count / 2]
            return SweepPoint(hz: hz, swrRaw: median, poRaw: po)
        } catch {
            await keyOff()
            throw error
        }
    }

    /// Beendet das Senden; notfalls direkt über die Schnittstelle.
    private func keyOff() async {
        guard radio.catTX else { return }
        do {
            try await radio.client.transact("TX0;", timeoutMs: 60)
        } catch {
            try? radio.client.port.write("TX0;")
        }
        radio.catTX = false
        radio.txState = 0
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    /// Liest ein Messinstrument, z. B. `RM6;`.
    private func meter(_ cmd: String) async throws -> Int? {
        let expect = String(cmd.dropLast())
        guard let f = try await radio.client.transact(cmd, expect: expect, timeoutMs: 400, quiet: true) else { return nil }
        return Int(f.dropFirst(3).dropLast())
    }

    // MARK: Speichern

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Mike Foxtrott/swr-sweeps.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        runs = (try? dec.decode([SweepRun].self, from: data)) ?? []
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try enc.encode(runs).write(to: Self.fileURL, options: .atomic)
        } catch {
            radio.alertMessage = "Sweep-Verlauf konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    func clearHistory() {
        runs.removeAll()
        selectedID = nil
        save()
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        if d.object(forKey: "sweep.start") != nil {
            startKHz = d.double(forKey: "sweep.start")
            stopKHz = d.double(forKey: "sweep.stop")
            stepKHz = d.double(forKey: "sweep.step")
        }
        let pw = d.integer(forKey: "sweep.power")
        if Self.powerChoices.contains(pw) { powerW = pw }
        if let m = d.string(forKey: "sweep.mode"), Self.carrierModes.contains(where: { $0.code == m }) { carrierMode = m }
        let a = d.double(forKey: "sweep.abort")
        if Self.abortChoices.contains(a) { abortSWR = a }
        let r = d.integer(forKey: "sweep.repeat")
        if r > 0 { repeatMinutes = r }
        if !Self.stepChoices.contains(stepKHz) { stepKHz = 5 }
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(startKHz, forKey: "sweep.start")
        d.set(stopKHz, forKey: "sweep.stop")
        d.set(stepKHz, forKey: "sweep.step")
        d.set(powerW, forKey: "sweep.power")
        d.set(carrierMode, forKey: "sweep.mode")
        d.set(abortSWR, forKey: "sweep.abort")
        d.set(repeatMinutes, forKey: "sweep.repeat")
    }

    /// Exportiert einen Durchlauf als CSV (Semikolon, Dezimalkomma – passt für Excel/Numbers auf Deutsch).
    func exportCSV(_ run: SweepRun) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        panel.nameFieldStringValue = "SWR_\(run.startHz / 1000)-\(run.stopHz / 1000)kHz_\(df.string(from: run.date)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["Frequenz (kHz);SWR;SWR roh;PO roh"]
        for p in run.points {
            let f = String(format: "%.1f", p.kHz).replacingOccurrences(of: ".", with: ",")
            let s = String(format: "%.2f", p.swr).replacingOccurrences(of: ".", with: ",")
            lines.append("\(f);\(s);\(p.swrRaw);\(p.poRaw)")
        }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            radio.alertMessage = "CSV konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }
}
