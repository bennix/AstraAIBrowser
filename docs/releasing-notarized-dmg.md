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

Successful completion means all of these checks passed:

- the app has a valid Developer ID signature;
- the signed app launched and rendered a local CEF smoke-test page;
- the DMG has a timestamped Developer ID signature;
- Apple accepted the notary submission;
- the notary ticket was stapled and validated;
- Gatekeeper accepted the finished DMG's primary signature.
