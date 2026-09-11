import SwiftUI

/// The whole app.
///
/// No `AppDelegate` and no `SceneDelegate`. Everything they were needed for is
/// covered by the Info.plist keys and three SwiftUI modifiers on the root view:
/// the status bar by `UIStatusBarHidden`, the home indicator by
/// `persistentSystemOverlays(.hidden)`, and the edge swipes by
/// `defersSystemGestures(on: .all)`. Two extra classes that exist only to
/// override two properties are two more places for lifecycle bugs to hide.
@main
struct OpenSteerApp: App {
    @StateObject private var settings = AppSettings()

    init() {
        // Invariant I6. The uplink is written field by field at fixed byte
        // offsets and, unlike the C# side, carries no `MemoryLayout` size
        // assertion to fall back on, so this is the only place the client would
        // ever notice a host that is not little-endian.
        precondition(UInt32(littleEndian: 1) == 1,
                     "the OpenSteer wire format is little-endian")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}
