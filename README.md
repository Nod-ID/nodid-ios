# Nod ID iOS SDK: integrate in an iOS app (about an hour)

Your app shows one sheet. The member's iPhone reads the passport chip and makes the proof. Your backend gets yes/no and a person code. You never receive an ID.
Needs: Xcode 16+, iOS 17+, a **real iPhone** (NFC does not work in the simulator), a Nod ID app key from us. A working example is in `sdk-ios/Sample/`.

**1. Add the package.** Xcode, File > Add Package Dependencies, enter `https://github.com/Nod-ID/nodid-ios`, version rule "Exact" or "Up to next minor" from the release you were given, product **NodIDKit**, then `import NodIDKit`. The Rust proving core comes as a prebuilt binary (checked against a checksum in `Package.swift`). (Working in the Nod ID repository itself: add the local folder `sdk-ios/NodIDKit` and run `scripts/sdk-package.sh` once.)

**2. Turn on the phone features.**
- Signing & Capabilities: add **Near Field Communication Tag Reading**. Entitlement `com.apple.developer.nfc.readersession.formats` = `TAG`.
- Info.plist: `NFCReaderUsageDescription`, `NSCameraUsageDescription` (your own words, say it stays on the phone), and `com.apple.developer.nfc.readersession.iso7816.select-identifiers` = `A0000002471001`, `A0000002472001`, `00000000000000`.

**3. Proving resources (circuits, keys, SRS, CSCA files).** Release builds of the package download what a member's passport needs once, into the app's Application Support folder (not backed up). Every file is checked against a manifest whose SHA-256 is built into the SDK release, so the download host cannot change what runs. Files come from `nodid.app/sdk/<version>/` and, if that is unreachable, from the GitHub release. Up to four files download at once, and a stopped download continues where it stopped. The shared files (SRS, keys, CSCA data) are about 34 MB; each passport then needs only its own two or three circuits (4 to 15 MB), so a typical first run is about 40 MB, not the full 135 MB set. Nothing about the member is uploaded.

**Call `NodID.prefetch()` at app launch** so the files are ready before a member ever opens the flow:
```swift
// in application(_:didFinishLaunchingWithOptions:) or your App's init
NodID.prefetch()                      // waits for Wi-Fi (default)
// NodID.prefetch(allowCellular: true) // also over mobile data
```
It returns at once and downloads in the background: the shared files plus the circuits most passports use (P-256 and RSA-2048), about 46 MB. A passport that needs a different circuit fetches just that one when it is scanned (a few MB). It does nothing when the files are already on the phone. If the app is closed first, the next launch continues. If a member opens the flow before it finishes, the flow completes the download over any network and shows "Getting ready for the first time" with a percentage that follows the bytes. Without `prefetch()`, the flow starts the download when it opens (Wi-Fi only until the proof needs it).

To ship the files inside your app instead (no download), add the resources folder from the release to your app target as a **group**, not a folder reference, so the files sit flat; or pass `RealServices(resources: url)`. Development builds of the package (this repository) expect the bundled folder.

**3b. Turn on App Attest (SDK 0.2.0 and later).** Every proof is signed with an Apple App Attest assertion that shows it came from your genuine app. In Xcode, Signing & Capabilities, add **App Attest** (entitlement `com.apple.developer.devicecheck.appattest-environment`; Xcode sets `development` for debug builds and `production` for App Store and TestFlight builds). Then, in the dashboard, open your app's Checks page and add your App ID under **App Attest**, written `TEAMID.bundle.id` (Team ID from your Apple Developer account, for example `ABCDE12345.com.example.haven`). Apps start in **test mode**, where App Attest may be skipped and development builds are accepted. When your released app has the capability, turn test mode off: from then on a verification without a valid App Attest check comes back as `not_verified`, and development-signed builds no longer verify. The SDK attests once per install (about 1.5 s, done beside the proving) and signs each proof in about 30 ms. It works only on a real iPhone. A reinstall or a restored device makes a new key by itself. SDK 0.1.x does not send App Attest; the verifier accepts it for a limited time that we announce, and records it in the evidence log as `legacy`.

**4. Stop the OS saving screens.** Two lines in your `UIApplicationDelegate` (SwiftUI: `@UIApplicationDelegateAdaptor`):
```swift
func application(_ a: UIApplication, shouldSaveSecureApplicationState c: NSCoder) -> Bool { NodID.disableStateRestoration() }
func application(_ a: UIApplication, shouldRestoreSecureApplicationState c: NSCoder) -> Bool { NodID.disableStateRestoration() }
```
The SDK covers the app-switcher snapshot and turns off keyboard learning on its own fields.

