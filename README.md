# Hush

A native, local-first meeting notebook for macOS 26 and Apple Silicon. Swift 6, SwiftUI and Apple frameworks, with pinned Sparkle 2.10.0 for secure automatic updates.

The interface and PDF exports use SF Pro, with quiet paper tones and a single recording accent.

[Download Hush for Apple Silicon](https://github.com/samizar/hush-meet/releases/latest/download/Hush.dmg). Open the disk image and drag Hush to Applications. The app is Developer ID signed and notarized by Apple.

Hush 1.1 and later check for updates daily, download signed updates automatically, and install them when Hush quits. Recording, transcription, and note generation block update restarts. You can change update preferences or choose **Check for Updates…** in General settings or the Hush menu. Install Hush in Applications rather than running it from its DMG. Users of 1.0 must install 1.1 manually once to gain the updater.

## Build and run

Requires Xcode 26 with the macOS 26 SDK and an Apple Silicon Mac.

```sh
./scripts/build.sh
open build/Hush.app
```

Or open `Hush.xcodeproj`, select the shared **Hush** scheme, and run. The app lives in the menu bar; closing the notebook keeps it available. First launch opens the three-step permission setup. Every step is skippable.

To inspect the notebook with disposable, in-memory sample meetings:

```sh
open -n build/Hush.app --args --demo
open -n build/Hush.app --args --demo --dark
```

Preview mode does not record, read calendars, save sample meetings, or change preferences. The recording button is intentionally unavailable in preview mode. Quit the preview before opening the real app.

Add `--reduce-motion` to preview the static voice indicators and crossfades without changing macOS preferences.

## Use

Click the outlined circle in the menu bar, choose the spoken language, and click **Record a meeting**. The microphone is **Me**; selected call applications are **Them**. Both tracks remain separate. Use headphones, and obtain any consent needed for your conversation.

While recording, type your own outline in the popover or notebook. Stop from either surface. Apple Speech streams locally; cloud speech services transcribe the saved tracks after Stop. The selected notes provider then writes structured notes. If a model is unavailable, the transcript remains available and the app offers a retry. Cloud providers are never selected automatically.

Double-click a meeting title to rename it. Search covers titles, notes, handwritten outlines and transcripts. Choose a template to regenerate notes from the saved transcript. The export menu copies Markdown or transcripts, saves Markdown or a paginated PDF, and reveals the meeting folder.

## Settings

- **General:** launch at login, temporary audio retention, consent line, storage location and editable templates.
- **Meetings:** calendar, optional automatic recording, ad-hoc call prompts, and application capture selection. Individual upcoming meetings can override automatic recording. Unscheduled calls always ask. Browser capture includes every audio-producing tab of that browser.
- **Models:** Apple Speech; Deepgram, ElevenLabs Scribe, Gemini or OpenAI transcription. Apple Foundation Models; Anthropic, OpenAI, Gemini or an OpenAI-compatible notes endpoint. Enter keys in the secure fields and save them to the Keychain. Test sends synthetic content, may incur provider charges, and never uses a saved meeting.
- **Privacy:** storage usage, optional AES-GCM encryption, reveal files and confirmed deletion.

Use a provider model available to your account. Notes model names are editable. OpenAI-compatible servers must expose a valid HTTPS endpoint and support JSON-schema responses. Configure TLS in front of a default HTTP-only Ollama or LM Studio installation; Hush does not disable certificate validation.

## Files and privacy

Each meeting has its own UUID folder with `meeting.json`, `transcript.json`, and `notes.md`. Temporary `me.wav` and `them.wav` recordings are deleted after successful transcription by default. Enable audio retention to keep them. Encrypted retained audio uses `.wav.sealed`; encrypted note/JSON files retain their filenames and start with an authenticated `HUSH1` envelope. Use Hush's export menu to produce ordinary files from an encrypted store.

The default directory is the app's Application Support folder under `Hush/Meetings`. App Sandbox places this inside Hush's macOS container. Settings shows the exact location, and can move the store to a user-selected folder with a persistent security-scoped bookmark. Meeting directories are mode `0700`, files mode `0600`, with complete file protection where supported. The optional store key and provider keys use `WhenUnlockedThisDeviceOnly` Keychain items. Keep the encryption key in the Keychain; deleting it makes encrypted meetings unrecoverable.

Templates are installed into `Hush/Templates` in Application Support. Each is a Markdown file with an instruction section, a `---` separator, and an output layout. Placeholders: `{{title}}`, `{{summary}}`, `{{key_points}}`, `{{decisions}}`, `{{decisions_table}}`, `{{action_items}}`, `{{open_questions}}`, and `{{user_notes}}`. Existing templates are never overwritten. Duplicate in Settings to create another template.

Search uses system SQLite FTS5 entirely in memory, rebuilt from meeting folders. There is no plaintext database journal, telemetry, account, backend or crash SDK. Default meeting providers make no application HTTP requests. Apple manages its own speech/model asset downloads. Automatic update checks contact GitHub and its download CDN with ordinary version/user-agent information; meeting content and provider keys are never included. System profiling is disabled. General settings can disable background checks.

All first-party meeting/provider HTTP goes through `NetworkClient`, with exact configured host matching, HTTPS, no redirects, no persisted cookies, credentials or response cache. API keys are sent in headers. The app confirms cloud use before a recording or a retry. Automatic cloud recordings ask for confirmation instead of silently starting. Sparkle's separate update transport uses HTTPS, an Ed25519-signed feed, and signed update archives verified before extraction. Developer ID signing and Apple notarization protect the app and installer as well. Preview mode never starts the updater.

## Verification

```sh
./scripts/test.sh
HUSH_RUN_MODEL_TESTS=1 ./scripts/test.sh
```

The first command runs the inherited Muesli tests, Hush storage/encryption/search/calendar/provider-boundary tests, PDF pagination tests, and a source-level network audit. The second additionally exercises the real Apple notes model with synthetic meeting speech; it requires Apple Intelligence to be ready.

See [VERIFICATION.md](VERIFICATION.md) for the actual validation performed and remaining hardware/account checks. No automated test records a user's microphone or call, uploads a real meeting, or writes a real calendar event.

## Package and release

```sh
./scripts/package.sh
```

This creates `build/Hush.dmg` and its SHA-256 checksum. Without a signing identity it is an ad-hoc-signed development build, not a notarized public release.

For an authorized public release, configure an existing Developer ID certificate and a `notarytool` Keychain profile:

```sh
HUSH_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
HUSH_NOTARY_PROFILE='your-notary-profile' ./scripts/package.sh
```

No certificate, password, API key or notarization credential belongs in this repository. The dedicated Sparkle private key stays in the release operator's login Keychain under account `app.hush.mac`. Only its public key is embedded in the app. Preserve that Keychain key for future releases; do not generate a replacement or rotate the Apple and Sparkle keys together.

An existing signed-in Xcode account can also notarize an app without a `notarytool` profile: archive the **Hush** scheme, open the archive in Organizer, and choose **Distribute App → Direct Distribution**. Once Apple approves it, export the notarized app from Organizer, or use `xcodebuild -exportNotarizedApp` with the archive path managed by Organizer. Set `HUSH_APP_SOURCE` to that exported app when packaging to preserve its notarization ticket. A newly created DMG still needs its own notarization ticket before publication. The release configuration uses developer team `ZUT6837GB5`.

For each release, increase `CFBundleVersion` monotonically and update `CFBundleShortVersionString` in `Resources/Info.plist` and the matching project-generator settings. Run the tests, archive and export with Xcode so Sparkle's nested helpers are re-signed for distribution, and notarize/staple the final DMG. Push the source to `main`, then publish:

```sh
./scripts/publish-release.sh v1.1.0 build/Hush.dmg build/release-notes.md
```

The publisher validates the DMG signature and Apple ticket, checks the update key, generates and verifies the signed appcast and payload, uploads all files to a draft release, and only then publishes it as latest. The stable feed URL is the latest GitHub release's `appcast.xml`; update payload URLs include their immutable version tags. Keep the generated `Updates/appcast.xml` in source control for compatible-version history. Every future public release must include a signed appcast; publishing a release without it would break the latest-release feed URL. Releases created through other GitHub tools need the same signed assets and checks. See [Sparkle's release guidance](https://sparkle-project.org/documentation/publishing/).

For an installation rehearsal before existing clients see the update, set `HUSH_RELEASE_STAGE=1` when running the publisher. It exposes a prerelease for testing while leaving the stable feed untouched. Test a disposable older app against the versioned `appcast.xml` asset, then promote with `gh release edit vVERSION --repo samizar/hush-meet --prerelease=false --latest`. Never change a DMG or appcast after signing, and never replace the contents of an already published version.

## Project

`Sources/HushApp` contains the four native surfaces, onboarding, the notebook design system, application orchestration and exports. `Sources/HushKit` contains protected storage, Keychain access, providers, networking, templates, calendar and call detection. `Vendor/Muesli` retains Muesli's core notes/transcript types, dual audio capture, PCM conversion, speech transcription and map/reduce logic. `scripts/generate-project.py` regenerates the Xcode project after adding app source files.

Muesli source was imported from [alimuqeem/muesli](https://github.com/alimuqeem/muesli), commit `9929b4fb883d11e2d41c7eebea091ee687ce2ebd`. Its MIT notice is preserved in `Vendor/Muesli/LICENSE` and bundled with Hush. The CLI, Whisper subprocess integration and unrelated action integrations are not exposed by Hush.

Provider references: [OpenAI transcription](https://developers.openai.com/api/docs/guides/speech-to-text), [OpenAI structured output](https://developers.openai.com/api/docs/guides/structured-outputs), [Claude structured output](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [Gemini audio](https://ai.google.dev/gemini-api/docs/audio), [Deepgram transcription](https://developers.deepgram.com/docs/pre-recorded-audio), [ElevenLabs Scribe](https://elevenlabs.io/docs/api-reference/speech-to-text/convert).
