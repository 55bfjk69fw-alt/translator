# Deployment — the real build (TestFlight)

The app has two build paths:

| | Swift Playgrounds (dev) | CI real build (TestFlight) |
|---|---|---|
| Where it runs | Inside Playgrounds, on the iPad it was opened on | Home-screen app on any of your iPhones/iPads (iOS 18+) |
| Background audio | ❌ foreground-only — pipeline dies when the screen locks | ✅ `UIBackgroundModes: audio` — keeps translating locked/pocketed |
| Built by | Tapping **Run** on the iPad | `.github/workflows/testflight.yml` on a GitHub-hosted Mac |
| Needs a Mac | No | No (the Mac is a rented CI runner) |

Both paths compile the **same source files** in `TranslatorApp.swiftpm/`. The CI
build wraps them in a generated Xcode project (`deploy/project.yml`, via
[XcodeGen](https://github.com/yonaskolb/XcodeGen)) so it can carry a real
`Info.plist` (`deploy/Info.plist`) with capabilities Swift Playgrounds can't
grant. Nothing about the on-iPad Playgrounds workflow changes.

## One-time setup (~30 min, all doable from the iPad)

1. **Join the Apple Developer Program** ($99/yr) at
   [developer.apple.com](https://developer.apple.com) with your Apple ID.

2. **Note your Team ID**: developer.apple.com → Account → Membership details →
   Team ID (10 characters, e.g. `A1B2C3D4E5`).

3. **Create the app record**: [App Store Connect](https://appstoreconnect.apple.com)
   → Apps → **+** → New App:
   - Bundle ID: register `com.stufflebeam.translator` (the "+" in the Bundle ID
     dropdown, or developer.apple.com → Identifiers)
   - Platform iOS, any name (e.g. "Translator"), primary language, SKU anything.
   - TestFlight-only apps are never public and never go through App Review
     (internal testers).

4. **Create an App Store Connect API key**: App Store Connect → Users and
   Access → Integrations → App Store Connect API → Team Keys → **+**.
   - Role: **Admin** — required for cloud signing; a Developer/App Manager key
     fails with "Cloud signing permission error".
   - Download the `.p8` file (only offered once) and note the **Key ID** and
     the **Issuer ID** shown at the top of the page.

5. **Add the GitHub secrets**: repo → Settings → Secrets and variables →
   Actions → New repository secret:

   | Secret | Value |
   |---|---|
   | `ASC_KEY_ID` | Key ID from step 4 |
   | `ASC_ISSUER_ID` | Issuer ID from step 4 |
   | `ASC_KEY_P8` | Full contents of the `.p8` file (open it in a text editor and paste, `-----BEGIN PRIVATE KEY-----` lines included) |
   | `APPLE_TEAM_ID` | Team ID from step 2 |

6. **Add yourself as an internal tester**: App Store Connect → your app →
   TestFlight → Internal Testing → **+** group → add your Apple ID. Install
   the **TestFlight** app on the iPhone/iPad and accept the email invite.

## Shipping a build

1. GitHub → **Actions** tab → **TestFlight** → **Run workflow** (Safari on the
   iPad or the GitHub app both work). Pushing a `v*` tag triggers it too.
2. ~10–15 min of build + upload, then App Store Connect processes the build
   (another 5–15 min).
3. It appears in the TestFlight app — install/update from there.

- **Build number** is the workflow run number (unique automatically).
- **Version string** is `MARKETING_VERSION` in `deploy/project.yml` — bump it
  when it feels like a new version; TestFlight groups builds under it.
- Export compliance is pre-answered (`ITSAppUsesNonExemptEncryption: false` —
  the app only uses standard HTTPS/WSS), so builds go live without questions.
- TestFlight builds expire after 90 days; ship a new one before then.

## Why cloud signing (no fastlane, no certificates)

The workflow passes the API key to `xcodebuild -allowProvisioningUpdates`,
which creates and manages the distribution certificate and provisioning
profile in Apple's cloud ([Xcode cloud signing](https://developer.apple.com/videos/play/wwdc2021/10204/)).
There is no certificate to export, no keychain to unlock on CI, and no
`fastlane match` repo to maintain. If signing ever wedges (e.g. revoked
certs), developer.apple.com → Certificates shows what Xcode created.

## What's different from the Playgrounds build

- **Background audio works**: `UIBackgroundModes: audio` keeps capture,
  translation sessions, and AirPods playback alive with the screen locked or
  the app backgrounded — as long as a conversation is running (an active
  audio session is what keeps the app alive; Stop → normal suspension).
- Real home-screen app with its own icon (`deploy/Assets.xcassets` — a
  placeholder waveform; replace `icon-1024.png` with real art any time).
- Keychain (API key storage), settings, and transcripts are per-app-identity:
  the TestFlight app and the Playgrounds copy don't share data, so re-enter
  the OpenAI key on first launch.

## Building locally on a Mac (optional)

```sh
brew install xcodegen
xcodegen generate --spec deploy/project.yml --project deploy
open deploy/Translator.xcodeproj
```

The generated project is disposable (gitignored) — regenerate after editing
`deploy/project.yml`. Source edits belong in `TranslatorApp.swiftpm/` as
always so the Playgrounds workflow sees them too.

## Troubleshooting

- **"Cloud signing permission error"** — the API key isn't Admin (step 4).
- **Upload rejected: bundle ID not found** — the app record (step 3) doesn't
  exist yet or uses a different bundle ID than `com.stufflebeam.translator`.
- **"No profiles for 'com.stufflebeam.translator'"** with
  `-allowProvisioningUpdates` present — check `APPLE_TEAM_ID` matches the team
  that owns the bundle ID.
- **Duplicate build number** — a re-run of an old workflow run reuses its run
  number; trigger a fresh run instead.
