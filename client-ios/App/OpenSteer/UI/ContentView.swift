import SwiftUI
import OpenSteerCore

/// The driving screen.
///
/// Landscape only. The left quarter of the width is the brake, the right quarter
/// is the throttle, and the middle half is the wheel and the readouts. The two
/// top corners are the paddles.
///
/// Nothing in the driving view moves under a finger. Every control is either a
/// thumb zone with no visible boundary to miss, or a target in a corner that can
/// be found without looking away from the screen.
struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var session = SessionViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingSettings = false

    private static let paddleWidth: CGFloat = 120
    private static let paddleHeight: CGFloat = 72

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.isRunning {
                drivingSurface
            } else {
                ConnectView(settings: settings,
                            onStart: startDriving,
                            onClose: nil)
            }
        }
        .statusBarHidden(true)
        // Keeps an edge swipe from pulling down Control Centre or the app
        // switcher mid-corner. The driver has to swipe twice to leave, which is
        // the behaviour every full-screen game uses.
        .defersSystemGestures(on: .all)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showingSettings) {
            ConnectView(settings: settings,
                        onStart: {
                            showingSettings = false
                            session.apply(settings: settings)
                        },
                        onClose: {
                            showingSettings = false
                            // The sheet edits the settings object in place, so
                            // closing it without this leaves the live session
                            // steering with the numbers the driver just changed.
                            session.apply(settings: settings)
                        })
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding stops the sensors, the connection and the haptics.
            // Leaving a 120 Hz gyro running behind a phone call is a fast way to
            // get the app killed for power use. `.inactive` is not backgrounding:
            // it is a notification banner, a half-pulled Control Centre, or the
            // Local Network prompt over the first connection attempt, and tearing
            // the session down under any of those drops the driver mid-corner.
            if phase == .background { session.enterBackground() }
        }
    }

    // MARK: - driving

    private var drivingSurface: some View {
        ZStack {
            // The touch surface sits under everything and is the full screen, so
            // a thumb never has to find an edge.
            PedalTouchView(travel: settings.pedalTravel) { throttle, brake in
                session.updatePedals(throttle: throttle, brake: brake)
            }
            .ignoresSafeArea()

            HStack(spacing: 0) {
                PedalGauge(value: session.brake, label: "BRAKE",
                           colour: .red, alignment: .leading)
                    .frame(width: 60)
                    .padding(.leading, 18)
                    .allowsHitTesting(false)

                Spacer(minLength: 0)

                centreColumn

                Spacer(minLength: 0)

                PedalGauge(value: session.throttle, label: "THROTTLE",
                           colour: .green, alignment: .trailing)
                    .frame(width: 60)
                    .padding(.trailing, 18)
                    .allowsHitTesting(false)
            }
            .padding(.vertical, 14)

            paddles
            statusStrip
        }
    }

    private var centreColumn: some View {
        VStack(spacing: 10) {
            // Every readout is hit-testing off. A shape or a label that swallows a
            // touch turns into an invisible dead patch in the middle of a thumb
            // zone, and the driver has no way to see why the pedal stopped working.
            RpmBar(rpm: session.telemetry.frame.rpm,
                   redline: HapticPolicy.defaultRedlineRpm)
                .frame(maxWidth: 260)
                .allowsHitTesting(false)

            WheelView(store: session.store,
                      degreesOfRotation: settings.mapper.degreesOfRotation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            TelemetryPills(frame: session.telemetry.frame)
                .allowsHitTesting(false)

            controlRow
        }
        .frame(maxWidth: .infinity)
    }

    /// Every button in the driving view lives here, inside the middle half of the
    /// screen.
    ///
    /// None of them may sit in a thumb zone. The touch surface tracks one touch
    /// per zone, so a button inside one claims that touch and the driver's real
    /// thumb is then ignored for as long as the button is held. The paddles are
    /// the single exception, and the touch surface cuts their rectangles out by
    /// hand for exactly this reason.
    private var controlRow: some View {
        HStack(spacing: 12) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 34)
                    .background(.white.opacity(0.10), in: Capsule())
                    .foregroundStyle(.white.opacity(0.7))
            }

            Button(action: session.recalibrate) {
                Text("CENTRE")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .background(.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white.opacity(0.9))
            }

            // Held, never latched. A handbrake you have to remember to release is
            // a handbrake you discover halfway down the next straight.
            HoldButton(label: "HOLD",
                       isHeld: session.isHandbrakeHeld) { held in
                session.setHandbrake(held)
            }

            Button {
                session.stop()
            } label: {
                Text("STOP")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(.red.opacity(0.18), in: Capsule())
                    .foregroundStyle(.red.opacity(0.95))
            }
        }
    }

    private var paddles: some View {
        VStack {
            HStack {
                paddle(label: "DOWN", mask: .downshift)
                Spacer()
                paddle(label: "UP", mask: .upshift)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func paddle(label: String, mask: ButtonMask) -> some View {
        PaddleButton(label: label,
                     width: Self.paddleWidth,
                     height: Self.paddleHeight) {
            session.paddle(mask)
        }
    }

    /// Text only, and hit-testing off. It runs the full width of the screen, which
    /// puts it across both thumb zones, so it must never be able to take a touch.
    private var statusStrip: some View {
        VStack {
            Spacer()
            HStack {
                StatusBar(status: session.status,
                          motion: session.motion,
                          display: session.display,
                          showDetail: settings.showDebugHud)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
        }
        .allowsHitTesting(false)
    }

    private func startDriving() {
        session.start(settings: settings)
    }
}

/// A button that reports press and release, for the handbrake.
///
/// `onChanged` repeats while the finger moves, so the press is latched and a
/// shaking hand cannot re-trigger it. The release is what matters most: it must
/// fire on `onEnded` no matter where the finger was when it lifted.
private struct HoldButton: View {
    let label: String
    let isHeld: Bool
    let onHold: (Bool) -> Void

    @State private var isPressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(isHeld ? .orange.opacity(0.75) : .white.opacity(0.10),
                        in: Capsule())
            .foregroundStyle(isHeld ? .black : .white.opacity(0.7))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        onHold(true)
                    }
                    .onEnded { _ in
                        isPressed = false
                        onHold(false)
                    }
            )
    }
}

/// A paddle that fires the moment it is touched.
///
/// A plain `Button` fires on release, which adds the whole press-and-lift time to
/// every gear change. A zero-distance drag gesture reports the touch down itself,
/// so the shift goes out in the next uplink packet 8 ms later.
private struct PaddleButton: View {
    let label: String
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .frame(width: width, height: height)
            .background(.white.opacity(isPressed ? 0.28 : 0.10),
                        in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white.opacity(0.8))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        // onChanged repeats while the finger moves, so the press
                        // is latched. Without this a shaking hand fires a burst of
                        // upshifts from one touch.
                        guard !isPressed else { return }
                        isPressed = true
                        action()
                    }
                    .onEnded { _ in isPressed = false }
            )
    }
}
