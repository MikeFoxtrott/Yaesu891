import SwiftUI
import AppKit

// MARK: - Farben

private extension Color {
    /// Farbe aus einem 24-Bit-Hexwert.
    /// - Parameter hex: `0xRRGGBB`, z. B. `0xF28A1E`.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Farbpalette der Marke „Mike Foxtrott“ – identisch mit der in `Icon/make_icon.py`.
enum Brand {
    static let navyTop = Color(hex: 0x0F2A44)
    static let navyBottom = Color(hex: 0x071827)
    static let orangeLight = Color(hex: 0xFFB84D)
    static let orangeMid = Color(hex: 0xF28A1E)
    static let orangeDark = Color(hex: 0xC9560F)
    static let creamLight = Color(hex: 0xFFF8EA)
    static let creamDark = Color(hex: 0xFFE3B5)
    static let teal = Color(hex: 0x4FE3D2)
}

// MARK: - Antenne

/// Das Logo ohne Hintergrund: eine kleine Sendeantenne (Fußplatte, Stab mit Verlängerungsspule, leuchtende
/// Spitze) mit Funkwellen nach beiden Seiten.
///
/// Gezeichnet wird mit `Canvas` im Koordinatenraster des Icons (1024 × 1024), das Ergebnis skaliert
/// verlustfrei auf jede Größe. Die Marke belegt dabei etwa 480 × 645 Einheiten.
struct LogoMark: View {
    /// Kantenlänge des quadratischen Zeichenbereichs in Punkten.
    var size: CGFloat = 64

    /// Funkwellen von innen nach außen: Radius, Deckkraft und Strichstärke (im 1024er-Raster).
    private static let waves: [(radius: CGFloat, opacity: Double, width: CGFloat)] = [
        (96, 1.0, 24), (168, 0.68, 22), (240, 0.38, 20)
    ]

    var body: some View {
        Canvas { ctx, canvasSize in
            // Die Marke im Raster (Mittelpunkt 512/497) mittig und passend groß in den Zeichenbereich legen.
            let k = min(canvasSize.width, canvasSize.height) / 700
            ctx.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -512, y: -497)
            draw(&ctx)
        }
        .frame(width: size, height: size)
    }

    /// Zeichnet Funkwellen, Leuchten, Fuß, Stab, Spule und Spitze – von hinten nach vorn.
    private func draw(_ ctx: inout GraphicsContext) {
        let tip = CGPoint(x: 512, y: 316)

        // Funkwellen: Bögen um die Spitze, je ±36° um die Waagerechte.
        for side: CGFloat in [-1, 1] {
            for wave in LogoMark.waves {
                var path = Path()
                let steps = 24
                for i in 0...steps {
                    let deg = side * 90 + CGFloat(i) / CGFloat(steps) * 72 - 36
                    let a = deg * CGFloat.pi / 180
                    let p = CGPoint(x: tip.x + wave.radius * sin(a), y: tip.y - wave.radius * cos(a))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                ctx.stroke(path, with: .color(Brand.teal.opacity(wave.opacity)),
                           style: StrokeStyle(lineWidth: wave.width, lineCap: .round, lineJoin: .round))
            }
        }

        // Leuchten um die Spitze
        ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 70, y: tip.y - 70, width: 140, height: 140)),
                 with: .radialGradient(Gradient(colors: [Brand.teal.opacity(0.85), Brand.teal.opacity(0)]),
                                       center: tip, startRadius: 0, endRadius: 70))

        // Fuß und Platte
        ctx.fill(Path(roundedRect: CGRect(x: 428, y: 772, width: 168, height: 46), cornerRadius: 16),
                 with: .color(Brand.orangeDark))
        let plate = Path(roundedRect: CGRect(x: 362, y: 722, width: 300, height: 66), cornerRadius: 26)
        ctx.fill(plate, with: .linearGradient(Gradient(colors: [Brand.creamLight, Brand.creamDark]),
                                              startPoint: CGPoint(x: 380, y: 722), endPoint: CGPoint(x: 640, y: 788)))
        ctx.stroke(plate, with: .color(Brand.orangeDark), lineWidth: 6)

        // Stab
        ctx.fill(Path(roundedRect: CGRect(x: 488, y: 330, width: 48, height: 416), cornerRadius: 24),
                 with: .linearGradient(Gradient(colors: [Brand.orangeMid, Brand.orangeLight, Brand.orangeDark]),
                                       startPoint: CGPoint(x: 488, y: 0), endPoint: CGPoint(x: 536, y: 0)))

        // Verlängerungsspule: sechs gestapelte Windungen
        for i in 0..<6 {
            let y = 462 + CGFloat(i) * 24
            let turn = Path(roundedRect: CGRect(x: 454, y: y, width: 116, height: 18), cornerRadius: 9)
            ctx.fill(turn, with: .linearGradient(Gradient(colors: [Brand.orangeLight, Brand.orangeMid]),
                                                 startPoint: CGPoint(x: 0, y: y), endPoint: CGPoint(x: 0, y: y + 18)))
            ctx.stroke(turn, with: .color(Brand.orangeDark), lineWidth: 3)
        }

        // Spitze
        let ball = Path(ellipseIn: CGRect(x: tip.x - 30, y: tip.y - 30, width: 60, height: 60))
        ctx.fill(ball, with: .radialGradient(Gradient(colors: [.white, Brand.creamDark, Brand.orangeLight]),
                                             center: CGPoint(x: tip.x - 6, y: tip.y - 8),
                                             startRadius: 0, endRadius: 40))
        ctx.stroke(ball, with: .color(Brand.orangeDark), lineWidth: 5)
    }
}

// MARK: - Kachel, Kopfzeile, App-Icon

/// Das Logo auf dunkelblauer, abgerundeter Kachel – wie das App-Icon, in beliebiger Größe.
///
/// Die Kachel sorgt dafür, dass die Marke auch im hellen Erscheinungsbild gut lesbar bleibt.
struct LogoTile: View {
    /// Kantenlänge in Punkten.
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Brand.navyTop, Brand.navyBottom], startPoint: .top, endPoint: .bottom))
            LogoMark(size: size * 0.86)
        }
        .frame(width: size, height: size)
    }
}

/// Schmale Kopfzeile über der Verbindungsleiste: Kachel, Name „Mike Foxtrott“ und Untertitel.
struct BrandBar: View {
    var body: some View {
        HStack(spacing: 10) {
            LogoTile(size: 34)
            (Text("Mike ") + Text("Foxtrott").foregroundColor(Brand.orangeMid))
                .font(.title3.bold())
            Text("FT-891 Control")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// Erzeugt das App-Icon zur Laufzeit aus dem Logo.
///
/// Nötig, wenn die App ohne `.app`-Bundle läuft (Xcode, `swift run`): Dann gibt es keine `AppIcon.icns`,
/// und Dock sowie App-Wechsler würden das Standard-Icon zeigen.
enum AppIcon {
    /// Rendert das Icon im macOS-Raster (1024 px Leinwand, 824 px große Kachel).
    /// - Returns: Das Bild oder `nil`, falls das Rendern fehlschlägt.
    @MainActor
    static func image() -> NSImage? {
        let renderer = ImageRenderer(content: LogoTile(size: 824).frame(width: 1024, height: 1024))
        renderer.scale = 1
        return renderer.nsImage
    }
}
