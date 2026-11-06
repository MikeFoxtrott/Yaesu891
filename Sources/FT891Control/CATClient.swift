import Foundation

/// Fehler bei der CAT-Kommunikation.
enum CATError: LocalizedError {
    /// Keine offene Schnittstelle.
    case notConnected
    /// Keine Antwort innerhalb der Wartezeit; enthält den gesendeten Befehl.
    case timeout(String)
    /// Das Gerät hat den Befehl mit `?;` (oder `E;`/`O;`) abgelehnt; enthält den Befehl.
    case rejected(String)
    /// Schreibfehler der Schnittstelle.
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Nicht verbunden"
        case .timeout(let c): return "Keine Antwort auf \(c)"
        case .rejected(let c): return "Vom Funkgerät abgelehnt (?;): \(c)"
        case .io(let m): return m
        }
    }
}

/// Richtung eines Protokolleintrags; der Rohwert ist das angezeigte Symbol.
enum LogDirection: String {
    /// An das Gerät gesendet.
    case tx = "→"
    /// Vom Gerät empfangen.
    case rx = "←"
    /// Information der App.
    case info = "•"
}

/// Serialisiert alle Befehle: immer genau ein Befehl unterwegs, Antworten werden über das
/// Präfix (z. B. "FA", "EX0506") zugeordnet. Befehle ohne Antwort (Set) gelten nach einer
/// kurzen Wartezeit als erledigt; kommt in dieser Zeit "?;", wird der Befehl als abgelehnt gemeldet.
@MainActor
final class CATClient {
    let port = SerialPort()

    /// Frames, die zu keiner laufenden Abfrage gehören (z. B. Auto-Information).
    var onFrame: ((String) -> Void)?
    var onLog: ((LogDirection, String) -> Void)?
    var onHangup: (() -> Void)?

    /// Ein wartender oder laufender Befehl samt Fortsetzung, über die das Ergebnis zurückgegeben wird.
    private struct Request {
        let id: Int
        let command: String
        let expect: String?
        let timeoutMs: Int
        let quiet: Bool
        let continuation: CheckedContinuation<String?, Error>
    }

    /// Wartende Befehle in Sendereihenfolge.
    private var queue: [Request] = []
    /// Der Befehl, für den gerade auf eine Antwort gewartet wird.
    private var current: Request?
    /// Laufende Nummer, um Zeitüberschreitungen dem richtigen Befehl zuzuordnen.
    private var nextID = 0
    /// Empfangspuffer; Frames enden jeweils mit `;`.
    private var rx: [UInt8] = []
    /// Wartezeit nach Set-Befehlen, in der eine Ablehnung eintreffen kann.
    private let settleMs = 60

    /// Verbindet die Rückrufe der Schnittstelle mit dem Client.
    init() {
        port.onData = { [weak self] bytes in
            self?.receive(bytes)
        }
        port.onHangup = { [weak self] in
            self?.handleHangup()
        }
    }

    /// Ob die Schnittstelle geöffnet ist.
    var isOpen: Bool { port.isOpen }

    /// Öffnet die Schnittstelle; noch wartende Befehle werden mit ``CATError/notConnected`` abgebrochen.
    /// - Throws: ``SerialError``.
    func open(path: String, baud: Int, twoStop: Bool) throws {
        failAll(with: CATError.notConnected)
        rx.removeAll()
        try port.open(path: path, baud: baud, twoStopBits: twoStop)
    }

    /// Schließt die Schnittstelle und bricht alle wartenden Befehle ab.
    func close() {
        port.close()
        rx.removeAll()
        failAll(with: CATError.notConnected)
    }

