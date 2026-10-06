import SwiftUI

/// The app's visual vocabulary: six achromatic values, three voices, no accent.
///
/// **The app has no colour of its own.** Every hue on screen comes from the
/// workflow step colours the server sends, plus the system's destructive red.
/// That is not restraint for its own sake — it settles a real argument. The server
/// colours process position, so any accent the app introduced would compete with
/// the one signal that carries meaning. Attention is therefore *ink*, not a hue.
///
/// **Three voices, three faces.** This app is a transcript: a record of who said
/// what. Type says which voice is speaking rather than decorating a screen.
///
/// - A person reading prose gets `New York` — task titles, and the prompts someone
///   typed.
/// - The agent gets `SF Pro` a size down. It writes at length, and at body size in a
///   serif its answers weighed as much as the questions they answered.
/// - A machine's output gets `SF Mono` — commands, exit codes, agent identifiers,
///   timestamps. Those are tokens, not sentences.
/// - Chrome gets `SF Pro` as well — labels, controls, chips — told from the agent's
///   prose by size. The two never sit at the same size in the same place, which is
///   what makes sharing a face affordable.
///
/// Hierarchy comes from size and from space, not from a stack of weights.
enum Theme {
    // MARK: - Palette

    /// Light mode is paper: an off-white with a whisper of warmth, and a grain.
    /// Dark mode is the void: pitch black, and deliberately no grain, because
    /// texture on true black lifts it off black and undoes the point of it.
    ///
    /// The values were chosen against measured contrast rather than by eye. Ink on
    /// paper is 16:1 and ink on black is 19:1; muted is 5.5:1 on paper and 6.4:1 on
    /// black, which keeps a clear step below ink without becoming hard to read at
    /// caption sizes; the rule is a hairline that is visible (1.4:1) and still
    /// quiet; the surface step is just enough to read as a block (1.15:1).
    static let paper = Color(light: 0xF5F5F2, dark: 0x000000)
    static let surface = Color(light: 0xE6E6E0, dark: 0x16161A)
    static let ink = Color(light: 0x15171B, dark: 0xF2F2F4)
    static let muted = Color(light: 0x63635C, dark: 0x8E8E93)

    /// What the machine is *doing*, as against what somebody *said*.
    ///
    /// Ink is for the two things you came to read — a person's question and an agent's answer —
    /// and muted is for an aside: a label, a step's own name, a fact you glance at. The line under
    /// a run and the step being written are neither. They are the only text on the screen that
    /// changes without anyone touching it, and at full ink both read as the loudest thing in a
    /// conversation they are only narrating: "Ran for 11 seconds" was set in ink at medium weight,
    /// which made a counter heavier than the answer it was counting.
    ///
    /// Only those two lines take it. An answer stays at ink, because softening what someone said
    /// to distinguish it from what a machine is doing would be the wrong trade.
    ///
    /// Measured rather than picked by eye, like the rest: 8.9:1 on paper and 10:1 on black, a
    /// clear step below ink and a clear step above muted.
    static let graphite = Color(light: 0x43464C, dark: 0xB4B4B9)

    static let rule = Color(light: 0xD0D0C8, dark: 0x2E2E32)

    // MARK: - Metrics

    /// Everything is placed on this grid, which is why the screens line up.
    enum Space {
        static let hair: CGFloat = 4
        static let snug: CGFloat = 8
        static let base: CGFloat = 12
        static let loose: CGFloat = 16
        static let section: CGFloat = 28
    }

    /// The spine that marks a task's workflow position, and the inset that keeps
    /// text off it.
    enum Spine {
        static let width: CGFloat = 3
        static let textInset: CGFloat = 13
        /// Clear space above and below a row's spine, so one row's colour does not
        /// run into its neighbour's.
        ///
        /// The spine was continuous from the first row to the last, which was the
        /// point of it — a column you can scan. A pulsing row is the exception that
        /// shows the cost: at full bleed it merges with the row above and the row
        /// below, and "this task is working" reads as "these three tasks are
        /// working". A gap the height of a hairline keeps the column and ends the
        /// ambiguity.
        static let gap: CGFloat = 3
    }

