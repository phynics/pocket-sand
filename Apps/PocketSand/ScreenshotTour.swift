import Foundation

/// Opening a named screen for a screenshot run.
///
/// There is no way to tap a simulator from the command line — no `idb` on this
/// machine, and `simctl` has no touch — so the only way to photograph a screen that
/// is not the first one is to *tell the app to open it*. That is what `KANDEV_SCREEN`
/// does, and it replaces the old ritual of patching `TaskListView` by hand and
/// remembering to put it back, which `AGENTS.md` warns about for good reason: a backup
/// taken while the patch was live restores the patch.
///
/// **Inert in a release build.** `screen` is always `nil` and `ready` does nothing, so
/// the call sites in the views need no conditionals and nothing here can be reached by
/// a shipped app. It only reads environment variables that a developer sets.
///
/// The companion is `scripts/screenshots`, which iterates the screens, appearances and
/// content sizes, and waits for the readiness marker rather than guessing a duration.
enum ScreenshotTour {
    /// Places on a screen a run can ask to be shown, by the name of the thing there.
    enum Anchor: String {
        case filedIn = "filedin"
        case agent
        case repository
    }

    /// The screens a run can ask for by name.
    enum Screen: String {
        case list
        case newTask = "newtask"
        case chat
        case setup
        case detail
        /// Not a screen inside the app: it means "clear the saved server", so that the
        /// connect screen is what a run sees. Without the case, the name parsed to
        /// nothing, nothing was cleared, and a run photographed the task list and filed
        /// it as the connect screen.
        case connect
    }

    #if DEBUG
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var screen: Screen? {
        environment["KANDEV_SCREEN"].flatMap(Screen.init(rawValue:))
    }

    /// Which task `detail` should open.
    static var taskID: String? {
        environment["KANDEV_TASK"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// An anchor to scroll to, for the part of a screen that is below the fold.
    ///
    /// A still can only be taken of what is on screen, and plenty of what is worth
    /// looking at is at the bottom of a form. Without this, a defect down there is
    /// invisible to a run — which is exactly what happened to the row layout at the
    /// largest text sizes.
    static var anchor: Anchor? {
        environment["KANDEV_SCROLL"].flatMap { value in
            value.isEmpty ? nil : Anchor(rawValue: value)
        }
    }

    /// A server to talk to instead of the one in the Keychain, so a run does not depend
    /// on what is saved in the simulator.
    ///
    /// Absent while a tour is active, the bookmarks are cleared so the connect screen
    /// is what a run sees — which is the only way to photograph it.
    static var server: (address: String, token: String?)? {
        guard let address = environment["KANDEV_DEV_SERVER"], !address.isEmpty else { return nil }
        let token = environment["KANDEV_DEV_TOKEN"]
        return (address, (token?.isEmpty ?? true) ? nil : token)
    }

    static var isActive: Bool { screen != nil }

    /// Where a run looks for the marker. Under `Documents/`, which
    /// `xcrun simctl get_app_container … data` hands to the script.
    static let readyFileName = "screenshot-ready"

    /// Says a screen has settled, so the script can photograph it without guessing how
    /// long loading takes.
    ///
    /// A file rather than standard output: `simctl launch --stdout=` did not create the
    /// file it was given, and a script that waits on a clock is a script that
    /// photographs spinners. The app's own container is somewhere the host can read
    /// deterministically.
    /// - Parameter state: whether the screen ended up with what it needed. A run has to
    ///   be able to tell "photographed the screen" from "photographed the failure to
    ///   load it", which is exactly what a first run against a server that had gone
    ///   away could not: every screen settled, every screen said ok, and half of them
    ///   were empty states.
    static func ready(_ state: State = .loaded) {
        guard let screen,
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        try? "\(screen.rawValue) \(state.rawValue)".write(
            to: directory.appendingPathComponent(readyFileName),
            atomically: true,
            encoding: .utf8
        )
    }

    enum State: String {
        /// The screen has what it needs and is worth looking at.
        case loaded
        /// Settled without it: a failed load, or nothing to show. Photographed anyway,
        /// because an empty state is a state, but a run must not call it a success.
        case failed
        /// Nothing to load. The connect screen, for instance.
        case ready
    }
    #else
    static var screen: Screen? { nil }
    static var taskID: String? { nil }
    static var anchor: Anchor? { nil }
    static var server: (address: String, token: String?)? { nil }
    static var isActive: Bool { false }

    /// Present in both builds so the call sites need no conditions.
    enum State: String { case loaded, failed, ready }
    static func ready(_ state: State = .loaded) {}
    #endif
}
