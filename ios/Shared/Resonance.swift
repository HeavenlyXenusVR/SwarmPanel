import SwiftUI

// "Resonance" -- the SwarmPanel visual language, shared by the iPhone/iPad
// app and the Apple TV app. This file holds only the platform-neutral
// pieces (bot identity colours, the hive geometry, the sound-wave field and
// the equalizer); each app layers its own surfaces and layout on top
// (DesignSystem/ResonanceUI.swift on iOS, TVResonance.swift on tvOS).
//
// The idea: SwarmPanel is a console for a fleet of music bots, so the app
// should look like it's listening. Screens sit on a dark studio sky crossed
// by slow sound-wave ribbons in the viewer's accent, and the fleet itself is
// drawn as a hive -- one hexagon per bot, in that bot's own colour, lit
// while it plays.

// MARK: - Bot identity

/// Each bot's signature colour and position in the hive. The colours are
/// the same ones the web panel uses (lua/src/config.lua's BOT_ACCENTS), so a
/// bot reads as the same character everywhere.
enum BotPalette {
    /// Fleet order: the order the web panel lists bots in.
    static let fleetOrder = [
        "gws", "maestro", "melodic", "nexus", "rhythm", "symphony",
        "tunestream", "alucard", "sapphire", "strife", "lockhart", "glitch", "dazzle",
    ]

    private static let accents: [String: UInt32] = [
        "gws": 0xCBA6F7, "maestro": 0xA6E3A1, "melodic": 0xFAB387,
        "nexus": 0xF38BA8, "rhythm": 0x94E2D5, "symphony": 0xF9E2AF, "tunestream": 0xB4BEFE,
        "alucard": 0xE06C75, "sapphire": 0x4FC3F7, "strife": 0xFF6B6B, "lockhart": 0xF9A8D4,
        "glitch": 0x00FF9F, "dazzle": 0xFFD700, "aria": 0xCBA6F7,
    ]

    /// The bot's colour, or a stable colour derived from its key for a bot
    /// added after this build shipped.
    static func color(for key: String) -> Color {
        let normalized = key.lowercased()
        if let value = accents[normalized] { return rgb(value) }
        var hash: UInt64 = 1469598103934665603
        for byte in normalized.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.95)
    }

    /// One- or two-letter monogram for a hive cell.
    static func monogram(for key: String, name: String?) -> String {
        if key.lowercased() == "gws" { return "GW" }
        let source = (name?.isEmpty == false ? name! : key)
        return String(source.prefix(2)).capitalized
    }

    static func rgb(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// How a bot is doing, as far as the hive is concerned.
enum HiveCellState: Equatable {
    case playing
    case paused
    case idle
    case offline
}

// MARK: - Hive geometry

/// A pointy-top hexagon filling its frame's height.
struct Hexagon: Shape {
    var cornerRadiusFraction: CGFloat = 0.12

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width / sqrt(3), rect.height / 2)
        let corners: [CGPoint] = (0..<6).map { index in
            let angle = (Double(index) * 60 - 90) * .pi / 180
            return CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
        }
        // Rounded corners: stop short of each vertex and curve through it.
        let inset = radius * cornerRadiusFraction
        var path = Path()
        for index in 0..<6 {
            let previous = corners[(index + 5) % 6]
            let current = corners[index]
            let next = corners[(index + 1) % 6]
            let entry = point(from: current, toward: previous, distance: inset)
            let exit = point(from: current, toward: next, distance: inset)
            if index == 0 { path.move(to: entry) } else { path.addLine(to: entry) }
            path.addQuadCurve(to: exit, control: current)
        }
        path.closeSubpath()
        return path
    }

    private func point(from a: CGPoint, toward b: CGPoint, distance: CGFloat) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(sqrt(dx * dx + dy * dy), 0.001)
        return CGPoint(x: a.x + dx / length * distance, y: a.y + dy / length * distance)
    }
}

