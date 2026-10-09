// Nod ID SDK: the member-flow state machine (design README, "Interactions and state").
// Talks to the machinery only through `NodIDServices`. MRZ values live here, in memory, and are cleared when the flow
// ends or is cancelled. Nothing in this file prints, logs or stores passport data.
import AVFoundation
import Observation
import SwiftUI
import UIKit

enum FlowFailure: Equatable {
    case chipUnreadable      // 07b and the first-class unreadable-chip fallback
    case keyMismatch         // 07i
    case camDenied           // 07h
    case expired             // 07c
    case underage            // 07d
    case used                // 07e
    case country             // 07f
    case technical
}

enum FlowScreen: Equatable {
    case loading
    case intro, need, prime
    case scan, manual
    case placement           // 05a, with `nfc` sub-state (nfcSearch / nfcRead / nfcCloser / nfcHold / nfcDone)
    case proving             // 06 and 06b (`provingLong`)
    case success, receipt    // 07a, 09
    case failure(FlowFailure)
    case cancelled           // 07g
    case digitalId           // 08a (stub)
    case noPassport          // 08b (stub)
}

enum NFCUIState: Equatable {
    case idle, searching, reading(Int), closer, hold(Int), done
    var message: String? {
        switch self {
        case .idle: return nil
        case .searching: return "Hold your iPhone near your passport."
        case .reading: return "Reading your passport. Keep still."
        case .closer: return nil   // filled in by the screen with the spot's text
        case .hold: return "Almost done. Keep holding."
        case .done: return "Passport read. Making your proof next."
        }
    }
}

@MainActor @Observable
final class NodIDFlowModel {
    // MARK: observable state
    private(set) var screen: FlowScreen = .loading
    private(set) var policy: SessionPolicy?
    private(set) var nfc: NFCUIState = .idle
    private(set) var provingLong = false
    private(set) var proofStep: ProofStep? = nil
    /// 0 to 100 while the proving resources are being downloaded for the first time (nil otherwise).
    private(set) var downloadPercent: Int?
    private(set) var spotOrder: [PlacementSpot] = PlacementSpot.allCases
    private(set) var spotOffset = 0
    private(set) var scanCaptured = false
    private(set) var cameraUnavailable = false
    private(set) var reference: String?
    private(set) var receiptDate = Date()
    private(set) var mrzTyped = false
    /// How many times the chip could not be read in this flow (not counting cancels or wrong typed details) and why the last one failed: the
    /// unreadable-chip screen gets more specific help on the second try, and a phone without NFC goes straight to the other options.
    private(set) var chipAttempts = 0
    private(set) var lastChipFailure: ChipFailure?
    // Manual entry (04c). In memory only.
    var docNumber = ""
    var birthDate = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    var expiryDate = Calendar.current.date(byAdding: .year, value: 5, to: Date()) ?? Date()
    var docNumberTouched = false
    /// Issuing state picked by hand (three letters), so the placement guide can pick the right spot. nil = not chosen.
    var issuingChoice: String?

    @ObservationIgnored let services: NodIDServices
    @ObservationIgnored let sessionId: String
    @ObservationIgnored private let onFinish: (NodIDOutcome) -> Void
    @ObservationIgnored private var mrz: MRZData?
    @ObservationIgnored private var chip: ChipHandle?
    @ObservationIgnored private var chipTask: Task<Void, Never>?
    @ObservationIgnored private var proveTask: Task<Void, Never>?
    @ObservationIgnored private var longTask: Task<Void, Never>?
    @ObservationIgnored private var closerTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var finished = false
    @ObservationIgnored let scanner = MRZScanner()
    @ObservationIgnored private var cameraKnownGood = false

    init(sessionId: String, services: NodIDServices, onFinish: @escaping (NodIDOutcome) -> Void) {
        self.sessionId = sessionId; self.services = services; self.onFinish = onFinish
    }

