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
    @State private var isTokenVisible = false
    @ScaledMetric(relativeTo: .callout) private var revealRoom: CGFloat = 28
    /// The address field's text line, measured rather than guessed. A SecureField lays its
    /// text out a little shorter than a TextField does, so the token well was about 2pt
    /// shorter at the default size; it is given this as a minimum height instead.
    @State private var addressLineHeight: CGFloat = 0
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
                    FailureNote(message: problem)
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
        .task { ScreenshotTour.ready(.ready) }
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
            tokenField
        }
    }

    /// The token is a credential, so it is masked: a shoulder, a recording or a screenshot should
    /// not carry it. It can be revealed, because it is checked character by character, as the
    /// address is, which is why it is the same mono face in the same well. Only the glyph at the
    /// trailing edge changes between the two states.
    private var tokenField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.hair + 2) {
            Text("Access token, if the server wants one")
                .font(Theme.Face.chrome(.footnote))
                .foregroundStyle(Theme.muted)
            Group {
                if isTokenVisible {
                    TextField("", text: $token, prompt: tokenPrompt)
                } else {
                    SecureField("", text: $token, prompt: tokenPrompt)
                }
            }
            .font(Theme.Face.machine(.callout))
            .foregroundStyle(Theme.ink)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .frame(minHeight: addressLineHeight)
            // The room the reveal glyph takes at the trailing edge, so a long token stops short of it.
            .padding(.leading, Theme.Space.base)
            .padding(.vertical, Theme.Space.base)
            .padding(.trailing, Theme.Space.base + revealRoom)
            .fieldWell()
            .overlay(alignment: .trailing) { revealButton }
            .onSubmit(connect)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
        }
    }

    private var tokenPrompt: Text {
        Text("kandev_pat_…").foregroundStyle(Theme.muted)
    }

    /// A 44pt target, drawn as a glyph. It is an overlay on the well rather than part of its
    /// padding, so a larger target cannot make the token well taller than the address well.
    private var revealButton: some View {
        Button {
            isTokenVisible.toggle()
        } label: {
            Image(systemName: isTokenVisible ? "eye.slash" : "eye")
                .font(Theme.Face.chrome(.callout))
                .foregroundStyle(Theme.muted)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isTokenVisible ? "Hide token" : "Show token")
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { addressLineHeight = $0 }
                // The same well the composer and the brief are, and the same one a question in the
                // transcript is. A field is the one place this app fills a container, and a text
                // field is a text field wherever it is: this screen was drawn as a bordered
                // rectangle before anything here had been looked at.
                .padding(Theme.Space.base)
                .fieldWell()
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