**5. Your backend creates the session.** The secret key never goes in the app.
```
POST https://api.nodid.app/v1/sessions        Authorization: Bearer <your secret key>
-> {"sessionId":"...","nonce":"...","expiresAt":...}      (single use, expires in minutes)
```
Send only `sessionId` to the app.

**6. Show the sheet.**
```swift
.sheet(isPresented: $show) {
    NodIDVerifyView(sessionId: id) { outcome in   // .verified / .notVerified / .cancelled / .technicalError
        show = false
    }.presentationDetents([.large])
}
```
The app learns only the outcome. Reasons (under age, country, expired, already used) are shown to the member and never to you.

**7. Confirm on your backend before you trust it.**
```
GET https://api.nodid.app/v1/sessions/<sessionId>/result    Authorization: Bearer <your secret key>
-> {"outcome":"verified","assurance":"substantial","unique":true,"personCode":"...","method":"passport_nfc",
    "versions":{"circuit":"...","vk":"...","dscTree":"...","sdk":"0.2.0"}}     (202 while pending)
```
- `outcome`: `verified`, `not_verified`, `cancelled` or `technical_error`.
- `assurance`: how sure the method makes us. `substantial` for a passport proof today; `high` (passport and face match) and `basic` (an OS age signal or estimation) come with those methods. Only present when verified.
- `unique`: `true` only for passport methods. `personCode` is present only when `unique` is `true`.
- `method`: `passport_nfc` today.
- `versions`: the circuit, key, certificate-tree and SDK versions that made the result. Keep them with the result.
- In the dashboard you can set a **minimum assurance** and whether a **unique person is required**, per app. A result below your minimum comes back as `not_verified`, with no reason.

`personCode` is stable for the same person in your app and cannot be matched across other apps. Use it for one-account-per-person.

**Evidence log.** The dashboard's Evidence tab shows one entry per verification (time, method, versions, assurance, outcome, App Attest result, a hash of the proofs), each chained to the one before. Export it as JSON or CSV and verify the chain there or yourself (the hash definition is in the tab). Entries hold no country, identity data, address or person code. Kept 13 months.

**What you configure per app** (name, accent colour, minimum age, expiry and country checks, country list, help link, digital ID on/off, other ways to prove): in the dashboard at dashboard.nodid.app. Sign in with your email (no password), create an app, set the checks, create a secret key (shown once), and use **Run a test verification** to get a test session id; paste it into the Sample app (or pass it to `NodIDVerifyView`) and the dashboard shows the outcome. Usage shows counts of the four outcomes only.

**Limits today.** Device only (no simulator). Passports whose signing certificates are larger than 2,048 bytes, or from countries not yet in the coverage table (`docs/COUNTRY_COVERAGE.md`), show the member a clear "can't accept this passport yet" screen. "Verify with Wallet" is shown only when your app has it switched on, and does nothing until Apple approves us for it.

**8. Treat the person code as a "likely same person" signal.** The person code is stable for the same name (as printed in the passport's machine-readable zone), date of birth and nationality, and is different for every app of yours. It is not proof of identity, and two different people can, rarely, share one (same name, birth date and nationality). So:
- When a code you already hold comes back for a new account, **do not ban and do not merge automatically.** Show a soft message ("This person may already have an account") and offer **contact support** or **link accounts**. A person wrongly locked out is a worse outcome than a rare duplicate.
- The code **changes** when the name on the passport changes (marriage, legal change, different spelling or transliteration, a middle name added or dropped) or the nationality changes. A renewed passport with the same details gives the same code. Someone holding passports from two countries gets two codes.
- **Re-verify and link** (for a name change, or a second passport): let a signed-in member verify again from inside their account, and when the new code differs from the one you stored for them, store it as a second code for the same member instead of treating it as a new person. Do this only from an authenticated session, and still route a code that matches a *different* member to support.
- Store person codes like any other personal data (they identify a person within your app). They are never linkable to another customer's.

## Licence
Apache-2.0 (see LICENSE and NOTICE). Third-party components are listed in `legal/THIRD_PARTY_LICENSES.md`. Pilot software: external audit pending; country coverage is partial.
