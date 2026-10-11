// Nod ID SDK: the debug setup checker (quickstart, decision 55). Compiled in DEBUG builds only. Prints one block, once per launch,
// prefixed `[NodID setup]`, through os_log (public). Never prints key material beyond the fixed prefixes, never passport data.
// The provisioning profile is read-only, in Debug on a device only; nothing in it is sent anywhere.
#if DEBUG
import Foundation
import os

enum NodIDSetupCheck {
    struct Environment {
        var info: [String: Any]
        var entitlements: [String: Any]?   // nil = could not be read (Simulator, or no embedded profile)
        var isSimulator: Bool
    }

    static let requiredAIDs = ["A0000002471001", "A0000002472001", "00000000000000"]
    static let nfcPlist = "Info.plist is missing NFCReaderUsageDescription. Add: \"Reads your passport chip on this phone to prove you are a real adult. Nothing is sent or stored.\" (Live mode on a real iPhone only.)"
    static let cameraPlist = "Info.plist is missing NSCameraUsageDescription. Add a sentence that says the camera view is never recorded."
    static let aidsPlist = "Add A0000002471001, A0000002472001 and 00000000000000 to com.apple.developer.nfc.readersession.iso7816.select-identifiers."
    static let nfcCapability = "Add the \"Near Field Communication Tag Reading\" capability: Xcode > target > Signing & Capabilities > + Capability. Entitlement com.apple.developer.nfc.readersession.formats must contain TAG."
    static let appAttest = "Add the App Attest capability and list TEAMID.bundle.id in the dashboard."
    static let testOK = "Test mode: no setup needed beyond the key."
    static let liveInSimulator = "Live mode needs a real iPhone (NFC does not work in the Simulator). To try Nod ID in the Simulator use your test key: nod_pk_test_..."
    static let liveOK = "Setup looks complete for live mode."

    /// `key` is the test key string when the flow runs in test mode, nil for a live session id.
    static func messages(key: String?, env: Environment) -> [String] {
        if let key {
            switch NodIDTestKey.classify(key) {
            case .test: return [testOK]
            case .secret: return [NodIDKeyText.secret]
            case .placeholder: return [NodIDKeyText.placeholder]
            case .mistyped: return [NodIDKeyText.mistyped]
            case .unsupportedPublishable: return [NodIDKeyText.liveKey]
            case .notAKey: return [NodIDKeyText.notAKey]
            }
        }
        if env.isSimulator { return [liveInSimulator] }
        var out: [String] = []
        if (env.info["NFCReaderUsageDescription"] as? String)?.isEmpty ?? true { out.append(nfcPlist) }
        if (env.info["NSCameraUsageDescription"] as? String)?.isEmpty ?? true { out.append(cameraPlist) }
        let aids = env.info["com.apple.developer.nfc.readersession.iso7816.select-identifiers"] as? [String] ?? []
        if !requiredAIDs.allSatisfy({ aids.contains($0) }) { out.append(aidsPlist) }
        if let ent = env.entitlements {
            let formats = ent["com.apple.developer.nfc.readersession.formats"] as? [String] ?? []
            if !formats.contains("TAG") { out.append(nfcCapability) }
            if ent["com.apple.developer.devicecheck.appattest-environment"] == nil { out.append(appAttest) }
        }
        return out.isEmpty ? [liveOK] : out
    }

    /// The Entitlements dictionary inside an `embedded.mobileprovision` (a CMS blob with an XML plist in it). Read-only parse; nil when not found.
    static func entitlements(fromProvisioningProfile data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else { return nil }
        return obj["Entitlements"] as? [String: Any]
    }

    private static func currentEnvironment() -> Environment {
        #if targetEnvironment(simulator)
        let sim = true
        #else
        let sim = false
        #endif
        var ent: [String: Any]?
        if !sim, let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"), let d = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            ent = entitlements(fromProvisioningProfile: d)
        }
        return Environment(info: Bundle.main.infoDictionary ?? [:], entitlements: ent, isSimulator: sim)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var done = false

    /// Prints the block once per launch. `key` as in `messages`.
    static func runOnce(key: String?) {
        lock.lock(); let already = done; done = true; lock.unlock()
        if already { return }
        let log = Logger(subsystem: "app.nodid.sdk", category: "setup")
        for line in messages(key: key, env: currentEnvironment()) { log.info("[NodID setup] \(line, privacy: .public)") }
    }
}
#endif