    /// Where prose stops being comfortable to read.
    static let measure: CGFloat = 34 * 11

    // MARK: - Type

    enum Face {
        /// For anything a person reads as prose.
        static func prose(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
            .system(style, design: .serif, weight: weight)
        }

        /// For anything a machine emitted.
        static func machine(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
            .system(style, design: .monospaced, weight: weight)
        }

        /// For chrome: labels, controls, counts.
        static func chrome(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
            .system(style, design: .default, weight: weight)
        }
    }

    /// Body prose wants more leading in a serif than a sans.
    static let proseLineSpacing: CGFloat = 4
}

// MARK: - Building blocks

/// The animation every fold uses: opening a row, opening a turn, revealing the
/// earlier steps of a run.
///
/// Short and nearly straight-line. A fold is not an event to celebrate; it is the
/// screen catching up with what was just asked for.
///
/// Takes Reduce Motion rather than reading it, so the value comes from the
/// environment of the view doing the animating. A process-global read would work
/// once and then not notice the setting changing.
enum Motion {
    static func fold(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2)
    }
}

/// The paper's grain.
///
/// Generated once, from a fixed seed, so it is the same texture every launch: a
/// texture that changed would read as noise rather than as the surface you are
/// looking at. Kept to a few percent alpha, which is the difference between paper
/// with tooth and a screen with dirt on it.
enum PaperTexture {
    /// 48 device pixels, which is a repeat period small enough to read as tooth
    /// rather than as a pattern.
    static let tile: CGImage? = makeTile(side: 48)

