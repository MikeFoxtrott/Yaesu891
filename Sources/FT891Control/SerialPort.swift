import Foundation
import Darwin

/// Fehler der seriellen Schnittstelle; die Meldungen sind für Benutzer formuliert.
enum SerialError: LocalizedError {
    case open(String)
    case config(String)
    case write(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): return "Port konnte nicht geöffnet werden: \(m)"
        case .config(let m): return "Port-Konfiguration fehlgeschlagen: \(m)"
        case .write(let m): return "Schreibfehler: \(m)"
        }
    }
}

/// Dünner POSIX-Wrapper. Alles läuft auf dem Main-Thread (Read-Source auf der Main-Queue),
/// dadurch braucht der Rest der App keine Locks.
@MainActor
final class SerialPort {
    /// Dateideskriptor; `-1` = geschlossen.
    private var fd: Int32 = -1
    /// Lesequelle, die bei eintreffenden Daten `drain()` aufruft. Ihr Cancel-Handler schließt den Deskriptor.
    private var source: DispatchSourceRead?
    /// Pfad des geöffneten Ports.
    private(set) var path = ""

    /// Wird mit jedem Block empfangener Bytes aufgerufen.
    var onData: (([UInt8]) -> Void)?
    /// Wird aufgerufen, wenn das Gerät verschwindet (USB-Kabel gezogen).
    var onHangup: (() -> Void)?

    /// Ob der Port geöffnet ist.
    var isOpen: Bool { fd >= 0 }

    /// Listet die Ausgangsports (`/dev/cu.*`) ohne Bluetooth, WLAN und Debug-Konsole.
    /// - Returns: Sortierte Gerätepfade.
    static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") }
            .filter { !$0.localizedCaseInsensitiveContains("Bluetooth") && !$0.contains("wlan") && !$0.contains("debug") }
            .sorted()
            .map { "/dev/" + $0 }
    }

    /// Öffnet den Port nicht blockierend und exklusiv (`flock`) mit 8N1 und ohne Handshake.
    /// - Parameters:
    ///   - path: Gerätedatei.
    ///   - baud: Baudrate.
    ///   - twoStopBits: Zwei statt einem Stoppbit.
    /// - Throws: ``SerialError``, z. B. wenn ein anderes Programm den Port belegt.
    func open(path: String, baud: Int, twoStopBits: Bool) throws {
        close()
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if f < 0 {
            throw SerialError.open(String(cString: strerror(errno)))
        }
        if flock(f, LOCK_EX | LOCK_NB) != 0 {
            Darwin.close(f)
            throw SerialError.open("Der Port wird bereits von einem anderen Programm verwendet.")
        }
        do {
            try SerialPort.configure(f, baud: baud, twoStopBits: twoStopBits)
        } catch {
            _ = flock(f, LOCK_UN)
            Darwin.close(f)
            throw error
        }
        fd = f
        self.path = path
        startReading(f)
    }

    /// Stellt Baudrate und Stoppbits im laufenden Betrieb um (nötig, wenn CAT RATE am Gerät geändert wird).
    func setBaud(_ baud: Int, twoStopBits: Bool) throws {
        guard fd >= 0 else { return }
        try SerialPort.configure(fd, baud: baud, twoStopBits: twoStopBits)
    }

    /// Schließt den Port; der Deskriptor wird über den Cancel-Handler der Lesequelle freigegeben.
    func close() {
        guard fd >= 0 else { return }
        let f = fd
        fd = -1
        _ = flock(f, LOCK_UN)
        if let s = source {
            source = nil
            s.cancel() // der Cancel-Handler schließt den Descriptor
        } else {
            Darwin.close(f)
        }
    }

    /// Schreibt Text vollständig auf den Port.
    ///
    /// Der Port ist nicht blockierend: Bei vollem Puffer (`EAGAIN`) wird bis zu 200-mal kurz gewartet.
    /// - Throws: ``SerialError/write(_:)``.
    func write(_ text: String) throws {
        guard fd >= 0 else { throw SerialError.write("Port nicht geöffnet") }
        let f = fd
        let bytes = Array(text.utf8)
        var offset = 0
        var spins = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                Darwin.write(f, raw.baseAddress! + offset, bytes.count - offset)
            }
            if n > 0 {
                offset += n
                spins = 0
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) && spins < 200 {
                spins += 1
                usleep(2000)
            } else {
                throw SerialError.write(String(cString: strerror(errno)))
            }
        }
    }

    // MARK: - Intern

    /// Setzt die Terminal-Attribute: Rohmodus, 8 Datenbits, keine Parität, kein Hardware-Handshake, gewünschte Baudrate.
    private static func configure(_ f: Int32, baud: Int, twoStopBits: Bool) throws {
        var t = termios()
        if tcgetattr(f, &t) != 0 {
            throw SerialError.config(String(cString: strerror(errno)))
        }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(PARENB | CSIZE)
        t.c_cflag |= tcflag_t(CS8)
        t.c_cflag &= ~tcflag_t(0x00030000) // kein Hardware-Handshake (CCTS_OFLOW | CRTS_IFLOW)
        if twoStopBits {
            t.c_cflag |= tcflag_t(CSTOPB)
        } else {
            t.c_cflag &= ~tcflag_t(CSTOPB)
        }
        if cfsetspeed(&t, speed_t(baud)) != 0 {
            throw SerialError.config("Baudrate \(baud) wird nicht unterstützt")
        }
        if tcsetattr(f, TCSANOW, &t) != 0 {
            throw SerialError.config(String(cString: strerror(errno)))
        }
        tcflush(f, TCIOFLUSH)
    }

    /// Startet die Lesequelle auf der Main-Queue.
    private func startReading(_ f: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.drain()
            }
        }
        src.setCancelHandler {
            Darwin.close(f)
        }
        source = src
        src.resume()
    }

    /// Aufeinanderfolgende leere Lesevorgänge – viele davon bedeuten, dass das Gerät weg ist.
    private var zeroReads = 0

    /// Liest alle verfügbaren Bytes und meldet sie; erkennt getrennte Geräte an den Fehlercodes.
    private func drain() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while fd >= 0 {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                zeroReads = 0
                onData?(Array(buffer[0..<n]))
                if n < buffer.count { break }
            } else if n == 0 {
                zeroReads += 1
                if zeroReads > 50 { hangup() }
                break
            } else {
                let e = errno
                if e == EIO || e == ENXIO || e == ENODEV || e == EBADF { hangup() }
                break
            }
        }
    }

    /// Schließt den Port und meldet das Verschwinden des Geräts.
    private func hangup() {
        let callback = onHangup
        close()
        callback?()
    }
}
