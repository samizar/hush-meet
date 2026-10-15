# Verification — 15 October 2026

## Confirmed

- Swift 6 build and Xcode Debug and Release application builds succeed on Apple Silicon with the macOS 26 SDK.
- The release archive is Apple Silicon only, has Hardened Runtime, and verifies with the Developer ID Application certificate for team `ZUT6837GB5`, including Apple's secure signing timestamp.
- Apple notarization was completed through Xcode's Direct Distribution workflow. The exported application has a valid attached ticket, and Gatekeeper accepts it as `Notarized Developer ID`. The final DMG packages that notarized app and carries a Developer ID signature.
- Standard automated suite: 95 tests reported passing, including inherited Muesli tests, folder persistence, SQLite full-text search, encryption integrity and migration, audio framing and conversion, calendar rules, template editing, network boundaries and transport errors, and multipage PDF export. Two opt-in integration tests are run separately.
- Network source audit passes: `NetworkClient` is the only application HTTP implementation. Default provider configuration has an empty host allowlist; unsafe URLs and non-configured hosts are rejected before transport. Error messages omit response bodies.
- Real Apple Foundation Models integration passes using synthetic meeting speech, producing a summary and action items in about 22 seconds on this development Mac.
- Real Apple Speech integration passes on two simultaneous synthetic audio streams, preserving the Me/Them channel labels. The fixture is generated speech, not a microphone or real meeting recording.
- PDF export test verifies pagination, the first and last text, every one of 100 decision lines, and inline Markdown removal.
- Native app launched and notebook, search, six template choices, template switching, and model settings were inspected. The user-requested SF Pro change applies to all app text and PDF export.
- Initial signed disk image is approximately 1.1 MB, below the 15 MB download target. The final asset is rebuilt from the notarized export before publication.

## Requires device/account acceptance testing

- A real two-sided call with microphone and System Audio Recording permissions, including headphones, selected call-app scope, silence hint, and device changes. Automated tests intentionally do not record private conversations or grant TCC access.
- Calendar reminders, non-activating meeting cards, automatic recording and microphone-release stop timing against real calendar events and call applications.
- Authenticated cloud requests using the user's own provider accounts. No API keys or real meeting data were supplied for these tests.
- Every surface in dark mode and Reduce Motion during an actual recording; the palette and reduced-motion branches are implemented, and preview flags support inspection.
- A 60-minute call finishing notes within 30 seconds on an M1. The short integration result does not establish this target.
- Sustained idle CPU below 1% and idle resident memory below 80 MB. A development preview with the notebook open showed 0% CPU and about 96 MB RSS at one sample; this is not the menu-only release idle benchmark. Normal subsequent launches stay in the menu bar, and closed windows are released.
- A full external network trace during and after a real default-provider meeting, beyond the source and request-boundary checks.

These unmeasured targets are not claimed as satisfied by a successful build or a small synthetic test.