    private static func makeTile(side: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        // A small linear congruential generator with a fixed seed. Deterministic is
        // the whole requirement; this is not for anything that needs randomness.
        var state: UInt32 = 0x9E37_79B9

        for index in stride(from: 0, to: pixels.count, by: 4) {
            state = 1_664_525 &* state &+ 1_013_904_223
            let value = Int((state >> 16) & 0xFF)

            // Black speckles, premultiplied so the value is legal: black with alpha
            // is (0, 0, 0, a). Storing a grey at alpha 1 — the first version of this
            // — is malformed premultiplied data, and CoreGraphics resolved it into a
            // uniform wash rather than grain.
            let alpha = value < 60 ? UInt8(value / 4) : 0
            pixels[index] = 0
            pixels[index + 1] = 0
            pixels[index + 2] = 0
            pixels[index + 3] = alpha
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// The surface a screen sits on: the paper colour, with its grain in light mode.
///
/// Applied to a screen's root and to anything that has to be opaque over scrolling
/// content — the transcript's pinned header and its composer — so no flat panel
/// shows as a seam beside grainy paper.
struct PaperBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    /// The tile is measured in device pixels, so it has to be told the scale it is
    /// being drawn at. At the wrong scale it is resampled, and grain that is
    /// resampled stops being grain and becomes a tint.
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                Theme.paper
                if colorScheme == .light, let tile = PaperTexture.tile {
                    Image(decorative: tile, scale: displayScale)
                        .resizable(resizingMode: .tile)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// The paper the transcript is written on.
    func paperBackground() -> some View {
        modifier(PaperBackground())
    }

    /// Glass for a control surface that content passes beneath.
    ///
    /// Tinted towards the palette rather than left clear, and the tint differs by
    /// appearance for a reason. Untinted over a transcript lets the rows behind ghost
    /// through at full contrast, so the control's own words compete with the
    /// conversation passing under them. In dark mode it does something worse: glass
    /// over pitch black resolves to a grey panel, which is a slab of light in an
    /// interface whose whole dark identity is the absence of one.
    ///
    /// So each appearance tints towards itself — paper in light, black in dark — and
    /// what is left of the material is the blur and the edge. That is the subtle
    /// version: you can tell something is moving underneath without being able to
    /// read it.
    ///
    /// Only for surfaces that float over scrolling content. Anywhere else there is
    /// nothing behind the glass to refract, and a material over a flat colour is
    /// decoration.
    func controlGlass() -> some View {
        modifier(ControlGlass())
    }

    /// Glass for a round control that floats over content.
    ///
    /// The same tint as the composer's bar, in a circle, and interactive: a button that
    /// carries its own material has to answer a finger itself, where the composer's
    /// buttons get that from `.buttonStyle(.glass)`.
    func circleGlass() -> some View {
        modifier(CircleGlass())
    }

    /// The recess a text field sits in.
    ///
    /// Depth rather than a line. A hairline under the field was a straight rule drawn
    /// on a material, and it read as an underscore laid over the glass and fought the
    /// panel's own edge. A shallow well instead: the field is delimited by appearing
    /// to be pressed into the surface, which is what a material like this can express.
    ///
    /// The gloss is a specular highlight along the top edge, fading before it reaches
    /// the bottom. A flat fill read as a hole cut out of the glass — sharp, with no
    /// light in it — and this is the same shape with the surface of it polished.
    func fieldWell() -> some View {
        modifier(FieldWell(shape: AnyShape(Capsule())))
    }

    /// The same recess, for writing more than one line.
    ///
    /// A capsule is the shape of a field that holds a phrase; a brief holds a
    /// paragraph, and a capsule around a paragraph is a pill with a sentence in it.
    /// The paint is shared, so the two read as the same kind of thing: a field is the
    /// one place this app fills a container, because a field is a container for words.
    func fieldArea() -> some View {
        modifier(FieldWell(shape: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))))
    }

    /// The block one voice speaks in.
    ///
    /// `.raised` for an agent's answer, `.pressed` for a person's question. Same shape, same width,
    /// same light — the only difference is which way it falls, which is all this app needs to say
    /// about who is talking.
    func messageBlock(_ depth: MessageBlock.Depth, cornerRadius: CGFloat = 12) -> some View {
        modifier(MessageBlock(depth: depth, cornerRadius: cornerRadius))
    }
}

/// The paint of a well: a recessed panel, tinted towards the ink in light and towards the light in
/// dark, with a polish along its top edge.
///
/// Shared rather than written twice, because the composer's field, the brief on the create sheet
/// and a question in the transcript are the same object — a place words go in. Three wells
/// differing by a few percent of tint would read as three different materials, and the transcript
/// asks you to believe they are one.
struct WellPaint: View {
    let shape: AnyShape

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        shape
            .fill(
                colorScheme == .dark
                    ? Color.white.opacity(0.06)
                    : Theme.ink.opacity(0.045)
            )
            .overlay {
                shape
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.22 : 0.9),
                                Color.white.opacity(colorScheme == .dark ? 0.04 : 0.15),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .blendMode(colorScheme == .dark ? .plusLighter : .normal)
            }
    }
}

private struct FieldWell: ViewModifier {
    let shape: AnyShape

    func body(content: Content) -> some View {
        content.background { WellPaint(shape: shape) }
    }
}

/// One voice's block: a sheet standing off the paper, or a well pressed into it.
///
/// Two shadows at opposite corners, and which way round they go is the whole of the difference
/// between the two voices. Light from the top left with the shade thrown to the bottom right reads
/// as a sheet raised off the page; the same two swapped read as a panel pushed into it. An agent's
/// answer is raised — it was produced for you — and a person's question is pressed, which is the
/// shape it arrived in: the same well the composer is, because that is where it was typed.
///
/// Neither is a card. A card is a container *for* structure and has an edge of its own; a block's
/// fill is the material it lies in, so the only thing marking where it begins is the light and no
/// line is drawn across the page. It is also the one depth treatment that cannot cost contrast —
/// the words stay ink on paper and all of the depth is outside them — which is what lets it carry
/// a whole answer without competing with the question it answers.
///
/// **On paper the shadows do the whole job. On black they cannot**: a shadow needs a surface to
/// fall on, and true black has none. So the dark blocks move themselves instead — the sheet rises
/// a step in its fill and the well sinks one — and the fill's own light says which is which. That
/// is the move `fieldWell` makes from the other direction, and for the same reason: a material
/// tells you about itself by where the light is.
struct MessageBlock: ViewModifier {
    enum Depth {
        /// An agent's answer: a sheet of the paper, standing off it.
        case raised
        /// A person's question: the paper pressed in, with the light under its near edge.
        case pressed
    }

