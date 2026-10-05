import KandevKit
import SwiftUI

/// Chooses between the connect screen and a connected session.
///
/// The session is built in `init` rather than in `onAppear` so a saved server
/// does not flash the connect screen on every launch.
struct RootView: View {
    @State private var servers: ServerBookmarkStore
    @State private var session: AppSession?

    init() {
        let servers = ServerBookmarkStore()
        // A screenshot run brings its own server, or asks for none so that the connect
        // screen is what gets photographed. Inert in a release build, and idempotent
        // because a view can be initialised more than once.
        if ScreenshotTour.isActive {
            if let server = ScreenshotTour.server {
                servers.add(baseURLString: server.address, token: server.token)
            } else {
                for bookmark in servers.bookmarks { servers.remove(bookmark) }
            }
        }
        _servers = State(initialValue: servers)
        if let active = servers.active {
            _session = State(
                initialValue: AppSession(bookmark: active, token: servers.token(for: active))
            )
        }
    }

    var body: some View {
        if let session {
            TaskListView(
                session: session,
                servers: servers,
                onSelectServer: activate,
                onAddServer: { self.session = nil }
            )
            .id(session.bookmark.id)
        } else {
            ConnectView(servers: servers, onConnect: activate)
        }
    }

    private func activate(_ bookmark: ServerBookmark) {
        servers.setActive(bookmark.id)
        session = AppSession(bookmark: bookmark, token: servers.token(for: bookmark))
    }
}

#Preview {
    RootView()
}
