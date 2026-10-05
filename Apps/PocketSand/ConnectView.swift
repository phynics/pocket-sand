import KandevKit
import SwiftUI

/// Where a server address is entered.
///
/// Deliberately minimal, as agreed for v1: one address, an optional token, no
/// account, no discovery. The token field exists because the server may have
/// authentication on, not because it usually does — a default install has no
/// client authentication boundary at all.
struct ConnectView: View {
    let servers: ServerBookmarkStore
    let onConnect: (ServerBookmark) -> Void

    @State private var urlString: String
    @State private var token = ""
    @State private var problem: String?

    init(servers: ServerBookmarkStore, onConnect: @escaping (ServerBookmark) -> Void) {
        self.servers = servers
        self.onConnect = onConnect
        _urlString = State(initialValue: servers.active?.baseURLString ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                masthead
                address
                if let problem {
                    Text(problem)
                        .font(Theme.Face.chrome(.footnote))
                        .foregroundStyle(Theme.muted)
                }
                connectButton
                if !servers.bookmarks.isEmpty {
                    savedServers
                }
            }
            .padding(Theme.Space.loose)
            .frame(maxWidth: Theme.measure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .paperBackground()
    }

    /// The app's name is the one place a large serif face is used as a mark rather
    /// than as prose. It is the first thing anyone sees, and it should look like
    /// the app rather than like a settings screen.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("Pocket Sand")
                .font(Theme.Face.prose(.largeTitle))
                .foregroundStyle(Theme.ink)
            Text("A remote control for the agents running on your own server.")
                .font(Theme.Face.chrome(.callout))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
        }
        .padding(.top, Theme.Space.section)
    }

    private var address: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            field("Server address", text: $urlString, prompt: "http://kandev.local:38429")
            field("Access token, if the server wants one", text: $token, prompt: "kandev_pat_…")
        }
    }

    /// Mono, because an address and a token are machine strings. A proportional
    /// face makes both harder to check character by character, which is the only
    /// way anyone reads them.
    private func field(
        _ label: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.hair + 2) {
            Text(label)
                .font(Theme.Face.chrome(.footnote))
                .foregroundStyle(Theme.muted)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.muted))
                .font(Theme.Face.machine(.callout))
                .foregroundStyle(Theme.ink)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .padding(Theme.Space.snug + 2)
                .overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
                .onSubmit(connect)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
        }
    }

    private var connectButton: some View {
        Button("Connect", action: connect)
            .font(Theme.Face.chrome(.callout, weight: .semibold))
            .foregroundStyle(parsedAddress == nil ? Theme.muted : Theme.ink)
            .buttonStyle(.plain)
            .disabled(parsedAddress == nil)
    }

    private var savedServers: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            Rule()
            Text("Saved servers")
                .font(Theme.Face.chrome(.footnote))
                .foregroundStyle(Theme.muted)

            ForEach(servers.bookmarks) { bookmark in
                Button {
                    onConnect(bookmark)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bookmark.name)
                            .font(Theme.Face.prose(.callout))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: Theme.Space.snug)
                        Text(bookmark.baseURLString)
                            .font(Theme.Face.machine(.caption2))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The rule lives in `ServerAddress`, not here, so it can be tested.
    private var parsedAddress: ServerAddress? { ServerAddress(string: urlString) }

    private func connect() {
        guard let address = parsedAddress else {
            problem = ServerAddress.rejectionMessage
            return
        }
        problem = nil
        let bookmark = servers.add(
            baseURLString: address.displayText,
            token: token.isEmpty ? nil : token
        )
        onConnect(bookmark)
    }
}

#Preview {
    ConnectView(servers: ServerBookmarkStore(defaults: .init(suiteName: "preview")!), onConnect: { _ in })
}
