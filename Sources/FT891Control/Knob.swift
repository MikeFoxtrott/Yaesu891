import SwiftUI
import AppKit

/// Hilfsobjekt für den Mausrad-Monitor (Referenztyp, damit der Closure immer den aktuellen Zustand sieht).
final class ScrollBox {
    /// Der Mauszeiger steht über dem Regler.
    var inside = false
    /// Aufgelaufener, noch nicht in ganze Schritte umgesetzter Scroll-Weg.
    var acc = 0.0
    /// Handle des lokalen Ereignismonitors (zum Entfernen).
    var monitor: Any?
}

/// Drehregler zum Abstimmen: mit der Maus am Rand ziehen und im Kreis drehen,
/// oder mit Mausrad / Trackpad-Scrollen, während der Zeiger über dem Regler steht.
/// Eine Rastung (6°) entspricht einem Abstimmschritt.
struct TuningKnob: View {
    @Environment(Radio.self) private var radio
    var size: CGFloat = 150

    @State private var rotation = 0.0
    @State private var lastAngle: Double?
    @State private var accumulated = 0.0
    @State private var scroll = ScrollBox()

    /// Drehwinkel in Grad, der einer Rastung (einem Abstimmschritt) entspricht.
    private let detent = 6.0

    var body: some View {
        @Bindable var radio = radio
        VStack(spacing: 8) {
            dial
            Picker("Schritt", selection: $radio.tuneStep) {
                ForEach(Radio.tuneSteps, id: \.self) { s in
                    Text(stepLabel(s)).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: max(size, 200))
            Text("Drehen: ziehen oder Mausrad")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: installMonitor)
        .onDisappear(perform: removeMonitor)
    }

    /// Der Regler selbst: Drehteil mit Rändelung und Markierung, feststehender Rand, Ziehgeste.
    private var dial: some View {
        ZStack {
            ZStack {
                Circle().fill(
                    LinearGradient(colors: [Color(nsColor: .controlBackgroundColor), Color.gray.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                ForEach(0..<36, id: \.self) { i in
                    Capsule()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 3, height: size * 0.07)
                        .offset(y: -(size / 2 - size * 0.07))
                        .rotationEffect(.degrees(Double(i) * 10))
                }
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: size * 0.09, height: size * 0.09)
                    .offset(y: -(size * 0.30))
            }
            .rotationEffect(.degrees(rotation))
            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 2)
        }
        .frame(width: size, height: size)
        .shadow(radius: 3, y: 2)
        .contentShape(Circle())
        .onHover { scroll.inside = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in drag(to: value.location) }
                .onEnded { _ in
                    lastAngle = nil
                    accumulated = 0
                }
        )
        .help("Frequenz abstimmen – am Regler drehen oder Mausrad benutzen")
    }

    /// Verarbeitet die Ziehgeste: rechnet die Zeigerposition in einen Winkel um und setzt die Winkeländerung
    /// in ganze Rastungen um. Nahe der Mitte reagiert der Regler nicht, weil dort der Winkel unstabil wird.
    /// - Parameter p: Zeigerposition im Koordinatensystem des Reglers.
    private func drag(to p: CGPoint) {
        let dx = Double(p.x - size / 2)
        let dy = Double(p.y - size / 2)
        guard (dx * dx + dy * dy).squareRoot() > Double(size) * 0.12 else { return }
        let angle = atan2(dx, -dy) * 180 / Double.pi      // 0° oben, im Uhrzeigersinn positiv
        if let last = lastAngle {
            var d = angle - last
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            rotation += d
            accumulated += d
            let steps = Int(accumulated / detent)
            if steps != 0 {
                accumulated -= Double(steps) * detent
                radio.tuneBy(steps: steps)
            }
        }
        lastAngle = angle
    }

    /// Beschriftung der Schrittweite, z. B. `100 Hz` oder `1 kHz`.
    private func stepLabel(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
    }

    /// Registriert einen Monitor für Mausrad und Trackpad-Scrollen; er wirkt nur, solange der Zeiger über dem Regler steht.
    /// Trackpads liefern feine Deltas (8 Punkte = 1 Rastung), Mausräder ganze Rasten.
    private func installMonitor() {
        guard scroll.monitor == nil else { return }
        let box = scroll
        let radio = self.radio
        scroll.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard box.inside else { return event }
            let unit: CGFloat = event.hasPreciseScrollingDeltas ? 8 : 1
            box.acc += Double(event.scrollingDeltaY / unit)
            let n = Int(box.acc)
            if n != 0 {
                box.acc -= Double(n)
                MainActor.assumeIsolated { radio.tuneBy(steps: n) }
            }
            return nil
        }
    }

    /// Entfernt den Scroll-Monitor wieder (beim Ausblenden des Reglers).
    private func removeMonitor() {
        if let m = scroll.monitor {
            NSEvent.removeMonitor(m)
            scroll.monitor = nil
        }
        scroll.inside = false
    }
}
