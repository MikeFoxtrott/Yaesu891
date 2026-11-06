# Mike Foxtrott – FT-891 Control (macOS)

SwiftUI-App zur CAT-Steuerung des Yaesu FT-891. Keine externen Abhängigkeiten, reines Swift/POSIX.
Grundlage: offizielles "FT-891 CAT Operation Reference Book".

## Starten
Voraussetzung: macOS 14+, Xcode (oder Command Line Tools).

Variante A – Xcode: `Package.swift` doppelklicken, Scheme "FT891Control", Ziel "My Mac", Run.
Variante B – fertige App: im Terminal `./build_app.sh` → `Mike Foxtrott.app` (ad-hoc signiert, mit Icon aus `Icon/AppIcon.icns`).
(Beim ersten Start ggf. Rechtsklick → Öffnen.)

## Verbinden
Das FT-891 zeigt zwei serielle Ports (Silicon Labs CP210x); CAT liegt am "Enhanced"-Port.
"Auto-Erkennung" probiert alle Ports/Baudraten mit `ID;` (Antwort `ID0650;`). Manuell: Port + Baudrate
wie im Gerät unter Menü 05-06 CAT RATE (Werkseinstellung 4800). Kein Port sichtbar → CP210x-Treiber installieren.

## Funktionen
- Live: Frequenz VFO A/B, Betriebsart, Bandtasten, Schrittknöpfe, S-Meter, beim Senden PO/SWR/ALC/COMP/ID
  mit SWR-Spitzenwert, Schnellzugriff (AF, RF, Squelch, Leistung, Mic, NB, NR, AGC, IF-Shift …).
- Einstellungen: alle Standard-CAT-Befehle (Lesen, Ändern, Zurücklesen zur Kontrolle).
- Menü (EX): alle EX-Menüs 01-01 … 16-23 sowie Versionen 18-01 … 18-03 mit Menünummern wie am Gerät.
  EX1701 (RESET) ist bewusst NICHT enthalten und wird auch im Rohbefehl-Feld blockiert.
- Sichern/Laden aller Werte als JSON. CAT RATE (05-06) wird beim Zurückschreiben übersprungen.
- Protokoll mit Rohbefehl-Eingabe (z. B. `FA;`).

## Sicherheit beim Senden
Senden (PTT, Tuner-Abstimmung, MOX) ist gesperrt, bis im Live-Tab "Sendefunktionen freigeben" aktiv ist.
CAT-PTT endet automatisch nach 2 Minuten und beim Beenden der App.
Die Auto-Erkennung öffnet kurz auch den zweiten Port. Ist dort PTT per RTS/DTR eingestellt
(Menü "PTT SELECT" ≠ DAKY), lieber manuell verbinden.

## Stand / Grenzen
- Nicht auf echter Hardware getestet und nicht mit Xcode kompiliert (Entwicklung ohne Mac).
  Erwarte ggf. kleine Compilerfehler; Meldung schicken, dann wird korrigiert.
- SWR/S-Meter-Umrechnung sind Näherungen des Rohwerts 0–255; PO/ALC/COMP/ID werden als Rohwert gezeigt.
- Handbuchausgaben unterscheiden sich bei RG (0–30 vs. 0–100), IS und SH (mit/ohne ON/OFF-Feld).
  Die App erkennt das Format an der Antwortlänge; RG-Bereich richtet sich nach der neueren Ausgabe.

## Logo und Icon
„Mike Foxtrott“ steht für MF. Das Logo zeigt eine kleine Sendeantenne (Fußplatte, Stab mit Verlängerungsspule,
leuchtende Spitze), von der Funkwellen nach beiden Seiten ausgehen; daneben der Schriftzug.
Dateien in `Icon/`: `AppIcon.icns` (wird eingebaut), `AppIcon.png`/`.svg`, `Logo.png`/`.svg`.
Neu erzeugen: `python3 Icon/make_icon.py` (braucht Python mit Pillow und Playwright/Chromium).

## SWR-Sweep (ab y891mac_swr, 04.11.2026)

Reiter „SWR-Sweep“: misst das SWR über einen wählbaren Bereich (z. B. 7080–7140 kHz, Schritt 5 kHz).
Pro Punkt: FA setzen → TX1 → 250 ms warten → RM6 (SWR) und RM5 (PO) je 3× lesen → TX0.
Leistung (5/10 W) und Träger-Betriebsart (FM/AM/RTTY) wählbar; Frequenz, Modus und Leistung werden danach
wiederhergestellt. Abbruch bei SWR über der Grenze, ohne gemessene Leistung, per Stopp/Esc oder wenn die
Sendefreigabe zurückgenommen wird. Nur innerhalb eines Amateurfunkbands, höchstens 101 Punkte.
Wiederholung im Abstand von 1–120 min; gleiche Bereiche erscheinen als Wasserfall.
Verlauf: ~/Documents/Mike Foxtrott/swr-sweeps.json, Export einzelner Durchläufe als CSV.
