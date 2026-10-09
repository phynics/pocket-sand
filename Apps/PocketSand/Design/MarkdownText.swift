import MarkdownUI
import SwiftUI

/// An agent's words, as the markdown they were written in.
///
/// The transcript's other voices are plain. A person types a sentence, and a step is one line
/// with a glyph in front of it. An agent writes markdown — headings, lists, fenced code, tables —
/// and drawing the characters it was written with is drawing the wrong thing.
///
/// A single `AttributedString`-backed `Text` gets bold, emphasis and links, and then stops: it
/// has no way to express a table, and a list arrives as a paragraph with numbers in it. That is
/// what a real renderer is for, and it is view code, so it lives here and not in KandevKit.
struct MarkdownText: View {
    let text: String

    /// Whether this text is still being written.
    ///
    /// Parsing is the expensive part, and a streaming reply changes on every token. While this is
    /// true the text is parsed at most every `coalesce`; the moment it stops, the exact text is
    /// parsed, so a finished answer is not a different page from the one that was streaming.
    let isStreaming: Bool

    /// The parsed document, not the string it came from. `Markdown` parses its source when it is
    /// created, so handing it the string on every body evaluation parsed the whole reply once per
    /// token. Parsing happens here, only when the text it shows changes.
    @State private var parsed: MarkdownContent
    @State private var parsedAt = Date.distantPast

    /// Long enough that the parse happens a handful of times a second at worst, short enough that
    /// a paragraph looks written rather than delivered in chunks.
    private static let coalesce: TimeInterval = 0.2

    init(text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
        _parsed = State(initialValue: MarkdownContent(text))
    }

    var body: some View {
        Markdown(parsed)
            .markdownTheme(.pocketSand)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: text) { _, latest in
                guard isStreaming else {
                    parsed = MarkdownContent(latest)
                    return
                }
                // The first words of a reply parse at once, so the row does not sit blank for a
                // fifth of a second. Later ones wait out the window.
                let now = Date()
                guard now.timeIntervalSince(parsedAt) >= Self.coalesce else { return }
                parsed = MarkdownContent(latest)
                parsedAt = now
            }
            .onChange(of: isStreaming) { _, streaming in
                // The last words may have arrived inside the window and been skipped: they are
                // parsed now, so the finished answer is the exact text.
                if !streaming { parsed = MarkdownContent(text) }
            }
    }
}

