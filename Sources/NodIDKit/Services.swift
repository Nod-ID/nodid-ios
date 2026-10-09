// Nod ID SDK: the contract between the screens and the machinery behind them (M2).
// The screens and the flow state machine (UI side) only talk to `NodIDServices`. The real implementation (chip read, proving,
// network) is written separately; `MockServices` lets the whole flow run without a passport.
// RULES: passport data (MRZ values, DG1, SOD) lives in memory only, is never logged, never printed, never persisted,
// and is wiped (overwritten) after the proof. Nothing in this file may print or store it.
import Foundation

/// What the member typed or the camera read from the two lines at the bottom of the photo page. In memory only.
public struct MRZData {
    public var documentNumber: String      // 6 to 9 letters or digits
    public var birthYYMMDD: String         // six digits
    public var expiryYYMMDD: String        // six digits
    public var issuingState: String?       // three letters from line 1, characters 3 to 5; nil when typed by hand
    public init(documentNumber: String, birthYYMMDD: String, expiryYYMMDD: String, issuingState: String?) {
        self.documentNumber = documentNumber; self.birthYYMMDD = birthYYMMDD; self.expiryYYMMDD = expiryYYMMDD; self.issuingState = issuingState
    }
}

/// The three places the chip can be read from (decision 31, `core/src/placement.rs`).
public enum PlacementSpot: String, CaseIterable { case backCover = "back_cover", photoPage = "photo_page", frontCover = "front_cover" }

/// What the host's backend configured for this verification. Fetched with the session id; no secret in it.
public struct SessionPolicy {
    public var appName: String
    public var accentHex: String           // host accent, light mode, like "#7B2D5B"
    public var minAge: Int                 // 0 when the age check is off
    public var checkAge: Bool
    public var checkExpiry: Bool
    public var checkCountry: Bool
    public var helpURL: URL?
    public var onePerPerson: Bool          // the app allows one account per person: the intro says "This is your only account"
    public var offerDigitalId: Bool        // show the Wallet option (decisions 14, 21); the app's dashboard sets it
    public var alternatives: [Alternative] // other ways the app accepts, for screen 08b
    public struct Alternative { public var title: String; public var detail: String
        public init(title: String, detail: String) { self.title = title; self.detail = detail } }
    public init(appName: String, accentHex: String, minAge: Int, checkAge: Bool, checkExpiry: Bool, checkCountry: Bool, helpURL: URL?,
                offerDigitalId: Bool = false, onePerPerson: Bool = false, alternatives: [Alternative] = []) {
        self.onePerPerson = onePerPerson; self.offerDigitalId = offerDigitalId; self.alternatives = alternatives
        self.appName = appName; self.accentHex = accentHex; self.minAge = minAge; self.checkAge = checkAge
        self.checkExpiry = checkExpiry; self.checkCountry = checkCountry; self.helpURL = helpURL
    }
}

/// Chip read progress, for screens 05a and the NFC sheet text. Phase names and numbers only; never passport data.
public enum ChipProgress { case waiting, authenticating, reading(percent: Int), done }

/// Why a chip read failed. `keyMismatch` = the typed or scanned details do not open the chip (screen 07i).
public enum ChipFailure: Error { case cancelled, keyMismatch, chipNotFound, tagLost, unsupported, other }

/// Opaque handle to the chip data held in memory. Real implementation keeps DG1/SOD inside; `wipe()` overwrites them.
public protocol ChipHandle: AnyObject { func wipe() }

/// Steps of screen 06, in order.
public enum ProofStep { case passportRead, checkingRules, makingProof }

/// A reason the member is not verified. Shown to the member only (rule 7); the host app only learns "not verified".
public enum NotVerifiedReason { case expired, underage, countryNotAllowed, alreadyUsed, technical }

public enum ProofResult {
    case verified(reference: String)                 // reference for the receipt, "NOD-XXXX-XXXX"
    case notVerified(NotVerifiedReason)
}

public protocol NodIDServices: AnyObject {
    /// Best-first order of spots to try for an issuing state (nil = unknown). Wraps `nodid_core::placement`.
    func placementOrder(issuingState: String?) -> [PlacementSpot]
    func fetchPolicy(sessionId: String) async throws -> SessionPolicy
    /// Reads DG1 and SOD over NFC. Throws `ChipFailure`. Calls `onProgress` on any thread.
    func readChip(mrz: MRZData, onProgress: @escaping (ChipProgress) -> Void) async throws -> ChipHandle
    /// Checks the rules on the phone, makes the proof, sends it. Wipes the chip data when it returns or throws.
    func prove(chip: ChipHandle, sessionId: String, onStep: @escaping (ProofStep) -> Void) async throws -> ProofResult
    /// Tells the verifier the member cancelled or the flow broke ("cancelled" or "technical_error"), so the app's usage counts are right.
    /// Best effort; carries no reason and no passport data. Only an open session can be closed this way.
    func report(sessionId: String, outcome: String) async
    /// Called as soon as the flow opens, on a background task: gets the proving system ready (loads the shared SRS file) while the member reads and
    /// scans, so the first proof does not wait for it. Must be safe to call more than once and must never fail loudly.
    func warmUp() async
    /// Makes sure the proving resources are on the phone (a one-time download when they are not shipped in the app). `progress` is 0 to 100.
    func resourcesReady(progress: @escaping (Int) -> Void) async throws
}

public extension NodIDServices {
    func report(sessionId: String, outcome: String) async {}
    func warmUp() async {}
    func resourcesReady(progress: @escaping (Int) -> Void) async throws {}
}

/// Runs the whole flow with timers and no passport (for previews and UI tests).
public final class MockServices: NodIDServices {
    public var outcome: ProofResult = .verified(reference: "NOD-TEST-0000")
    public var chipError: ChipFailure? = nil
    public init() {}
    public func placementOrder(issuingState: String?) -> [PlacementSpot] {
        switch issuingState { case "USA": return [.backCover, .photoPage, .frontCover]
        case "GBR", "NLD", "SWE", "FIN", "NOR", "DNK": return [.photoPage, .backCover, .frontCover]
        default: return [.frontCover, .backCover, .photoPage] }
    }
    public func fetchPolicy(sessionId: String) async throws -> SessionPolicy {
        SessionPolicy(appName: "Haven", accentHex: "#7B2D5B", minAge: 18, checkAge: true, checkExpiry: true, checkCountry: false, helpURL: nil)
    }
    final class Handle: ChipHandle { func wipe() {} }
    public func readChip(mrz: MRZData, onProgress: @escaping (ChipProgress) -> Void) async throws -> ChipHandle {
        onProgress(.waiting); try await Task.sleep(nanoseconds: 1_500_000_000)
        if let e = chipError { throw e }
        onProgress(.authenticating)
        for p in stride(from: 0, through: 100, by: 10) { onProgress(.reading(percent: p)); try await Task.sleep(nanoseconds: 300_000_000) }
        onProgress(.done); return Handle()
    }
    public func prove(chip: ChipHandle, sessionId: String, onStep: @escaping (ProofStep) -> Void) async throws -> ProofResult {
        onStep(.passportRead); try await Task.sleep(nanoseconds: 800_000_000)
        onStep(.checkingRules); try await Task.sleep(nanoseconds: 800_000_000)
        onStep(.makingProof); try await Task.sleep(nanoseconds: 3_000_000_000)
        chip.wipe(); return outcome
    }
}