    /// Sendet einen Befehl und wartet auf die Antwort.
    ///
    /// Der Aufruf reiht sich in die Warteschlange ein; es ist immer nur ein Befehl gleichzeitig unterwegs.
    /// - Parameters:
    ///   - command: Kompletter Befehl inklusive abschließendem `;`.
    ///   - expect: Präfix der erwarteten Antwort (z. B. `"FA"`); `nil` bei reinen Set-Befehlen.
    ///   - timeoutMs: Wartezeit auf die Antwort; bei Set-Befehlen die Zeit, in der eine Ablehnung (`?;`) abgewartet wird.
    ///   - quiet: Frames nicht ins Protokoll schreiben (für das häufige Polling).
    /// - Returns: Die Antwort oder `nil` bei Set-Befehlen ohne Fehlermeldung.
    /// - Throws: ``CATError``.
    @discardableResult
    func transact(_ command: String, expect: String? = nil, timeoutMs: Int = 500, quiet: Bool = false) async throws -> String? {
        guard port.isOpen else { throw CATError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            self.nextID += 1
            self.queue.append(Request(id: self.nextID, command: command, expect: expect,
                                      timeoutMs: timeoutMs, quiet: quiet, continuation: cont))
            self.pump()
        }
    }

    // MARK: - Intern

    /// Beendet den laufenden und alle wartenden Befehle mit einem Fehler.
    private func failAll(with error: Error) {
        let all = [current].compactMap { $0 } + queue
        current = nil
        queue.removeAll()
        for r in all {
            r.continuation.resume(throwing: error)
        }
    }

    /// Startet den nächsten Befehl, falls keiner läuft, und legt den Zeitgeber für seine Antwort an.
    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let req = queue.removeFirst()
        current = req
        do {
            try port.write(req.command)
            if !req.quiet { onLog?(.tx, req.command) }
        } catch {
            current = nil
            req.continuation.resume(throwing: CATError.io(error.localizedDescription))
            pump()
            return
        }
        let id = req.id
        let delay = req.expect == nil ? settleMs : req.timeoutMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timedOut(id)
            }
        }
    }

    /// Zeitgeber abgelaufen: Set-Befehle gelten jetzt als erledigt, Abfragen als fehlgeschlagen.
    /// - Parameter id: Nummer des Befehls; veraltete Zeitgeber werden ignoriert.
    private func timedOut(_ id: Int) {
        guard let req = current, req.id == id else { return }
        current = nil
        if req.expect == nil {
            req.continuation.resume(returning: nil)
        } else {
            req.continuation.resume(throwing: CATError.timeout(req.command))
        }
        pump()
    }

    /// Sammelt empfangene Bytes und zerlegt sie in Frames (Trennzeichen `;`).
    private func receive(_ bytes: [UInt8]) {
        rx.append(contentsOf: bytes)
        let terminator = UInt8(ascii: ";")
        while let idx = rx.firstIndex(of: terminator) {
            let frameBytes = Array(rx[0...idx])
            rx.removeSubrange(0...idx)
            let frame = String(decoding: frameBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            handle(frame)
        }
        if rx.count > 4096 { rx.removeAll() }
    }

    /// Ordnet einen Frame zu: Fehlerantwort → laufender Befehl scheitert, passendes Präfix → Antwort auf den
    /// laufenden Befehl, alles andere → ``onFrame`` (z. B. Auto-Information).
    private func handle(_ frame: String) {
        if !(current?.quiet ?? false) { onLog?(.rx, frame) }

        if frame == "?;" || frame == "E;" || frame == "O;" {
            if let req = current {
                current = nil
                req.continuation.resume(throwing: CATError.rejected(req.command))
                pump()
            }
            return
        }

        if let req = current, let expect = req.expect, frame.hasPrefix(expect) {
            current = nil
            req.continuation.resume(returning: frame)
            pump()
            return
        }

        onFrame?(frame)
    }

    /// Die Schnittstelle ist verschwunden (Kabel gezogen): alles abbrechen und ``onHangup`` melden.
    private func handleHangup() {
        failAll(with: CATError.notConnected)
        onHangup?()
    }
}
