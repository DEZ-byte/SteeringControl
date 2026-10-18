import Combine
import Foundation
import SwiftUI
import OpenSteerCore

/// Everything the driver can change, remembered between runs.
///
/// Stored in `UserDefaults`, so the host address survives a restart and does not
/// have to be retyped.
///
/// Written out by hand rather than with `@AppStorage`. That wrapper is a
/// `DynamicProperty`: it only republishes when SwiftUI installs it in a view
/// graph, so on a plain `ObservableObject` it reads and writes defaults
/// correctly and never fires `objectWillChange`. A slider bound to one moves and
/// snaps straight back, because nothing observing this object is ever
/// invalidated.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var host: String { didSet { defaults.set(host, forKey: "host") } }
    @Published var port: Int { didSet { defaults.set(port, forKey: "port") } }

    @Published var degreesOfRotation: Int { didSet { defaults.set(degreesOfRotation, forKey: "dor") } }
    @Published var deadband: Double { didSet { defaults.set(deadband, forKey: "deadband") } }
    @Published var gamma: Double { didSet { defaults.set(gamma, forKey: "gamma") } }

    @Published var pedalTravel: Double { didSet { defaults.set(pedalTravel, forKey: "pedalTravel") } }

    @Published var absTicksEnabled: Bool { didSet { defaults.set(absTicksEnabled, forKey: "absTicks") } }
    @Published var tcTicksEnabled: Bool { didSet { defaults.set(tcTicksEnabled, forKey: "tcTicks") } }
    @Published var rumbleEnabled: Bool { didSet { defaults.set(rumbleEnabled, forKey: "rumble") } }

    @Published var showDebugHud: Bool { didSet { defaults.set(showDebugHud, forKey: "showDebugHud") } }

    /// The defaults are registered rather than written, so a key the driver has
    /// never touched reads back as the shipped value instead of as zero.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "host": "192.168.1.10",
            "port": 9999,
            "dor": DegreesOfRotation.dor180.rawValue,
            "deadband": SteerMapper.defaultDeadband,
            "gamma": SteerMapper.defaultGamma,
            "pedalTravel": PedalMapper.defaultTravel,
            "absTicks": true,
            "tcTicks": true,
            "rumble": true,
            "showDebugHud": false,
        ])

        host = defaults.string(forKey: "host") ?? "192.168.1.10"
        port = defaults.integer(forKey: "port")
        degreesOfRotation = defaults.integer(forKey: "dor")
        deadband = defaults.double(forKey: "deadband")
        gamma = defaults.double(forKey: "gamma")
        pedalTravel = defaults.double(forKey: "pedalTravel")
        absTicksEnabled = defaults.bool(forKey: "absTicks")
        tcTicksEnabled = defaults.bool(forKey: "tcTicks")
        rumbleEnabled = defaults.bool(forKey: "rumble")
        showDebugHud = defaults.bool(forKey: "showDebugHud")

        // An install from before the rotation options were resized still has 540
        // or 900 on disk. Those were wheel numbers on a device that cannot turn
        // that far, and a phone left on one can only ever reach a fifth of the
        // car's lock. Migrate rather than fall back: a fallback would fix the
        // picker and leave the old number driving the wheel.
        if DegreesOfRotation(rawValue: degreesOfRotation) == nil {
            degreesOfRotation = DegreesOfRotation.dor180.rawValue
            // Written by hand because property observers do not run during init.
            defaults.set(degreesOfRotation, forKey: "dor")
        }
    }

    /// Built from `dor`, not from the raw stored integer.
    ///
    /// Those two can disagree: an install carrying a value the enum no longer
    /// offers falls back for the picker but would keep the old number here, so
    /// the wheel would behave as a setting the driver cannot see. Going through
    /// `dor` makes that impossible.
    var mapper: SteerMapper {
        SteerMapper(dor: dor, deadband: deadband, gamma: gamma)
    }

    var portValue: UInt16 {
        UInt16(clamping: port)
    }

    var dor: DegreesOfRotation {
        get { DegreesOfRotation(rawValue: degreesOfRotation) ?? .dor180 }
        set { degreesOfRotation = newValue.rawValue }
    }

    /// A host string that could plausibly be reached. Kept loose: a
    /// hostname, an IPv4 address and a `.local` name are all valid, and rejecting
    /// something the network stack would have accepted is worse than trying.
    var isHostUsable: Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains(" ")
    }
}
