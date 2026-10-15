# Hush — Mac Meeting Notes: Build Spec

Oct 15, 2026 · @Moha

## Your role

Paste everything below this line into Claude Code or Codex as the first message, or save it as `SPEC.md` in the repo root.

---

You are a senior macOS engineer and product designer. Build **Hush** (working name): a native Mac menu-bar app that records meetings, transcribes them on-device, and writes clean notes. It is a simpler, faster, more private Granola.

Three things matter more than features: it feels effortless, it looks like nothing else, and nothing leaves the Mac unless the user says so. When a choice is unclear, pick the simpler one and write the decision down in `DECISIONS.md`.

Work in small steps. After each milestone (see Build order), build the app, run it, and tell me what works and what doesn't before moving on.

## The product

Hush sits in the menu bar. When a meeting starts, it taps you on the shoulder. One click and it listens to both sides of the call. When you stop, notes appear a few seconds later.

**Principles**

- **One job.** Record, transcribe, summarize, export. Nothing else in v1.
- **Free and local by default.** Apple's on-device speech and on-device model do the work. No account, no sign-up, no server.
- **Bring your own key, optionally.** Users can switch to a cloud provider in Settings with their own API key.
- **Calm.** The app is quiet until it's needed. No badges, no streaks, no upsells.
- **Fast and tiny.** Opens instantly, idles near zero CPU, small download.

**Not in v1:** teams, sharing links, sync, mobile, chat with your meetings, speaker voice identification, integrations beyond calendar, Windows.

## Features (v1)

**1. Recording both sides**

- Capture the microphone as "Me" and system audio as "Them" on two separate tracks. Never mix them down.
- System audio uses a Core Audio process tap. Let the user limit capture to call apps (Zoom, Teams, Meet in a browser, FaceTime, Slack) so music doesn't leak in.
- The "System Audio Recording" permission can't be checked by API. A tap without it returns silence. Detect a flat "Them" level for 20+ seconds during a call and show a gentle fix-it hint.
- Recommend headphones once, in onboarding. Don't nag.

**2. Transcription**

- Default: Apple `SpeechAnalyzer` + `SpeechTranscriber`, streaming, with live (volatile) results that settle into final text.
- Optional cloud providers with the user's key: Deepgram, ElevenLabs (Scribe), Gemini, OpenAI.
- Language picker per meeting, defaulting to the system language. If Apple doesn't support the chosen language, say so plainly and offer a cloud provider. Never let Apple run on an unsupported language; it returns confident gibberish.
- Show a clear one-time progress state while Apple downloads its speech model.

**3. Notes**

- Default: Apple Foundation Models on-device. Its context is small (about 4K tokens), so long transcripts go through map/reduce: summarize chunks, then merge.
- Optional cloud LLMs with the user's key: Anthropic (Claude), OpenAI, Gemini, plus any OpenAI-compatible URL (Ollama, LM Studio).
- One notes schema shared by every provider (summary, key points, decisions, action items with owner and due date, open questions). Use guided generation for Apple and JSON schema output for the cloud ones, then render to Markdown.
- If the user typed notes during the meeting, use them as the outline and fill them in from the transcript.

**4. Templates**

- Built in: **Quick** (3-line summary + action items, the default), **Standard** (all schema sections), **Detailed** (sections + a decisions table), **1:1**, **Sales call**, **Interview**.
- A template is one Markdown file: a short instruction plus the output layout. Stored in `~/Library/Application Support/Hush/Templates/`. Users can duplicate and edit.
- Switching template re-generates notes from the saved transcript without re-transcribing.

**5. Calendar**

- Read Apple Calendar via EventKit. Google, Outlook and iCloud calendars come along if the user added those accounts in macOS. No Google login code in the app.
- An event counts as a meeting if it has a video link or another attendee, isn't all-day, and isn't declined.
- One minute before start: a notification and a small card under the menu bar with **Record** and **Skip**.
- Setting: *Start recording automatically when a meeting begins* (off by default). Per-event override in the upcoming list.
- Stop automatically when the call app releases the mic for 60 seconds, or at the event's end time plus 10 minutes, whichever comes first. Always show a stop button.

**6. Ad-hoc call detection**

- When an app holds the mic and the speakers at the same time and no meeting is armed, offer the same Record / Skip card. Never auto-record these; ask every time.

**7. Export**

