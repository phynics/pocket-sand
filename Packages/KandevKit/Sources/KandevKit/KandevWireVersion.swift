/// The Kandev release line these wire types were written against.
///
/// Kandev calls `/ws` an internal protocol that can change without notice, so the
/// pin is deliberate: bumping it means re-reading the server, not just trusting a
/// newer build. Verified against the server reported by `GET /health`.
public enum KandevWireVersion {
    /// The release line every action in this module was checked against.
    public static let releaseLine = "0.96"

    /// The full version reported by the dev server when these types were verified.
    public static let verifiedServerVersion = "v0.96.0"

    /// The port a Kandev server listens on when it is not told otherwise.
    public static let defaultPort = 38429
}
