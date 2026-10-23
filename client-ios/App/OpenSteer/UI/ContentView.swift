import SwiftUI
import OpenSteerCore

/// The driving screen.
///
/// Landscape only. The left quarter of the width is the brake, the right quarter
/// is the throttle, and the middle half is the wheel, the readouts and every
/// button. The paddles sit at the top of the middle half, either side of the RPM
/// bar.
///
/// Nothing in the driving view moves under a finger. Every control is either a
/// thumb zone with no visible boundary to miss, or a target at a fixed spot in
/// the middle half that can be found without looking away from the screen.
struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var session = SessionViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingSettings = false

    private static let paddleWidth: CGFloat = 104
    private static let paddleHeight: CGFloat = 64
    /// Gap between each paddle and the end of the middle half.
    private static let paddleZoneMargin: CGFloat = 12

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
        // Keeps an edge swipe from pulling down Notification Center or Control
        // Center mid-corner. The swipe home from the bottom edge of a Face ID
        // iPhone cannot be deferred: with the home indicator hidden, the first
        // swipe only shows it and the next one leaves. Pedals apply on an upward
        // slide, so a press should start a little above that edge.
        .defersSystemGestures(on: .all)
        .persistentSystemOverlays(.hidden)
        // A swipe down closes the sheet without either button, so the settings
        // are applied on every dismissal as well.
        .sheet(isPresented: $showingSettings, onDismiss: {
            session.apply(settings: settings)
        }) {
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
            // A 120 Hz gyro left running behind a phone call can get the app
            // killed for power use. `.inactive` is not backgrounding: it is a
            // notification banner, a half-pulled Control Center, or the Local
            // Network prompt over the first connection attempt, and tearing the
            // session down under any of those drops the driver mid-corner.
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

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    PedalGauge(value: session.brake, label: "BRAKE",
                               colour: .red, alignment: .leading)
                        .frame(width: 60)
                        .padding(.leading, 18)
                        .allowsHitTesting(false)

                    Spacer(minLength: 0)

                    centreColumn(middleWidth: geometry.size.width
                                 * (1 - 2 * PedalTouchView.zoneWidthFraction))

                    Spacer(minLength: 0)

                    PedalGauge(value: session.throttle, label: "THROTTLE",
                               colour: .green, alignment: .trailing)
                        .frame(width: 60)
                        .padding(.trailing, 18)
                        .allowsHitTesting(false)
                }
                .padding(.vertical, 14)
            }

            statusStrip
        }
    }

    private func centreColumn(middleWidth: CGFloat) -> some View {
        VStack(spacing: 10) {
            paddleRow(width: middleWidth)

            // Every readout is hit-testing off. A shape or a label that swallows a
            // touch turns into an invisible dead patch in the middle of a thumb
            // zone, and the driver has no way to see why the pedal stopped working.
            WheelView(store: session.store,
                      degreesOfRotation: settings.mapper.degreesOfRotation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            TelemetryPills(frame: session.telemetry.frame)
                .allowsHitTesting(false)

            controlRow
        }
        // A fixed width, not maxWidth: .infinity. An unbounded column ties with
        // the two spacers for flexibility, and the stack does not promise to
        // split the room evenly between them, so the column could slide sideways
        // and carry a paddle into a pedal zone. Fixed, the spacers share what
        // is left and the column stays centred.
        .frame(width: middleWidth)
    }

    /// The paddles, at the outer ends of the middle half, with the RPM bar
    /// between them.
    ///
    /// They used to sit in the top corners, over the pedal zones. A pedal now
    /// applies as the thumb slides up, so a thumb at full travel ends up near the
    /// top of its zone, and the next press would land on a paddle instead. Here
    /// they are a short reach in from the zone, and the zones are clear from top
    /// to bottom.
    ///
    /// The row is half the safe-area width, centred, less a margin at each end.
    /// The touch surface measures its zones across the whole glass, which is
    /// wider by the side insets, so the row always stays clear of the zones. The
    /// margin keeps a gap even on a phone with no side insets, where half the
    /// safe area ends exactly on the zone edges.
    private func paddleRow(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            paddle(label: "DOWN", mask: .downshift)

            Spacer(minLength: 10)

            // Without the priority the two spacers share the gap with the bar
            // and leave it a third of the room.
            RpmBar(rpm: session.telemetry.frame.rpm,
                   redline: HapticPolicy.defaultRedlineRpm)
                .frame(maxWidth: 260)
                .layoutPriority(1)
                .allowsHitTesting(false)

            Spacer(minLength: 10)

            paddle(label: "UP", mask: .upshift)
        }
        .padding(.horizontal, Self.paddleZoneMargin)
        .frame(width: width)
    }

    /// The bottom row of buttons. Like the paddles, they sit inside the middle
    /// half of the screen.
    ///
    /// None of them may sit in a thumb zone. The touch surface tracks one touch
    /// per zone, so a button inside one claims that touch and the driver's real
    /// thumb is then ignored for as long as the button is held.
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
                Text("CENTER")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .background(.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white.opacity(0.9))
            }

            // Held, never latched, so the handbrake cannot be left on by mistake.
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
///
/// `onEnded` runs only when the gesture succeeds. When the system cancels the
/// touch instead, for example under an incoming call, only the `@GestureState`
/// resets, so that reset releases the handbrake too.
private struct HoldButton: View {
    let label: String
    let isHeld: Bool
    let onHold: (Bool) -> Void

    @State private var isPressed = false
    @GestureState private var touchActive = false

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
                    .updating($touchActive) { _, active, _ in active = true }
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
            .onChange(of: touchActive) { _, active in
                if !active {
                    isPressed = false
                    onHold(false)
                }
            }
            .onDisappear {
                isPressed = false
                onHold(false)
            }
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
    @GestureState private var touchActive = false

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
                    .updating($touchActive) { _, active, _ in active = true }
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
            // A cancelled touch never reaches onEnded. Without this the latch
            // stays set and the next press on this paddle is ignored.
            .onChange(of: touchActive) { _, active in
                if !active { isPressed = false }
            }
    }
}
