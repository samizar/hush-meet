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

The app's accent colour lives in `Resources/Assets.xcassets`; `build.sh` compiles it with `actool`.

Or open `Hush.xcodeproj`, select the shared **Hush** scheme, and run. The app lives in the menu bar and shows a Dock icon while one of its windows is open. First launch opens a five-step welcome. Every step is skippable.

To try the notebook with disposable, in-memory sample meetings:

```sh
./scripts/preview.sh
./scripts/preview.sh --dark
./scripts/preview.sh --demo-open recording
```

Preview mode never records, reads your calendar, saves anything, or reads or changes preferences. **Record** plays a simulated meeting (scripted transcript, animated levels, simulated note writing) with no microphone or files. `--demo-open` opens one surface for review: `tasks`, `transcript`, `ask`, `ask:answer`, `recording`, `popover`, `card`, `onboarding` or `settings:<general|recording|models|templates|privacy>`. Add `--demo-meeting`, `--demo-failure` or `--reduce-motion` to inspect those states. The preview copy is re-signed without the hardened runtime so ad-hoc builds can load Sparkle; quit it from its menu bar icon.

## Use

Click **Record** in the menu bar popover, the notebook toolbar or Home, or press **⌃⌥⌘R** from any app. The microphone is **Me**; selected call apps are **Them**. Both tracks stay separate. Use headphones, and obtain any consent needed for your conversation.

While recording, the meeting page shows the elapsed time, the two voice lines, a notes editor and the live transcript side by side. Type names, decisions or questions; Hush uses them as an outline when it writes the notes. Stop from the page, the popover, the toolbar, **⌘.** or the shortcut. Recording also stops cleanly when the call releases its microphone for a minute, when a calendar meeting runs ten minutes over, when the disk is nearly full, or when the Mac goes to sleep. Hush keeps the Mac awake while it records. Switching microphones or speakers mid-call (AirPods, a headset) carries on with the new device.

After Stop, notes are written in the background. You can start the next recording straight away; meetings queue and show their progress (for example "Reading part 3 of 8") in the page, the sidebar and the popover. Long meetings are split into parts with a separate time limit for each part, so an hour-long call finishes instead of timing out. If Hush quits mid-meeting or mid-notes, the next launch repairs the saved audio and, with on-device providers, finishes the notes automatically; cloud setups show **Try again**.

**Home** shows what's next on your calendar with **Join & record**, open action items and recent meetings. **Action items** collects every checklist line across meetings. Check items off anywhere, or add them to Reminders. Checked items stay checked when notes are rewritten with the same wording.

Each meeting page has **Notes**, **Transcript** and **Ask** (⌘1, ⌘2, ⌘3). Click the title to rename it. Choose a template to rewrite the notes. The new layout appears immediately from the existing notes, then the model refines them. Edit notes by hand (⌘E); Hush asks before replacing hand edits. The transcript can be searched, its speakers renamed (for example "Them" → "Priya"), and, when audio is kept, played back from any line. **Side notes** sit beside the page in wide windows and float over it in narrow ones (⌥⌘I), and autosave; **Use when writing notes** controls whether they guide the model. Search (sidebar) covers titles, notes, side notes, invitees and transcripts and shows the matching excerpt.

**Ask** answers questions about one meeting with your selected notes model. Start from **What did we decide?**, **What do I owe people?** or **What's still open?**, or type your own; follow-ups can refer to the previous answer. Answers cite transcript timestamps; click one to open the transcript at that line. Copy an answer, or choose **Add to side notes** to keep it. That is the only way an answer is saved: questions and answers stay on the page for this session and are gone when Hush quits. Apple's on-device model reads about 3,600 characters at once and local models about 8,000, so in a longer meeting Hush always includes the notes and picks the transcript lines that share the most words with your question (plus the lines either side); the answer then says it read only part of the transcript. With a cloud notes model, Hush asks once per meeting before sending questions, and again if you change providers.

**Share** copies Markdown, copies formatted notes for Mail, Notes, Docs or Slack, saves Markdown or a paginated PDF, starts an email, and copies or saves the transcript. Exports use the meeting's own title and speaker names.

