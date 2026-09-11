import Combine
import Foundation
import SwiftUI
import OpenSteerCore

/// Everything the driver can change, remembered between runs.
///
/// Stored in `UserDefaults`, so the host address survives a restart. Nobody wants
/// to retype an IP address while sitting in a rig.
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
            "dor": DegreesOfRotation.dor900.rawValue,
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
    }

    var mapper: SteerMapper {
        SteerMapper(degreesOfRotation: Double(degreesOfRotation),
                    deadband: deadband,
                    gamma: gamma)
    }

    var portValue: UInt16 {
        UInt16(clamping: port)
    }

    var dor: DegreesOfRotation {
        get { DegreesOfRotation(rawValue: degreesOfRotation) ?? .dor900 }
        set { degreesOfRotation = newValue.rawValue }
    }

    /// A host string that could plausibly be reached. Deliberately loose: a
    /// hostname, an IPv4 address and a `.local` name are all valid, and rejecting
    /// something the network stack would have accepted is worse than trying.
    var isHostUsable: Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains(" ")
    }
}