/// `@preconcurrency`, because MarkdownUI's own isolation is what these warnings are about.
///
/// This extension has to be `@MainActor`: `MarkdownUI.Theme()` is main-actor-isolated, so the theme
/// cannot be built anywhere else.
///
/// **Known gap: ninety-seven `#IsolatedConformances` warnings come from right here.** A view built
/// inside a main-actor context gets a main-actor-isolated conformance, and MarkdownUI's block
/// builders are `nonisolated`, so every block is a conformance that cannot be handed back. Four
/// fixes were attempted and measured against a clean build, and none of them works:
///
/// - De-isolating this extension: an error. `MarkdownUI.Theme()` is main-actor-isolated, so the
///   theme cannot be built anywhere else.
/// - De-isolating the palette's dynamic-colour initialiser, so the theme need not read main-actor
///   state: the same error, because the isolation is MarkdownUI's and not the palette's.
/// - Turning `InferIsolatedConformances` off: still 97. The diagnostic is not that feature's — it
///   fires under the Swift 6 language mode for conformances inferred anywhere.
/// - `@preconcurrency import MarkdownUI`: still 97.
/// - Building the theme in a `nonisolated` function that *takes* the five colours, so no builder
///   reads main-actor state: the warnings drop to 49 but sixty hard errors appear, because SwiftUI's
///   `View` protocol is main-actor, so `markdownMargin`, `relativeLineSpacing` and the rest are
///   main-actor too and a nonisolated body cannot call them at all. The two are mutually exclusive:
///   calling a SwiftUI modifier needs the main actor, and a view built on the main actor is the
///   thing that warns.
///
/// What is left is the only thing that can work, and it is a design decision rather than a fix:
/// stop customising the blocks. Keep `.text` and `.code` — the `TextStyle` builders, which are
/// quiet — and drop every closure that returns a view, which means giving up the headings' sizes and
/// margins, the paragraph leading, the blockquote's rule, the code block's background and scroll
/// view, the app's own thematic-break divider, and the table's borders and paint. That is most of
/// what the agent's page is, traded for a quiet build, and it is not mine to trade.
@MainActor
extension MarkdownUI.Theme {
    /// The agent's page, set in this app's own hands.
    ///
    /// MarkdownUI's themes bring their own typography, and none of it belongs here: this answer
    /// sits in a transcript where a person's question is serif and the work is mono, and a third
    /// voice with its own sizes and greys would read as a third author. What is borrowed is the
    /// structure — the sizes are relative to the reader's own, so Dynamic Type moves the whole
    /// page, and every colour is one of the app's.
    ///
    /// The agent's own voice is decided here rather than in `Theme.Face`, because a renderer takes
    /// relative sizes and not a `Font`: sans, a size down from a person's, with less leading than
    /// the serif prose wants. It writes at length, and an answer as heavy as the question it
    /// answers is the wrong shape; a narrower face at a smaller size is what keeps the question the
    /// loudest thing in the exchange.
    static let pocketSand = MarkdownUI.Theme()
        .text {
            FontFamily(.system())
            // A step down from the platform's body size, which is what an agent's answer is: it is
            // long, and at body size it competes with the question it is answering.
            FontSize(.em(0.94))
            ForegroundColor(Theme.ink)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .em(1.2), bottom: .em(0.4))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.35))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: .em(1.2), bottom: .em(0.4))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.2))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: .em(1), bottom: .em(0.3))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.08))
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: .em(1), bottom: .em(0.3))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1))
                }
        }
        .heading5 { configuration in
            configuration.label
                .markdownMargin(top: .em(1), bottom: .em(0.3))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.95))
                }
        }
        .heading6 { configuration in
            configuration.label
                .markdownMargin(top: .em(1), bottom: .em(0.3))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.9))
                    ForegroundColor(Theme.muted)
                }
        }
        .paragraph { configuration in
            configuration.label
                // Less than the serif prose wants: a sans at a smaller size needs less air, and
                // this is the one voice that arrives by the page.
                .relativeLineSpacing(.em(0.14))
                .markdownMargin(top: .zero, bottom: .em(0.9))
        }
        .blockquote { configuration in
            // A rule at the leading edge, which is how this app marks a quotation everywhere else.
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.rule)
                    .relativeFrame(width: .em(0.12))
                configuration.label
                    .markdownTextStyle { ForegroundColor(Theme.muted) }
                    .relativePadding(.horizontal, length: .em(0.9))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .codeBlock { configuration in
            // Scrolls sideways rather than wrapping: a wrapped line of code is a line whose
            // indentation no longer means anything.
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.9))
                    }
                    .padding(Theme.Space.base)
            }
            .background(Theme.surface)
            .markdownMargin(top: .em(0.6), bottom: .em(0.9))
        }
        .listItem { configuration in
            configuration.label.markdownMargin(top: .em(0.25))
        }
        .thematicBreak {
            // The app's own divider, not a line drawn by a renderer.
            Rule().markdownMargin(top: .em(1), bottom: .em(1))
        }
        .table { configuration in
            configuration.label
                .markdownTableBorderStyle(
                    .init(
                        color: Theme.rule,
                        strokeStyle: StrokeStyle(lineWidth: 1)
                    )
                )
                .markdownTableBackgroundStyle(
                    .alternatingRows(Theme.paper, Theme.surface)
                )
                .markdownMargin(top: .em(0.6), bottom: .em(0.9))
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                }
                .relativePadding(.vertical, length: .em(0.35))
                .relativePadding(.horizontal, length: .em(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
}