## Settings

- **General:** open at login, Dock icon while windows are open, menu bar timer, the ⌃⌥⌘R shortcut, updates.
- **Recording:** spoken language, temporary audio retention, consent line, calendar, a minute's reminder, automatic recording, call detection and which apps count as the other side.
- **AI Models:** Apple Speech; Deepgram, ElevenLabs Scribe, Gemini or OpenAI transcription. Apple Foundation Models; Ollama or LM Studio / llama.cpp local models; Anthropic, OpenAI, Gemini or a remote OpenAI-compatible notes endpoint. Keys go to the Keychain. The top of the tab always says where meeting data goes. Tests send synthetic content and may incur provider charges. Changes apply to the next recording; meetings already queued keep the providers you confirmed.
- **Templates:** edit name, focus instruction and layout in the app, insert placeholders, create, duplicate, remove your own, and restore built-ins.
- **Privacy:** storage size and location, moving the store, encryption, what Hush does and doesn't do, diagnostic logs and deleting everything.

Use a provider model available to your account. Notes model names are editable. The Anthropic default is `claude-opus-5-5`, with server-side refusal fallback enabled for models that support it. Remote OpenAI-compatible servers must expose a valid HTTPS endpoint and support JSON-schema responses. Certificate validation stays enabled.

### Local AI models

Choose **Settings → AI Models → Notes → Ollama (local)** or **LM Studio / llama.cpp (local)**. Open your local runner, download/load a chat or instruction model, then click **Find models** and select it. **Test local notes** sends only a short synthetic example. Hush does not download large models or install runners automatically. Small models can omit details; review the output and choose a more capable model if needed.

- Ollama defaults to `http://127.0.0.1:11434`. It uses the native model listing, routing checks and JSON-schema chat API. Downloaded Llama, Gemma, Qwen and other chat models can be selected. Cloud-backed and embedding-only Ollama models are refused before any meeting text is sent.
- LM Studio defaults to `http://127.0.0.1:1234/v1`. A llama.cpp server can use `http://127.0.0.1:8080/v1`. Both use model discovery and OpenAI-compatible structured output. If your local server requires a token, store it in the optional Keychain field.
- Local providers accept only literal `127.0.0.1`, `[::1]`, or `localhost` (canonicalized to `127.0.0.1`), pinned to the exact selected scheme/host/port. Other addresses belong under the remote HTTPS provider. Redirects are refused. Your local server controls the selected model; no cloud fallback is attempted.

