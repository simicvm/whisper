import SwiftUI

/// The floating circle UI shown during recording and transcription,
/// rendered as an animated MeshGradient clipped to a circle.
///
/// Animation speed is driven by the real-time microphone audio level:
/// - Quiet / no audio → slow, gentle drift
/// - Loud audio → fast, energetic movement
/// - Transcribing → slow drift + reduced opacity
struct RecordingOverlayView: View {
    let appState: AppState

    static let circleDiameter: CGFloat = 32

    private let circleSize = Self.circleDiameter

    /// Accumulates a "phase offset" each frame so that when audio level
    /// drops, the animation decelerates smoothly instead of jumping.
    /// Stored in a plain reference type (not observed state): TimelineView
    /// already re-evaluates every frame, so writing an @State property from
    /// the frame callback would invalidate the view a second time and double
    /// the per-frame rendering work.
    @State private var clock = PhaseClock()

    var body: some View {
        Group {
            if isVisible {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    gradientCircle(at: clock.advance(to: time, speed: currentSpeed))
                }
            }
        }
        .frame(width: circleSize, height: circleSize, alignment: .center)
        .clipped()
        .background(Color.clear)
    }

    private var isVisible: Bool {
        appState.phase == .recording || appState.phase == .transcribing
    }

    @ViewBuilder
    private func gradientCircle(at phase: Double) -> some View {
        MeshGradient(
            width: 4,
            height: 4,
            points: meshPoints(at: phase),
            colors: meshColors
        )
        .frame(width: circleSize * 1.5, height: circleSize * 1.5)
        .frame(width: circleSize, height: circleSize)
        .clipShape(Circle())
        .overlay(
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.clear, .black.opacity(0.22)],
                        center: .center,
                        startRadius: circleSize * 0.30,
                        endRadius: circleSize * 0.50
                    )
                )
                .blendMode(.multiply)
        )
        .overlay(
            Circle()
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        )
        .opacity(appState.phase == .transcribing ? 0.35 : 1.0)
    }

    // MARK: - Phase Accumulation

    /// Animation speed driven by the app phase and live audio level.
    private var currentSpeed: Double {
        if appState.phase == .transcribing {
            return 0.15
        }
        return 0.15 + Double(appState.audioLevel) * 4.85
    }

    /// Integrates phase over time at a variable speed.
    private final class PhaseClock {
        private var phase: Double = 0
        private var lastTime: TimeInterval?

        /// Advance by the elapsed time scaled by `speed` and return the new
        /// phase. The delta is clamped so gaps (first frame, the view being
        /// hidden and reshown) don't cause visual jumps.
        func advance(to time: TimeInterval, speed: Double) -> Double {
            let dt = lastTime.map { min(max(time - $0, 0), 0.1) } ?? 0
            phase += dt * speed
            lastTime = time
            return phase
        }
    }

    // MARK: - Mesh Points (4×4)

    /// Returns a 4×4 grid of control points (16 total).
    /// Edge points are inset slightly (0.02 / 0.98) to avoid clamping
    /// artifacts at boundaries. Interior points drift with sine/cosine
    /// waves seeded uniquely per point.
    private func meshPoints(at t: Double) -> [SIMD2<Float>] {
        // Edge inset to keep blending smooth at boundaries
        let lo: Float = 0.02
        let hi: Float = 0.98

        // Drift amplitudes
        let edgeAmp: Float = 0.06   // points along outer edges
        let innerAmp: Float = 0.12  // fully interior points

        func drift(_ base: SIMD2<Float>, amp: Float, seed: Double) -> SIMD2<Float> {
            let dx = amp * Float(sin(t * 1.7 + seed))
            let dy = amp * Float(cos(t * 2.3 + seed * 1.4))
            return SIMD2<Float>(
                min(max(base.x + dx, lo), hi),
                min(max(base.y + dy, lo), hi)
            )
        }

        return [
            // Row 0 — top edge
            SIMD2(lo, lo),
            drift(SIMD2(0.33, lo), amp: edgeAmp, seed: 1.0),
            drift(SIMD2(0.66, lo), amp: edgeAmp, seed: 2.0),
            SIMD2(hi, lo),

            // Row 1 — upper interior
            drift(SIMD2(lo, 0.33), amp: edgeAmp, seed: 3.0),
            drift(SIMD2(0.33, 0.33), amp: innerAmp, seed: 4.0),
            drift(SIMD2(0.66, 0.33), amp: innerAmp, seed: 5.0),
            drift(SIMD2(hi, 0.33), amp: edgeAmp, seed: 6.0),

            // Row 2 — lower interior
            drift(SIMD2(lo, 0.66), amp: edgeAmp, seed: 7.0),
            drift(SIMD2(0.33, 0.66), amp: innerAmp, seed: 8.0),
            drift(SIMD2(0.66, 0.66), amp: innerAmp, seed: 9.0),
            drift(SIMD2(hi, 0.66), amp: edgeAmp, seed: 10.0),

            // Row 3 — bottom edge
            SIMD2(lo, hi),
            drift(SIMD2(0.33, hi), amp: edgeAmp, seed: 11.0),
            drift(SIMD2(0.66, hi), amp: edgeAmp, seed: 12.0),
            SIMD2(hi, hi),
        ]
    }

    // MARK: - Colors (4×4)

    /// Sixteen vibrant colours arranged across the 4×4 mesh grid.
    private var meshColors: [Color] {
        [
            // Row 0
            Color(hue: 0.83, saturation: 0.90, brightness: 0.95), // violet
            Color(hue: 0.55, saturation: 0.85, brightness: 0.95), // cyan
            Color(hue: 0.45, saturation: 0.80, brightness: 0.90), // teal
            Color(hue: 0.35, saturation: 0.85, brightness: 0.90), // green

            // Row 1
            Color(hue: 0.95, saturation: 0.85, brightness: 0.95), // pink
            Color(hue: 0.75, saturation: 0.80, brightness: 0.95), // purple
            Color(hue: 0.08, saturation: 0.90, brightness: 1.00), // orange
            Color(hue: 0.15, saturation: 0.90, brightness: 1.00), // yellow

            // Row 2
            Color(hue: 0.60, saturation: 0.85, brightness: 0.90), // blue
            Color(hue: 0.02, saturation: 0.85, brightness: 1.00), // red-orange
            Color(hue: 0.90, saturation: 0.80, brightness: 0.95), // magenta
            Color(hue: 0.50, saturation: 0.75, brightness: 0.90), // sky blue

            // Row 3
            Color(hue: 0.72, saturation: 0.85, brightness: 0.90), // indigo
            Color(hue: 0.00, saturation: 0.85, brightness: 0.95), // red
            Color(hue: 0.12, saturation: 0.85, brightness: 1.00), // amber
            Color(hue: 0.80, saturation: 0.75, brightness: 0.95), // lavender
        ]
    }
}
