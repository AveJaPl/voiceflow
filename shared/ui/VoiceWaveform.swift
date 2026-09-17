import SwiftUI
import Combine

/// A bounded, soft-knee meter. Rendering cadence is independent of ASR chunks.
struct VoiceMeter {
    private(set) var amplitude: Double = 0

    mutating func update(rms: Float, delta: Double) {
        let input = rms.isFinite ? max(0, Double(rms) - 0.002) : 0
        let target = 1 - exp(-input * 18)
        let timeConstant = target > amplitude ? 0.045 : 0.13
        amplitude += (target - amplitude) * (1 - exp(-min(max(delta, 0), 0.1) / timeConstant))
    }

    func height(index: Int, count: Int, time: Double, reducedMotion: Bool) -> Double {
        let x = Double(index) / Double(max(1, count - 1))
        let envelope = 0.5 + 0.5 * sin(.pi * x)
        let variation = reducedMotion ? 0.75 : 0.65
            + 0.22 * sin(time * 9 + Double(index) * 1.7)
            + 0.13 * sin(time * 15 - Double(index) * 0.8)
        return 2 + 18 * amplitude * envelope * variation
    }
}

struct VoiceWaveform: View {
    let level: Float
    var tint: Color = .white
    var barCount = 25
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var meter = VoiceMeter()
    @State private var lastTick = Date()
    @State private var time: Double = 0
    private let clock = Timer.publish(every: 1 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { context, size in
            let spacing = size.width / CGFloat(barCount)
            for index in 0..<barCount {
                let height: CGFloat = min(size.height, CGFloat(meter.height(index: index, count: barCount, time: time, reducedMotion: reducedMotion)))
                let rect = CGRect(x: CGFloat(index) * spacing + 1, y: (size.height - height) / 2,
                                  width: max(2, spacing * 0.48), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(tint))
            }
        }
        .onReceive(clock) { now in
            meter.update(rms: level, delta: now.timeIntervalSince(lastTick))
            lastTick = now
            time = now.timeIntervalSinceReferenceDate
        }
        .accessibilityHidden(true)
    }
}

/// Shared compact recording surface. Identical geometry and meter on both platforms.
struct VoiceRecordingPill: View {
    let level: Float
    var label = "Słucham"
    var active = true
    var icon = "mic.fill"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
            if active {
                VoiceWaveform(level: level).frame(width: 124, height: 22)
            } else {
                Text(label).font(.system(size: 12, weight: .medium)).frame(width: 124, height: 22)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .foregroundStyle(.white)
        .background(Color(red: 0.24, green: 0.24, blue: 0.26))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .accessibilityLabel(label)
    }
}
