import Foundation

/// Whether the model server and the sandbox are ready, as far as the cards'
/// folding is concerned. `nil` means "in between" (the server is being
/// checked, the sandbox's protection is being verified): the cards leave
/// their folds alone until it is known.
public struct ResearchCardReadiness: Equatable, Sendable {
    public var server: Bool?
    public var sandbox: Bool?

    public init(server: Bool?, sandbox: Bool?) {
        self.server = server
        self.sandbox = sandbox
    }
}

/// Decides when the Model server card and the Web sandbox card fold and open
/// on their own, so a window where everything works shows just two title rows
/// and one where something is wrong shows the card with the problem.
///
/// - When both are ready, both fold once. If the person opens one while both
///   stay ready, it is left open.
/// - When one is not ready, its card opens, whatever the person chose, so the
///   problem is visible. The next time both are ready, both fold once again.
///
/// Whether a card is folded is kept by the window (it is remembered across
/// restarts); this type only says what it should become.
public struct ResearchCardFolding: Equatable, Sendable {
    /// Which cards are folded.
    public struct Folds: Equatable, Sendable {
        public var server: Bool
        public var sandbox: Bool

        public init(server: Bool, sandbox: Bool) {
            self.server = server
            self.sandbox = sandbox
        }
    }

    /// True after both cards were folded for the current stretch in which
    /// both are ready.
    private var foldedForThisSpell = false

    public init() {}

    /// The folds to use now. Call it whenever the readiness changes, with the
    /// folds as they are.
    public mutating func update(_ readiness: ResearchCardReadiness, folds: Folds) -> Folds {
        var folds = folds
        if readiness.server == false { folds.server = false }
        if readiness.sandbox == false { folds.sandbox = false }
        if readiness.server == false || readiness.sandbox == false {
            foldedForThisSpell = false
        } else if readiness.server == true, readiness.sandbox == true, !foldedForThisSpell {
            folds.server = true
            folds.sandbox = true
            foldedForThisSpell = true
        }
        return folds
    }
}