    let depth: Depth
    var cornerRadius: CGFloat = 12

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    /// Subtle on purpose. A shadow you can point at has stopped being depth and become a drawing
    /// of a shadow; two points of offset under a six-point blur is a soft edge, and a soft edge is
    /// all a block needs to say which side of the paper it is on.
    private static let offset: CGFloat = 2
    private static let blur: CGFloat = 6

    /// How far the block reaches past the transcript's gutter — and, because the padding inside is
    /// the same number, how much of the page it takes from the margin rather than from the words.
    ///
    /// The gutter is `Theme.Space.loose` and `Theme.Space.base` of it is reclaimed, which leaves
    /// four points of margin on the narrowest phone this runs on. The payoff is that every voice
    /// starts on one left edge: a question, an answer, and the steps between them.
    private static let reach: CGFloat = Theme.Space.base

    func body(content: Content) -> some View {
        content
            .padding(Theme.Space.base)
            .background { block }
            // After the background, and that order is the whole trick: the panel is measured from
            // the words, and only then is the whole of it let out past the gutter. Reversed, the
            // panel shrinks and the words are left sitting outside their own block.
            .padding(.horizontal, -Self.reach)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var block: some View {
        ZStack {
            fill
            // The grain, so a block is the same paper rather than a smoother one. A texture that
            // stopped at an edge would read as a patch stuck to the page, which is worse than no
            // edge at all.
            if colorScheme == .light, let tile = PaperTexture.tile {
                Image(decorative: tile, scale: displayScale)
                    .resizable(resizingMode: .tile)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(shape)
        .shadow(color: far, radius: Self.blur, x: farOffset.x, y: farOffset.y)
        .shadow(color: near, radius: Self.blur, x: nearOffset.x, y: nearOffset.y)
    }

    @ViewBuilder private var fill: some View {
        if depth == .pressed {
            // A question and the field it was typed into are one object, so in the light they wear
            // one paint.
            if colorScheme == .dark {
                // On black there is no below-black to press into, so the block keeps the step
                // `surface` has always given a panel here. A well that cannot be pressed is only a
                // lighter panel — and then it should be a decisively lighter one, because a
                // question is the heavier of the two blocks in both appearances, and two panels
                // within a couple of percent of each other say nothing about who is talking.
                Theme.surface
            } else {
                WellPaint(shape: AnyShape(shape))
            }
        } else {
            Theme.paper
            if colorScheme == .dark {
                // A step up from black rather than a shadow on it, and deliberately short of
                // `surface`, so a code block inside an answer stays the lighter of the two.
                LinearGradient(
                    colors: [Color.white.opacity(0.07), Color.white.opacity(0.028)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    /// Where the light lands, as opposed to where it comes from. A raised block throws its shade
    /// away from the light; a well catches it under the near edge, which is the same shadow read
    /// the other way round.
    private var nearOffset: CGPoint {
        let d = Self.offset
        return depth == .raised ? CGPoint(x: -d, y: -d) : CGPoint(x: d, y: d)
    }

    private var farOffset: CGPoint {
        CGPoint(x: -nearOffset.x, y: -nearOffset.y)
    }

    /// The light. Nearly white in full on paper, which is nearly white already; on black the same
    /// white is a lamp, so it is a fiftieth of the strength.
    private var near: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.9)
    }

    /// The shade, thrown to the far corner. Ink rather than black: it is the only thing marking
    /// where a raised block ends, so it has to be findable without being seen. In the dark there is
    /// nothing to cast it on, so there is none, and the fill carries the depth alone.
    private var far: Color {
        colorScheme == .dark ? .clear : Theme.ink.opacity(0.12)
    }
}

private struct CircleGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        // `.interactive()` is the part that scales and shimmers under a finger, and it
        // is iOS only — the macOS build takes the material without the response.
        #if os(iOS)
        content.glassEffect(tint.interactive(), in: .circle)
        #else
        content.glassEffect(tint, in: .circle)
        #endif
    }

    private var tint: Glass {
        .regular.tint(
            colorScheme == .dark
                ? Color.black.opacity(0.55)
                : Theme.paper.opacity(0.82)
        )
    }
}

private struct ControlGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.glassEffect(
            .regular.tint(
                colorScheme == .dark
                    ? Color.black.opacity(0.55)
                    : Theme.paper.opacity(0.82)
            ),
            in: .rect(cornerRadius: 0)
        )
    }
}

/// A hairline. Structure in this app comes from rules rather than from boxes.
struct Rule: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.rule)
            .frame(height: 1 / displayScale)
            .accessibilityHidden(true)
    }
}