- Copy as Markdown, save `.md`, save `.pdf` (rendered from the same Markdown with the app's typography), copy transcript.
- Each meeting is a plain folder on disk, so users own their files.

## Design direction

The concept is **a quiet notebook**. Notes should look like a well-typeset page in a good paper notebook, not a SaaS dashboard. Ink on paper, one warm accent, almost no chrome.

**Colour**

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `paper` | #F7F5F0 | #151513 | Window background |
| `ink` | #1A1916 | #ECE9E2 | Primary text |
| `ink-soft` | ink at 55% | ink at 55% | Secondary text, live transcript |
| `hairline` | ink at 8% | ink at 10% | Dividers, borders |
| `ember` | #D9502F | #E8673F | Recording state only. Nowhere else. |

No gradients. No glassmorphism except the system material macOS gives the menu-bar popover.

**Type**

- Notes and titles: **New York** (Apple's built-in serif). Title 22pt, body 15pt, line height 1.5.
- UI chrome: SF Pro Text 13pt.
- Timestamps and durations: SF Mono 11pt, `ink-soft`.
- Generous margins: notes column max 640pt wide, centred.

**Signature details**

- **The live line.** While recording, two thin 1.5pt lines trace voice levels left to right: Me in `ink`, Them in `ink-soft`. Like a seismograph pen, not bars or orbs. It's the app's one visual flourish.
- **Menu-bar icon.** A small outlined circle. When recording it fills with `ember` and slowly breathes (scale 1.0 to 0.85, 2.4s, ease-in-out).
- **Ink drying.** When notes arrive, each line fades in and rises 4pt, 30ms apart, 220ms each. Live transcript words start at `ink-soft` 40% and settle to `ink-soft` when finalized.

**Motion rules**

- SwiftUI springs (response 0.35, damping 0.85). Durations 150 to 300ms.
- Only the recording breath loops. Everything else plays once and rests.
- Reduce Motion on: crossfades only, no movement, live line becomes a static level dot.

**Anti-template rules (hard)**

- No purple or blue gradients, sparkle icons, "AI" badges, glowing orbs, robots, or emoji.
- No grid of rounded cards with drop shadows. Corner radius 6pt maximum.
- No illustrations in empty states. One quiet sentence instead.
- SF Symbols only, regular weight, used sparingly.
- Copy is short and human: "Listening." "Notes ready." "Couldn't hear the other side." Never "AI-powered" or "magic".
- Light and dark mode both designed, not inverted. Dark is warm charcoal, not pure black.

## Screens

There are four surfaces. Keep each one smaller than you think it needs to be.

1. **Menu-bar popover (320pt wide).** Shows the next meeting with its time and a Record button, then today's past meetings as plain rows (title, time, duration). One button opens the main window. While recording, it shows the live line, the elapsed time in SF Mono, a notes field to type into, and Stop.
2. **Meeting card.** Slides down 8pt from under the menu bar a minute before a meeting: title, "Starts in 1 min", **Record** and **Skip**. Fades away after 30 seconds if ignored. Never steals focus.
3. **Main window.** Two columns. Left: meetings grouped by day, a search field on top (searches titles, notes and transcripts locally). Right: the selected meeting as a page: title, date and duration line, a template picker, the notes, then a collapsed "Transcript" section. Export lives in a small menu at the top right. No toolbar clutter.
4. **Settings (one window, four tabs).** *General* (launch at login, storage folder, delete audio after transcription: on by default). *Meetings* (auto-record toggle, call detection, which apps to capture). *Models* (transcription provider, notes provider, API key fields, a "Test" button, and a plain line saying where data goes for the current choice). *Privacy* (see below).

**Onboarding** is three calm steps on one small window: microphone, system audio (with a 10-second test that shows the live line moving), calendar. Each step can be skipped. Finish with a single line: "You're set. Hush will tap you before your next meeting."

**Main flow:** card appears, Record, live line in the popover, Stop (or auto-stop), "Writing notes…" with a subtle progress line, notification "Notes ready", click opens the meeting page with the ink-drying animation.

## Privacy and security

The rule: with default settings, Hush makes zero network calls except Apple's one-time model downloads. Treat every rule below as a requirement, not a suggestion.

- **No backend.** No server, account, telemetry, analytics, crash reporting SDK, or auto-update phone-home in v1. Updates go out through Sparkle with EdDSA-signed appcasts only if the user turns update checks on.
- **Keys in the Keychain.** API keys stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never in UserDefaults, files, logs, or command arguments.
- **Visible data flow.** Whenever text or audio is about to leave the Mac, show which provider it's going to. The Models tab always states this in one sentence. Never fall back to a cloud provider silently.
- **Local files, protected.** Meetings live in `~/Library/Application Support/Hush/Meetings/<id>/` with Data Protection, POSIX permissions 0700. Option to encrypt the store with a key held in the Keychain.
- **Audio is temporary.** Raw audio is deleted once the transcript is final, unless the user keeps it. Transcribe from memory buffers where the provider allows.
- **Hardened app.** App Sandbox on (if the system-audio tap won't work sandboxed, verify it, then record why in DECISIONS.md), Hardened Runtime, notarized, Developer ID signed. Entitlements limited to: microphone, audio capture, calendars, outgoing network (used only for BYOK providers), user-selected files for export.
- **Network allowlist.** All outgoing requests go through one `NetworkClient` that only reaches the configured provider hosts over HTTPS. Unit-test that nothing else can call out.
- **No secrets in logs.** Use `os.Logger` with private redaction for transcript text, titles and keys.
- **Consent.** Before the first recording, a one-time note that recording others may require their consent. An optional setting copies a short "I'm taking notes with Hush" line to the clipboard when a recording starts.
- **Privacy tab.** Shows storage size, a "Delete all meetings" button (with confirmation), a "Reveal in Finder" button, and a plain-language list of what Hush does and doesn't do.

## Tech stack

- **Swift 6, SwiftUI, AppKit where needed** (menu-bar popover, non-activating panel for the meeting card). No Electron, no web views, no Tauri.
- **macOS 26+ on Apple Silicon only.** That's what Apple's speech and on-device model need.
- **Minimal dependencies.** Allowed: Sparkle (updates). Everything else is Apple frameworks: AVFoundation, Core Audio, Speech, FoundationModels, EventKit, UserNotifications, Security, PDFKit. Cloud providers are called with plain `URLSession`, no SDKs.
- **Storage:** one folder per meeting with `meeting.json`, `transcript.json`, `notes.md`. A small SQLite FTS index (via the system SQLite) for search, rebuildable from the folders.

**Start from Muesli.** Fork [github.com/alimuqeem/muesli](https://github.com/alimuqeem/muesli) (MIT). It already has dual-stream capture with a Core Audio process tap, a `SpeechAnalyzer` wrapper, a notes schema shared across Apple, Claude and OpenAI-compatible backends, and chunk-and-merge for long meetings. Read its code first, keep its core modules, drop the CLI, and build the app on top. Keep the MIT notice. Don't copy code from projects without a licence.

**Modules**

| Module | Job |
| --- | --- |
| `Capture` | Mic + process tap, two tracks, level meters for the live line |
| `Transcribe` | `TranscriptionProvider` protocol: Apple (default), Deepgram, ElevenLabs, Gemini, OpenAI |
| `Notes` | `NotesProvider` protocol: Apple FM (default), Anthropic, OpenAI, Gemini, OpenAI-compatible; templates; map/reduce |
| `Calendar` | EventKit reader, meeting rules, scheduler that arms events |
| `CallDetector` | Watches which processes hold mic + output at once |
| `Store` | Meeting folders, search index, deletion |
| `Secrets` | Keychain wrapper, the only code that touches keys |
| `NetworkClient` | The only code that makes HTTP calls, host allowlist |
| `UI` | Popover, meeting card, main window, settings, onboarding, design tokens |

All colours, sizes, radii, durations and springs live in one `DesignTokens.swift`. No literal values in views.

## Build order

Stop after each milestone, build, run, and report back.

1. **Skeleton.** Fork Muesli, create the Xcode app target, menu-bar icon, empty popover, `DesignTokens.swift`, light and dark mode.
2. **Record.** Record button, two-track capture, live line, Stop. Save a meeting folder.
3. **Transcribe.** Apple streaming transcription with live words settling into final text. Language picker.
4. **Notes.** Apple FM notes with map/reduce, the Quick template, main window with the meeting page and ink-drying animation.
5. **Calendar.** EventKit, meeting rules, meeting card, notification, auto-record toggle, auto-stop.
6. **Templates + export.** All built-in templates, editable template files, Markdown and PDF export.
7. **Bring your own key.** Settings Models tab, Keychain, `NetworkClient` allowlist, each cloud provider with a Test button.
8. **Polish.** Onboarding, call detection, search, Privacy tab, Reduce Motion, empty and error states.
9. **Ship.** Sign, notarize, DMG.

## Done means

- [ ] A 60-minute call produces notes in under 30 seconds after Stop on an M1, using only on-device models.
- [ ] Idle CPU under 1%, idle memory under 80 MB, app download under 15 MB.
- [ ] With default settings, a network monitor shows no traffic during or after a meeting.
- [ ] No API key ever appears in logs, files or crash output.
- [ ] Every screen works in light, dark and Reduce Motion.
- [ ] A first-time user can record their first meeting within 60 seconds of opening the app.
- [ ] Nothing in the UI looks like a generic AI app: check it against the anti-template rules before calling it done.
