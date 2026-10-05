import SwiftUI

/// An empty screen, said in the app's own voice.
///
/// Hand-rolled rather than `ContentUnavailableView` so it is set in the app's
/// faces: a serif line for what this is, and a plain sentence for what to do. An
/// empty screen is an invitation, not an apology.
struct EmptyNote: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(title)
                .font(Theme.Face.prose(.title3))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(Theme.Face.chrome(.callout))
                .foregroundStyle(Theme.muted)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.section)
    }
}

#Preview {
    EmptyNote(
        title: "No session yet",
        detail: "This task has no agent conversation. Start one and it will have something to say."
    )
    .padding(Theme.Space.loose)
    .background(Theme.paper)
}