/// Axial coordinates for a hive laid out in rings around a centre cell:
/// ring 0 is one cell, ring 1 six, ring 2 twelve -- so Aria plus all
/// thirteen music bots fit in the centre and first two rings, with room to
/// grow. Returned centres are in "cell units" (one cell = 1 wide).
enum HiveLayout {
    static func positions(count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        var result: [(q: Int, r: Int)] = [(0, 0)]
        var ring = 1
        let directions = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]
        while result.count < count {
            var q = -ring, r = ring // start at the ring's south-west corner
            for side in 0..<6 {
                for _ in 0..<ring where result.count < count {
                    result.append((q, r))
                    q += directions[side].0
                    r += directions[side].1
                }
            }
            ring += 1
        }
        // Pointy-top axial -> pixel, with cell width normalised to 1.
        return result.prefix(count).map { cell in
            let x = Double(cell.q) + Double(cell.r) / 2
            let y = Double(cell.r) * sqrt(3) / 2
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Sound-wave field

/// Deterministic RNG (SplitMix64), so generated decoration is identical on
/// every launch.
struct ResonanceRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Slow, layered sine ribbons drifting across the backdrop -- the
/// "resonance" the language is named for. Purely decorative: it ignores
/// touches, is hidden from VoiceOver, and stops moving under Reduce Motion
/// (`animated: false`), leaving a still frame.
struct WaveField: View {
    var tint: Color
    var secondary: Color
    var animated = true
    var ribbonCount = 4
    /// 0...1 vertical centre of the ribbon band.
    var baseline: CGFloat = 0.78
    var intensity: Double = 1

    private struct Ribbon {
        let amplitude: CGFloat
        let wavelength: CGFloat
        let speed: Double
        let phase: Double
        let offset: CGFloat
        let width: CGFloat
        let opacity: Double
        let useSecondary: Bool
    }

    private var ribbons: [Ribbon] {
        var generator = ResonanceRandom(seed: 0x5357_4152)
        return (0..<ribbonCount).map { index in
            Ribbon(
                amplitude: CGFloat.random(in: 0.025...0.06, using: &generator),
                wavelength: CGFloat.random(in: 0.55...1.2, using: &generator),
                speed: Double.random(in: 0.08...0.2, using: &generator) * (index.isMultiple(of: 2) ? 1 : -1),
                phase: Double.random(in: 0...(2 * .pi), using: &generator),
                offset: CGFloat(index) * 0.035 - 0.05,
                width: CGFloat.random(in: 1.0...2.2, using: &generator),
                opacity: Double.random(in: 0.22...0.5, using: &generator),
                useSecondary: index % 3 == 1
            )
        }
    }

    var body: some View {
        let field = ribbons
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let time = animated ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas { canvas, size in
                for ribbon in field {
                    var path = Path()
                    let steps = max(Int(size.width / 6), 24)
                    for step in 0...steps {
                        let progress = CGFloat(step) / CGFloat(steps)
                        let x = progress * size.width
                        // Two sines beating against each other, with a soft
                        // envelope so ribbons taper at the screen edges.
                        let envelope = sin(progress * .pi)
                        let primary = sin(Double(progress / ribbon.wavelength) * 2 * .pi + time * ribbon.speed * 6 + ribbon.phase)
                        let beat = sin(Double(progress) * 9 + time * ribbon.speed * 3) * 0.35
                        let y = (baseline + ribbon.offset) * size.height
                            + CGFloat(primary + beat) * ribbon.amplitude * size.height * envelope
                        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    let color = (ribbon.useSecondary ? secondary : tint).opacity(ribbon.opacity * intensity)
                    canvas.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: ribbon.width, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Equalizer

/// A small live equalizer: bars that dance while `isActive`, settle to a
/// low flat line otherwise. Each instance gets its own rhythm from `seed`
/// so a screen full of them doesn't move in lockstep.
struct EqualizerBars: View {
    var isActive: Bool
    var color: Color
    var barCount = 4
    var seed: UInt64 = 7
    var animated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !(isActive && animated))) { context in
            let time = (isActive && animated) ? context.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { geo in
                let spacing = geo.size.width * 0.12
                let barWidth = (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule()
                            .fill(color)
                            .frame(width: max(barWidth, 1), height: geo.size.height * level(index, time))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .accessibilityHidden(true)
    }

    private func level(_ index: Int, _ time: TimeInterval) -> CGFloat {
        guard isActive else { return 0.18 }
        guard animated else { return [0.55, 0.9, 0.4, 0.7, 0.6][index % 5] }
        let rate = 3.1 + Double((seed &+ UInt64(index) &* 31) % 17) / 6
        let phase = Double((seed &* 13 &+ UInt64(index) &* 7) % 100) / 15
        let value = 0.5 + 0.32 * sin(time * rate + phase) + 0.18 * sin(time * rate * 2.3 + phase * 1.7)
        return CGFloat(min(max(value, 0.12), 1))
    }
}