/// Something went wrong, said in the one voice this app has for failure.
///
/// Muted grey is the app's voice for an aside, and a failure is not an aside: the
/// two faults this replaced both rendered as the same quiet grey as "waiting for the
/// session", so a send that had failed read as a send still in progress.
///
/// The glyph takes the system's destructive red, which is the one hue this app is
/// allowed to borrow because it does not own it. The words stay in ink at reading
/// size: an error you have to lean in to read is an error you will misread.
struct FailureNote: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .frame(width: 14, alignment: .leading)
                .accessibilityHidden(true)

            Text(message)
                .font(Theme.Face.chrome(.callout))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}

/// Dims and brightens, which is how work in flight is shown.
///
/// The app's only non-user-triggered motion, and it answers a question the user is
/// actually asking: is anything happening? Off when Reduce Motion is on — and that
/// is not a loss, because the spine stays solid and still means "working".
struct WorkingPulse: ViewModifier {
    let isWorking: Bool
    /// How long one breath takes. Attention breathes faster than work, because the
    /// two are different questions: "is anything happening" and "does anything need
    /// me".
    var period: TimeInterval = 1.1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDim = false

    func body(content: Content) -> some View {
        content
            // A floor of 0.55 rather than 0.3: the spine is only three points
            // wide, and at 30% a working row reads as a missing one.
            .opacity(isWorking && isDim ? 0.55 : 1)
            // The animation follows the value instead of being started by an event. A
            // `repeatForever` begun in `onChange` keeps running after the reason for it is
            // gone — a row that goes on blinking for a task that stopped minutes ago — and
            // setting the value back without one does not reliably stop it. Attached to the
            // value, the pulse exists only while there is something to pulse for.
            .animation(
                isWorking && !reduceMotion
                    ? .easeInOut(duration: period).repeatForever(autoreverses: true)
                    : nil,
                value: isDim
            )
            .onChange(of: isWorking, initial: true) { _, working in
                isDim = working && !reduceMotion
            }
    }
}

extension View {
    func workingPulse(_ isWorking: Bool, period: TimeInterval = 1.1) -> some View {
        modifier(WorkingPulse(isWorking: isWorking, period: period))
    }
}

// MARK: - Colour from numbers

extension Color {
    /// A colour that answers the system's appearance.
    ///
    /// Written out rather than pulled from an asset catalog so the palette is
    /// reviewable in one place, and so a value cannot drift from its documented
    /// hex without a diff.
    init(light: UInt32, dark: UInt32) {
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #elseif os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
        #else
        self.init(red: Double((light >> 16) & 0xFF) / 255,
                  green: Double((light >> 8) & 0xFF) / 255,
                  blue: Double(light & 0xFF) / 255)
        #endif
    }
}

#if os(iOS)
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
#elseif os(macOS)
extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
