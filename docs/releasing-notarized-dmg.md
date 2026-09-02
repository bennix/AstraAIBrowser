# Astra Browser Notarized DMG Release

Astra Browser's DMG release helper packages an existing Developer ID–signed app,
submits it to Apple's notary service, staples the ticket, and validates the
finished image. It deliberately refuses to re-sign the app with `--deep`:
Xcode must sign every nested helper and framework correctly during archive or
export.

## One-time setup

The Mac must have a valid `Developer ID Application` certificate and a
notarytool Keychain profile. A browser login is not used by `notarytool`.

```sh
xcrun notarytool store-credentials "PhiBrowser-Notary" \
  --apple-id "APPLE_ID_EMAIL" \
  --team-id "APPLE_DEVELOPER_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

The password is stored in Keychain and does not belong in this repository or
in a shell script. App Store Connect API key credentials can also be stored by
`notarytool`; see `xcrun notarytool store-credentials --help`.

In a non-interactive build environment where Keychain profile storage is
unavailable, supply the app-specific password only through the process
environment and pass the account identifiers explicitly:

```sh
NOTARY_APP_PASSWORD="APP_SPECIFIC_PASSWORD" scripts/notarize_dmg.sh \
  --app "/path/to/Astra Browser.app" \
  --output "/path/to/Astra-Browser.dmg" \
  --apple-id "APPLE_ID_EMAIL" \
  --team-id "APPLE_DEVELOPER_TEAM_ID"
```

Do not persist `NOTARY_APP_PASSWORD` in a shell profile, repository file, or
CI log.

## Build and export

Archive the `PhiBrowser-release` scheme in Xcode and export the app with
Developer ID distribution. Before packaging, verify the export:

Use the Astra build epoch for `CFBundleVersion`: public Build N must use
`10000 + N` (for example, Build 29 uses `10029`). The epoch keeps every Astra
release newer than the legacy Phi 1.6.0 build 616 that used the same bundle
identifier. Astra releases use a dedicated signed Sparkle feed hosted as the
`appcast.xml` asset on the latest GitHub Release. They must never contain Phi's
legacy OTA endpoint or signing key.

Bundle the CEF runtime and sign the app with the dedicated Developer ID
entitlements. Do not reuse the development-team entitlements because their
restricted App Group and Keychain groups are not valid for this certificate.

```sh
scripts/bundle_cef_runtime.sh \
  --app "/path/to/Astra Browser.app" \
  --cef-swift "/path/to/CefSwift" \
  --configuration release \
  --identity "Developer ID Application: ZHIPING XU (5N66S29EK2)" \
  --entitlements Resources/AstraBrowser-DeveloperID.entitlements
```

Then verify the signed app:

```sh
scripts/verify_astra_release.sh \
  --app "/path/to/Astra Browser.app" \
  --release-build 29
codesign --verify --deep --strict --verbose=2 "/path/to/Astra Browser.app"
spctl --assess --type execute --verbose=2 "/path/to/Astra Browser.app"
```

## Create and notarize the DMG

```sh
scripts/notarize_dmg.sh \
  --app "/path/to/Astra Browser.app" \
  --output "/path/to/Astra-Browser.dmg" \
  --profile "PhiBrowser-Notary"
```

The helper never overwrites an existing DMG. It automatically selects the
first available `Developer ID Application` identity, or accepts an explicit
identity through `--identity` or `DEVELOPER_ID_APPLICATION`.
When the output follows `Astra-Browser-buildN.dmg`, the helper also verifies
the matching Astra build epoch, app icon, and signed GitHub updater metadata
before creating the image.

Successful completion means all of these checks passed:

- the app has a valid Developer ID signature;
- the bundle uses `AstraIcon` and contains no legacy Phi app icon;
- the release contains the signed Astra GitHub Releases update channel and no
  Phi OTA channel or legacy rollback policy;
- the signed app launched and rendered a local CEF smoke-test page;
- the DMG has a timestamped Developer ID signature;
- Apple accepted the notary submission;
- the notary ticket was stapled and validated;
- Gatekeeper accepted the finished DMG's primary signature.

## Generate and publish the GitHub Releases appcast

The first Astra update signing key is stored in the release Mac's login
Keychain under the account `com.phibrowser.Mac.astra-github`. Its public key is
embedded in the app. Do not export or commit the private key. Back it up through
an approved secrets workflow before moving releases to another Mac.

After notarization, generate a signed appcast from the exact DMG that will be
uploaded. For Build 77, for example:

```sh
scripts/generate_github_appcast.sh \
  --dmg releases/Astra-Browser-build77.dmg \
  --tag v1.0.77 \
  --output releases/appcast.xml
```

Create the GitHub Release and upload both files. The appcast asset name must
remain exactly `appcast.xml`, because installed apps resolve it through
`https://github.com/bennix/AstraAIBrowser/releases/latest/download/appcast.xml`.

```sh
gh release create v1.0.77 \
  releases/Astra-Browser-build77.dmg \
  releases/appcast.xml \
  --repo bennix/AstraAIBrowser \
  --title "Astra Browser 1.0 (Build 77)" \
  --notes-file /path/to/release-notes.md
```

Never edit `appcast.xml` after generation. Any change invalidates its embedded
feed signature. Verify both assets are present before announcing the release:

```sh
gh release view v1.0.77 \
  --repo bennix/AstraAIBrowser \
  --json assets,url
```