    // MARK: derived
    var app: String { policy?.appName ?? "this app" }
    var minAge: Int { policy?.minAge ?? 18 }
    var showAge: Bool { (policy?.checkAge ?? true) && minAge > 0 }
    var lockDismiss: Bool { screen == .proving || (screen == .placement && nfc != .idle) }
    var currentSpot: PlacementSpot { spotOrder[spotOffset % spotOrder.count] }
    var spotNumber: Int { spotOffset % spotOrder.count + 1 }
    var manualValid: Bool { docNumberError == nil && !docNumber.isEmpty && birthError == nil && expiryError == nil }
    var docNumberError: String? {
        guard !docNumber.isEmpty || docNumberTouched else { return nil }
        let ok = (6...9).contains(docNumber.count) && docNumber.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return ok ? nil : "Passport numbers have 6 to 9 letters and numbers. It's the first part of the second line."
    }
    var birthError: String? {
        birthDate >= Date() || birthDate < (Calendar.current.date(from: DateComponents(year: 1900)) ?? .distantPast)
            ? "Check the date of birth. It's the 6 digits after the country code, year first." : nil
    }
    var expiryError: String? { expiryDate <= birthDate ? "The expiry date can't be before the date of birth." : nil }

    // MARK: start
    func start() {
        guard screen == .loading else { return }
        let warm = services
        Task.detached(priority: .utility) { await warm.warmUp() }   // SRS ready before proving starts
        Task { [weak self] in
            guard let self else { return }
            do {
                let p = try await services.fetchPolicy(sessionId: sessionId)
                policy = p
                go(.intro)
            } catch {
                go(.failure(.technical))
            }
        }
    }

    func retryLoad() { screen = .loading; start() }

    // MARK: navigation
    func go(_ s: FlowScreen) {
        if screen == .scan, s != .scan { stopScanner() }
        if screen == .placement, s != .placement { stopChip() }
        screen = s
        UIAccessibility.post(notification: .screenChanged, argument: nil)
        if s == .scan { startScanner() }
        if s == .placement { enterPlacement() }
    }

    var backTarget: FlowScreen? {
        switch screen {
        case .need: return .intro
        case .prime: return .need
        case .scan: return .prime
        case .manual: return .scan
        case .placement: return mrzTyped ? .manual : .scan
        case .receipt: return .success
        case .digitalId, .noPassport: return .intro
        default: return nil
        }
    }
    func back() { if let t = backTarget { go(t) } }
    var showClose: Bool { screen != .loading }

    /// Close (xmark). From result screens it returns to the host; elsewhere it shows 07g first.
    func close() {
        switch screen {
        case .success, .receipt: finish(.verified)
        case .failure(.technical): finish(.technicalError)
        case .failure(.expired), .failure(.underage), .failure(.used), .failure(.country): finish(.notVerified)
        case .cancelled: finish(.cancelled)
        case .loading: finish(.cancelled)
        default: cancelWork(); wipe(); go(.cancelled)
        }
    }

    func restart() { cancelWork(); wipe(); go(.intro) }
    func backToHost(_ o: NodIDOutcome) { finish(o) }

    func finish(_ o: NodIDOutcome) {
        guard !finished else { return }
        finished = true
        cancelWork(); wipe()
        switch o {
        case .cancelled: let (svc, id) = (services, sessionId); Task { await svc.report(sessionId: id, outcome: "cancelled") }
        case .technicalError: let (svc, id) = (services, sessionId); Task { await svc.report(sessionId: id, outcome: "technical_error") }
        default: break
        }
        onFinish(o)
    }

