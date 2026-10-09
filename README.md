# Nod ID iOS SDK: integrate in an iOS app (about an hour)

Your app shows one sheet. The member's iPhone reads the passport chip and makes the proof. Your backend gets yes/no and a person code. You never receive an ID.
Needs: Xcode 16+, iOS 17+, a **real iPhone** (NFC does not work in the simulator), a Nod ID app key from us. A working example is in `sdk-ios/Sample/`.

**1. Add the package.** Xcode, File > Add Package Dependencies, enter `https://github.com/Nod-ID/nodid-ios`, version rule "Exact" or "Up to next minor" from the release you were given, product **NodIDKit**, then `import NodIDKit`. The Rust proving core comes as a prebuilt binary (checked against a checksum in `Package.swift`). (Working in the Nod ID repository itself: add the local folder `sdk-ios/NodIDKit` and run `scripts/sdk-package.sh` once.)

**2. Turn on the phone features.**
- Signing & Capabilities: add **Near Field Communication Tag Reading**. Entitlement `com.apple.developer.nfc.readersession.formats` = `TAG`.
- Info.plist: `NFCReaderUsageDescription`, `NSCameraUsageDescription` (your own words, say it stays on the phone), and `com.apple.developer.nfc.readersession.iso7816.select-identifiers` = `A0000002471001`, `A0000002472001`, `00000000000000`.

**3. Proving resources (circuits, keys, SRS, CSCA files; about 135 MB).** Release builds of the package download them once into the app's Application Support folder (not backed up). Every file is checked against a manifest whose SHA-256 is built into the SDK release, so the download host cannot change what runs. Files come from `nodid.app/sdk/<version>/` and, if that is unreachable, from the GitHub release. A stopped download continues where it stopped. Nothing about the member is uploaded.

**Call `NodID.prefetch()` at app launch** so the files are ready before a member ever opens the flow:
```swift
// in application(_:didFinishLaunchingWithOptions:) or your App's init
NodID.prefetch()                      // waits for Wi-Fi (default)
// NodID.prefetch(allowCellular: true) // also over mobile data
```
It returns at once and downloads in the background; it does nothing when the files are already on the phone. If the app is closed first, the next launch continues. If a member opens the flow before it finishes, the flow completes the download over any network and shows "Getting ready for the first time" with a percentage that follows the bytes. Without `prefetch()`, the flow starts the download when it opens (Wi-Fi only until the proof needs it).

To ship the files inside your app instead (no download), add the resources folder from the release to your app target as a **group**, not a folder reference, so the files sit flat; or pass `RealServices(resources: url)`. Development builds of the package (this repository) expect the bundled folder.

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
-> {"outcome":"verified","personCode":"...","versions":{...}}     (202 while pending)
```
`personCode` is stable for the same person in your app and cannot be matched across other apps. Use it for one-account-per-person.

**What you configure per app** (name, accent colour, minimum age, expiry and country checks, country list, help link, digital ID on/off, other ways to prove): in the dashboard at dashboard.nodid.app. Sign in with your email (no password), create an app, set the checks, create a secret key (shown once), and use **Run a test verification** to get a test session id; paste it into the Sample app (or pass it to `NodIDVerifyView`) and the dashboard shows the outcome. Usage shows counts of the four outcomes only.

**Limits today.** Device only (no simulator). Passports whose signing certificates are larger than 2,048 bytes, or from countries not yet in the coverage table (`docs/COUNTRY_COVERAGE.md`), show the member a clear "can't accept this passport yet" screen. "Verify with Wallet" is shown only when your app has it switched on, and does nothing until Apple approves us for it.

## Licence
Apache-2.0 (see LICENSE and NOTICE). Third-party components are listed in `legal/THIRD_PARTY_LICENSES.md`. Pilot software: external audit pending; country coverage is partial.
