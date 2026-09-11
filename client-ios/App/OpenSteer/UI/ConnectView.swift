import SwiftUI
import OpenSteerCore

/// Where the driver types the PC address and sets the wheel up.
///
/// Shown before the session starts and reachable from the settings button. There
/// is no discovery yet, so the address is typed once and remembered.
struct ConnectView: View {
    @ObservedObject var settings: AppSettings
    let onStart: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Address")
                        Spacer()
                        TextField("192.168.1.10", text: $settings.host)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 220)
                    }

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("9999", value: $settings.port, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                } header: {
                    Text("PC")
                } footer: {
                    Text("Run the OpenSteer daemon on the PC, then use the address "
                       + "it prints. Both devices must be on the same Wi-Fi network, "
                       + "or the phone's own hotspot.")
                }

                Section {
                    Picker("Lock to lock", selection: $settings.dor) {
                        ForEach(DegreesOfRotation.allCases) { dor in
                            Text(dor.label).tag(dor)
                        }
                    }

                    slider("Deadband", value: $settings.deadband,
                           range: 0...0.10, format: "%.3f")
                    slider("Response", value: $settings.gamma,
                           range: 1.0...1.6, format: "%.2f")
                } header: {
                    Text("Wheel")
                } footer: {
                    Text("Larger lock to lock means more phone rotation for the same "
                       + "steering, which is easier to hold steady at speed. Response "
                       + "above 1.0 softens the centre and keeps full lock reachable.")
                }

                Section {
                    slider("Thumb travel", value: $settings.pedalTravel,
                           range: PedalMapper.minimumTravel...PedalMapper.maximumTravel,
                           format: "%.0f pt")
                } header: {
                    Text("Pedals")
                } footer: {
                    Text("A pedal starts at zero wherever your thumb lands and applies "
                       + "as you slide down. Travel is how far a full press takes.")
                }

                Section("Haptics") {
                    Toggle("Engine rumble", isOn: $settings.rumbleEnabled)
                    Toggle("ABS ticks", isOn: $settings.absTicksEnabled)
                    Toggle("Traction control ticks", isOn: $settings.tcTicksEnabled)
                }

                Section("Display") {
                    Toggle("Show diagnostics", isOn: $settings.showDebugHud)
                }
            }
            .navigationTitle("OpenSteer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onClose)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Drive", action: onStart)
                        .disabled(!settings.isHostUsable)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