    // MARK: camera
    func continueFromPrime() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: go(.scan)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in self?.go(granted ? .scan : .failure(.camDenied)) }
            }
        default: go(.failure(.camDenied))
        }
    }

    func recheckCamera() {
        if screen == .failure(.camDenied), AVCaptureDevice.authorizationStatus(for: .video) == .authorized { go(.scan) }
    }

    func openSettings() {
        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
    }

    /// Goes to the scan screen (or the permission screen when the camera is off).
    func scanOrPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: go(.scan)
        case .notDetermined: go(.prime)
        default: go(.failure(.camDenied))
        }
    }

    private func startScanner() {
        scanCaptured = false; cameraUnavailable = false
        scanner.onRead = { [weak self] data in
            Task { @MainActor in self?.scanned(data) }
        }
        scanner.onUnavailable = { [weak self] in Task { @MainActor in self?.cameraUnavailable = true } }
        scanner.start()
    }
    private func stopScanner() {
        scanner.onRead = nil; scanner.onUnavailable = nil
        scanner.stop()
    }
    private func scanned(_ data: MRZData) {
        guard screen == .scan, !scanCaptured else { return }
        mrz = data; mrzTyped = false; scanCaptured = true
        UIAccessibility.post(notification: .announcement, argument: "Got it. Next, hold your iPhone near your passport.")
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self, self.screen == .scan else { return }
            self.go(.placement)
        }
    }
    func setTorch(_ on: Bool) { scanner.setTorch(on) }

    // MARK: manual entry
    func continueFromManual() {
        docNumberTouched = true
        guard manualValid else { return }
        let cal = Calendar(identifier: .gregorian)
        func yymmdd(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return String(format: "%02d%02d%02d", (c.year ?? 0) % 100, c.month ?? 0, c.day ?? 0)
        }
        mrz = MRZData(documentNumber: docNumber.uppercased(), birthYYMMDD: yymmdd(birthDate), expiryYYMMDD: yymmdd(expiryDate), issuingState: issuingChoice)
        mrzTyped = true
        go(.placement)
    }

    // MARK: placement and chip
    private func enterPlacement() {
        var order = services.placementOrder(issuingState: mrz?.issuingState)
        for s in PlacementSpot.allCases where !order.contains(s) { order.append(s) }
        spotOrder = Array(order.prefix(3)); spotOffset = 0
        startChip()
    }
    /// "Try Again" after an unreadable chip: back to the guidance with the next spot suggested, or to the scan when nothing is held.
    func retryChip() {
        guard mrz != nil else { scanOrPermission(); return }
        let next = spotOffset + 1
        go(.placement)
        spotOffset = next % spotOrder.count
    }
    /// "Try Again" on the technical-error screen.
    func retryTechnical() { if policy == nil { retryLoad() } else { scanOrPermission() } }
    func nextSpot() { spotOffset = (spotOffset + 1) % spotOrder.count }

    func startChip() {
        guard let mrz else { go(.failure(.technical)); return }
        stopChip()
        setNFC(.searching)
        scheduleCloser()
        let data = mrz
        chipTask = Task { [weak self] in
            guard let self else { return }
            do {
                let handle = try await services.readChip(mrz: data) { [weak self] p in
                    Task { @MainActor in self?.apply(p) }
                }
                if Task.isCancelled { handle.wipe(); return }
                chip = handle
                clearMRZ()
                setNFC(.done)
                try? await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                startProving()
            } catch let f as ChipFailure {
                if Task.isCancelled { return }
                chipFailed(f)
            } catch {
                if Task.isCancelled { return }
                chipFailed(.other)
            }
        }
    }

    private func stopChip() {
        chipTask?.cancel(); chipTask = nil
        closerTask?.cancel(); closerTask = nil
        if screen == .placement { nfc = .idle }
    }

    private func apply(_ p: ChipProgress) {
        guard screen == .placement, chipTask != nil else { return }
        switch p {
        case .waiting: if nfc == .idle || nfc == .searching || nfc == .closer { setNFC(nfc == .closer ? .closer : .searching) }
        case .authenticating: closerTask?.cancel(); setNFC(.reading(0))
        case .reading(let pct): closerTask?.cancel(); setNFC(pct >= 82 ? .hold(pct) : .reading(pct))
        case .done: setNFC(.done)
        }
    }

    private func scheduleCloser() {
        closerTask?.cancel()
        closerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, self.nfc == .searching else { return }
            self.setNFC(.closer)
        }
    }

    private func setNFC(_ s: NFCUIState) {
        let old = nfc
        nfc = s
        // VoiceOver announcement only when the sentence changes (not on every percent).
        func key(_ x: NFCUIState) -> Int { switch x { case .idle: return 0; case .searching: return 1; case .reading: return 2; case .closer: return 3; case .hold: return 4; case .done: return 5 } }
        guard key(old) != key(s) else { return }
        let text: String? = s == .closer ? closerText : s.message
        if let text { UIAccessibility.post(notification: .announcement, argument: text) }
    }

    var closerText: String { Placement.text(for: currentSpot).closer }

    private func chipFailed(_ f: ChipFailure) {
        closerTask?.cancel()
        switch f {
        case .cancelled: nfc = .idle                      // back to the guidance, the member can try again
        case .keyMismatch: nfc = .idle; go(.failure(mrzTyped ? .keyMismatch : .chipUnreadable))
        default: nfc = .idle; chipAttempts += 1; lastChipFailure = f; go(.failure(.chipUnreadable))
        }
    }

    // MARK: proving
    private func startProving() {
        guard let handle = chip else { go(.failure(.technical)); return }
        go(.proving)
        provingLong = false; proofStep = .passportRead
        longTask?.cancel()
        longTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.provingLong = true
        }
        proveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await services.resourcesReady { [weak self] p in Task { @MainActor in self?.downloadPercent = p } }
                downloadPercent = nil
                let result = try await services.prove(chip: handle, sessionId: sessionId) { [weak self] step in
                    Task { @MainActor in self?.proofStep = step }
                }
                if Task.isCancelled { return }
                proofEnded(result)
            } catch {
                if Task.isCancelled { return }
                proofEnded(.notVerified(.technical))
            }
        }
    }

    private func proofEnded(_ r: ProofResult) {
        longTask?.cancel(); longTask = nil
        chip?.wipe(); chip = nil
        proofStep = nil; provingLong = false; downloadPercent = nil
        switch r {
        case .verified(let ref): reference = ref; receiptDate = Date(); go(.success)
        case .notVerified(let why):
            switch why {
            case .expired: go(.failure(.expired))
            case .underage: go(.failure(.underage))
            case .countryNotAllowed: go(.failure(.country))
            case .alreadyUsed: go(.failure(.used))
            case .technical: go(.failure(.technical))
            }
        }
    }

    // MARK: cleanup
    private func cancelWork() {
        chipTask?.cancel(); proveTask?.cancel(); longTask?.cancel(); closerTask?.cancel(); captureTask?.cancel()
        chipTask = nil; proveTask = nil; longTask = nil; closerTask = nil; captureTask = nil
        stopScanner()
        provingLong = false; proofStep = nil; nfc = .idle
    }

    private func clearMRZ() {
        if var m = mrz { m.documentNumber = ""; m.birthYYMMDD = ""; m.expiryYYMMDD = ""; m.issuingState = nil; mrz = m }
        mrz = nil
    }

    /// Overwrites everything the member typed or the camera read, and wipes the chip handle.
    func wipe() {
        clearMRZ()
        docNumber = ""; docNumberTouched = false; issuingChoice = nil
        birthDate = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
        expiryDate = Calendar.current.date(byAdding: .year, value: 5, to: Date()) ?? Date()
        mrzTyped = false; chipAttempts = 0; lastChipFailure = nil
        chip?.wipe(); chip = nil
    }

    func viewDisappeared() {
        if !finished { cancelWork(); wipe() }
    }
}

extension NodIDFlowModel {
    /// Previews and the gallery: jump straight to a state without running services (never called by the real flow).
    func previewShow(_ s: FlowScreen, nfc n: NFCUIState = .idle, long: Bool = false, step: ProofStep? = nil, spotOffset off: Int = 0, order: [PlacementSpot]? = nil,
                     accent: String = "#7B2D5B", checkCountry: Bool = true, onePerPerson: Bool = false, offerDigitalId: Bool = false,
                     alternatives: [SessionPolicy.Alternative] = [], attempts: Int = 0, lastFailure: ChipFailure? = nil, download: Int? = nil) {
        policy = SessionPolicy(appName: "Haven", accentHex: accent, minAge: 18, checkAge: true, checkExpiry: true, checkCountry: checkCountry, helpURL: URL(string: "https://example.com/help"),
                               offerDigitalId: offerDigitalId, onePerPerson: onePerPerson, alternatives: alternatives)
        screen = s; nfc = n; provingLong = long; proofStep = step; spotOffset = off
        chipAttempts = attempts; lastChipFailure = lastFailure; downloadPercent = download
        if let order { spotOrder = order }
        reference = "NOD-TEST-0000"
    }
}