API references: [Ollama chat](https://docs.ollama.com/api/chat), [Ollama model metadata](https://github.com/ollama/ollama/blob/main/api/types.go), [LM Studio structured output](https://lmstudio.ai/docs/developer/openai-compat/structured-output).

## Files and privacy

Each meeting has its own UUID folder with `meeting.json`, `transcript.json`, and `notes.md`. Temporary `me.wav` and `them.wav` recordings are deleted after successful transcription by default. Enable audio retention to keep them. Encrypted retained audio uses `.wav.sealed`; encrypted note/JSON files retain their filenames and start with an authenticated `HUSH1` envelope. Use Hush's export menu to produce ordinary files from an encrypted store.

The default directory is the app's Application Support folder under `Hush/Meetings`. App Sandbox places this inside Hush's macOS container. Settings shows the exact location, and can move the store to a user-selected folder with a persistent security-scoped bookmark. Meeting directories are mode `0700`, files mode `0600`, protected until the first unlock after startup so recordings and notes can still be saved while the screen is locked. The optional store key and provider keys use `WhenUnlockedThisDeviceOnly` Keychain items. Keep the encryption key in the Keychain; deleting it makes encrypted meetings unrecoverable.

Templates are installed into `Hush/Templates` in Application Support. Each is a Markdown file with an instruction section, a `---` separator, and an output layout. Placeholders: `{{title}}`, `{{summary}}`, `{{key_points}}`, `{{decisions}}`, `{{decisions_table}}`, `{{action_items}}`, `{{open_questions}}`, and `{{user_notes}}`. Existing templates are never overwritten. Duplicate in Settings to create another template.

Search uses system SQLite FTS5 entirely in memory, rebuilt from meeting folders. There is no plaintext database journal, telemetry, account, backend or crash SDK. Default meeting providers make no application HTTP requests. Apple manages its own speech/model asset downloads. Automatic update checks contact GitHub and its download CDN with ordinary version/user-agent information; meeting content and provider keys are never included. System profiling is disabled. General settings can disable background checks.

All first-party meeting/provider HTTP goes through `NetworkClient`, with exact configured host matching, HTTPS for remote providers, narrowly scoped loopback HTTP for explicitly chosen local providers, no redirects, no persisted cookies, credentials or response cache. API keys are sent in headers. The app confirms cloud use before a recording or a retry, and before the first question about a meeting when the notes model is a cloud provider.

Ask sends one request per question to the selected notes provider over the same paths as notes: Foundation Models on the Mac, the pinned loopback client for Ollama or LM Studio (after the same cloud-routing check), or `NetworkClient` for Anthropic, OpenAI, Gemini and OpenAI-compatible servers. The request holds the question, the meeting's notes as shown (including hand edits), side notes only when **Use when writing notes** is on, the transcript lines that fit, and the previous question and answer, all wrapped and escaped as untrusted data. Cloud transcription is never involved. Nothing from Ask is written to disk unless you add an answer to side notes. In preview mode, answers are canned samples and no provider is created. Automatic cloud recordings ask for confirmation instead of silently starting. Sparkle's separate update transport uses HTTPS, an Ed25519-signed feed, and signed update archives verified before extraction. Developer ID signing and Apple notarization protect the app and installer as well. Preview mode never starts the updater.

## Verification

```sh
./scripts/test.sh
HUSH_RUN_MODEL_TESTS=1 ./scripts/test.sh
```

The first command runs the inherited Muesli tests, the 2.0 reliability and notebook tests (damaged-store tolerance, resilient preferences, WAV repair, search excerpts, checklists, queueing, templates, per-request deadlines), Hush storage/encryption/search/calendar/provider-boundary tests, PDF pagination tests, and a source-level network audit. The second additionally exercises the real Apple notes model with synthetic meeting speech; it requires Apple Intelligence to be ready. `HUSH_RUN_LOCAL_MODEL_TESTS=1 ./scripts/test.sh` runs a real local Ollama summarization with synthetic context, using `llama3.2:latest` by default or `HUSH_LOCAL_MODEL` if set. These tests do not download models.

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

`Sources/HushApp` contains the notebook (sidebar, Home, Action items, meeting page, transcript, inspector), the menu bar popover and meeting card, settings and template editor, onboarding, the design system (`DesignTokens.swift`, `Components.swift`), application state split by concern (`AppState+Recording`, `+Processing`, `+Library`) and exports. `Sources/HushKit` contains protected storage, Keychain access, providers, networking, templates, calendar and call detection. `Vendor/Muesli` retains Muesli's core notes/transcript types, dual audio capture, PCM conversion, speech transcription and map/reduce logic. `scripts/generate-project.py` regenerates the Xcode project after adding app source files.

Muesli source was imported from [alimuqeem/muesli](https://github.com/alimuqeem/muesli), commit `9929b4fb883d11e2d41c7eebea091ee687ce2ebd`. Its MIT notice is preserved in `Vendor/Muesli/LICENSE` and bundled with Hush. The CLI, Whisper subprocess integration and unrelated action integrations are not exposed by Hush.

Provider references: [OpenAI transcription](https://developers.openai.com/api/docs/guides/speech-to-text), [OpenAI structured output](https://developers.openai.com/api/docs/guides/structured-outputs), [Claude structured output](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [Gemini audio](https://ai.google.dev/gemini-api/docs/audio), [Deepgram transcription](https://developers.deepgram.com/docs/pre-recorded-audio), [ElevenLabs Scribe](https://elevenlabs.io/docs/api-reference/speech-to-text/convert).
