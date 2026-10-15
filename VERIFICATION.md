# Verification — 15 October 2026

## Confirmed

- Swift 6 build and Xcode Debug and Release application builds succeed on Apple Silicon with the macOS 26 SDK.
- The release archive is Apple Silicon only, has Hardened Runtime, and verifies with the Developer ID Application certificate for team `ZUT6837GB5`, including Apple's secure signing timestamp.
- The v1.0 and v1.1 releases completed Apple notarization through Xcode's Direct Distribution workflow. Their applications and signed DMGs have valid attached tickets, and Gatekeeper accepts them as `Notarized Developer ID`. Sparkle's framework, relaunch helper, installer and downloader in v1.1 each have the `ZUT6837GB5` Developer ID signature and a secure timestamp. Each subsequent release must repeat these checks before publication.
- Standard automated suite: 100 tests reported passing, including inherited Muesli tests, folder persistence, SQLite full-text search, encryption integrity and migration, audio framing and conversion, calendar rules, template editing, network boundaries and transport errors, multipage PDF export, and five update-safety tests. Two opt-in integration tests are run separately.
- Update-safety tests confirm that preview mode does not start checks, active work blocks both background and manual checks, scheduled alerts wait during a meeting, idle checks are allowed, and a postponed restart resumes only after work finishes.
- Network source audit passes: `NetworkClient` is the only first-party meeting/provider HTTP implementation. Default provider configuration has an empty host allowlist; unsafe URLs and non-configured hosts are rejected before transport. Error messages omit response bodies. Pinned Sparkle 2.10.0 separately handles signed updates; it never receives meeting content or provider keys.
- Real Apple Foundation Models integration passes using synthetic meeting speech, producing a summary and action items in about 22 seconds on this development Mac.
- Real Apple Speech integration passes on two simultaneous synthetic audio streams, preserving the Me/Them channel labels. The fixture is generated speech, not a microphone or real meeting recording.
- PDF export test verifies pagination, the first and last text, every one of 100 decision lines, and inline Markdown removal.
- Native app launched and notebook, search, six template choices, template switching, and model settings were inspected. The user-requested SF Pro change applies to all app text and PDF export.
- The v1.0 signed and notarized disk image is approximately 1.1 MB, below the 15 MB download target. A read-only mount confirmed that it contains build 2 with a valid notarization ticket. Its alternate ZIP preserves the app's signature and ticket after extraction. SHA-256 checksum files accompany both downloads.

## Automatic update release v1.1.0

- The signed and notarized DMG is approximately 2.1 MB. The app is version 1.1.0, build 4, and uses pinned Sparkle 2.10.0. Both automatic checks and automatic download/installation default to enabled, with a daily check interval.
- The final DMG and the appcast's Ed25519 signatures verify using the dedicated Hush signing key. Modified copies of both the appcast and archive are rejected by Sparkle's verification tool. The private key was generated in the local login Keychain and was never exported into source or release assets.
- The release was first published as a prerelease with a signed appcast and versioned download URL. Using Sparkle's official CLI compiled from the pinned source, a disposable notarized build 3 downloaded the real GitHub DMG and upgraded successfully to build 4. The installed copy retains valid deep code signatures and an attached Apple ticket.
- A second real download was deferred while an isolated test host was running. The test app remained build 3 after staging. Ending only that host triggered installation automatically and changed the test app to build 4, without a manual install action. Tests watched a separate host bundle and did not launch or terminate the user's Hush or access saved meetings.
- After promotion to the latest stable release, Sparkle's read-only probe discovered 1.1.0 through the exact stable feed URL embedded in the app. A fresh download of the public release passes its SHA-256 checksum, Ed25519 payload verification, stapler validation and Gatekeeper assessment.
- The updater tests cover meeting/restart guards separately from the real installer rehearsal. This does not replace the live-call/device and provider acceptance checks below.

## Requires device/account acceptance testing

- A real two-sided call with microphone and System Audio Recording permissions, including headphones, selected call-app scope, silence hint, and device changes. Automated tests intentionally do not record private conversations or grant TCC access.
- Calendar reminders, non-activating meeting cards, automatic recording and microphone-release stop timing against real calendar events and call applications.
- Authenticated cloud requests using the user's own provider accounts. No API keys or real meeting data were supplied for these tests.
- Every surface in dark mode and Reduce Motion during an actual recording; the palette and reduced-motion branches are implemented, and preview flags support inspection.
- A 60-minute call finishing notes within 30 seconds on an M1. The short integration result does not establish this target.
- Sustained idle CPU below 1% and idle resident memory below 80 MB. A development preview with the notebook open showed 0% CPU and about 96 MB RSS at one sample; this is not the menu-only release idle benchmark. Normal subsequent launches stay in the menu bar, and closed windows are released.
- A full external network trace during and after a real default-provider meeting, beyond the source and request-boundary checks.

These unmeasured targets are not claimed as satisfied by a successful build or a small synthetic test.
