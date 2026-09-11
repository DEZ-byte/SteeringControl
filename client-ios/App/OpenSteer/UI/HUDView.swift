import SwiftUI
import OpenSteerCore

/// Engine speed as a horizontal bar, with the shift light at the top end.
///
/// A bar rather than a number: at speed the driver reads it with peripheral
/// vision, and a five-digit number is unreadable that way.
struct RpmBar: View {
    let rpm: UInt16
    let redline: Double

    private var fraction: Double {
        min(1, max(0, Double(rpm) / redline))
    }

    private var colour: Color {
        switch fraction {
        case ..<0.75: return .green
        case ..<0.92: return .yellow
        default: return .red
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.12))
                    Capsule()
                        .fill(colour)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 12)

            Text("\(rpm) rpm")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
        .animation(nil, value: fraction)
    }
}

/// Small status pills. Grey means off, coloured means the game is reporting it.
struct TelemetryPills: View {
    let frame: TelemetryFrame

    var body: some View {
        HStack(spacing: 8) {
            pill("ABS", active: frame.absActive, colour: .orange)
            pill("TC", active: frame.tcActive, colour: .cyan)
            pill(String(format: "SLIP %.2f", frame.slip),
                 active: frame.slip > 0.2, colour: .red)
        }
    }

    private func pill(_ text: String, active: Bool, colour: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(active ? colour.opacity(0.85) : .white.opacity(0.10),
                        in: Capsule())
            .foregroundStyle(active ? .black : .white.opacity(0.6))
    }
}

/// One line of link state, plus the numbers that matter when something is wrong.
struct StatusBar: View {
    let status: LinkController.Status
    let motion: MotionSnapshot
    let display: DisplaySnapshot
    let showDetail: Bool

    private var indicator: Color {
        switch status.state {
        case .streaming: return .green
        case .degraded: return .yellow
        case .connecting: return .blue
        case .disconnected: return .red
        case .idle: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(indicator)
                .frame(width: 8, height: 8)

            Text(status.message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)

            if showDetail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        parts.append(String(format: "%.0f Hz", motion.motionHz))
        parts.append("tx \(status.packetsSent)")
        parts.append("rx \(status.framesReceived)")
        parts.append(String(format: "%.1f°", motion.thetaDegrees))
        parts.append("axis \(motion.steerI16)")

        // Send interval and display cadence: device measurements with no other way
        // to be read, so the numbers live here rather than in a log nobody opens.
        if status.sendIntervalP50Ms > 0 {
            parts.append(String(format: "ia %.1f/%.1f ms",
                                status.sendIntervalP50Ms, status.sendIntervalP99Ms))
        }
        if display.frameIntervalMs > 0 {
            parts.append(String(format: "disp %.1f ms", display.frameIntervalMs))
        }

        if status.droppedForBackpressure > 0 {
            parts.append("drop \(status.droppedForBackpressure)")
        }
        if status.sendErrors > 0 {
            parts.append("err \(status.sendErrors)")
        }
        if !status.hapticsAvailable {
            parts.append("no haptics")
        }
        if status.isPathExpensive {
            // A hotspot reads as expensive and is a perfectly good way to run
            // this, so it is a note rather than a warning.
            parts.append("hotspot")
        }
        return parts.joined(separator: "  ")
    }
}

/// A vertical pedal readout beside each thumb zone.
struct PedalGauge: View {
    let value: Double
    let label: String
    let colour: Color
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(colour.opacity(0.85))
                        .frame(height: geometry.size.height * min(1, max(0, value)))
                }
            }
            .frame(width: 26)

            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}
