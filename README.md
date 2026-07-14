# Social Climber

A private, local-first relationship memory app for iPhone. It helps you remember the people you care about (interactions, birthdays, gift ideas, follow-ups) and tells you when a relationship is going quiet.

**Not** a social network, not a CRM product, not for the App Store. Everything stays on your phone: no accounts, no backend, no cloud sync, no analytics.

## Install on your iPhone

1. Open `SocialClimber.xcodeproj` in Xcode 16 or newer.
2. Select the **SocialClimber** target → *Signing & Capabilities* → pick your personal team (a free Apple ID works). Xcode manages signing automatically. If the bundle ID collides, change `com.jerryhuang.SocialClimber` to anything unique.
3. Plug in your iPhone (iOS 17+), select it as the run destination, and hit **Run**.
4. First run on a free account: on the phone, go to *Settings → General → VPN & Device Management* and trust your developer certificate.

Free-account builds expire after 7 days; just hit Run again to reinstall (data is kept). A paid developer account extends this to a year.

## Connecting Google Calendar (optional)

1. In [Google Cloud Console](https://console.cloud.google.com/), create (or reuse) a project, then enable the **Google Calendar API** under APIs & Services.
2. Under *APIs & Services → Credentials → Create Credentials → OAuth client ID*, choose application type **iOS**, and set the bundle ID to match your build (`com.jerryhuang.SocialClimber`, or whatever you changed it to).
3. Copy the generated Client ID and paste it into Social Climber's **Settings → Google Calendar**, then tap **Connect Google Calendar** and sign in.
4. No client secret is ever needed or requested; the app uses the standard PKCE flow for native apps. Only a refresh token is stored, in iOS Keychain.

## What's inside

- **SwiftUI + SwiftData**, iOS 17+, iPhone only, MVVM-ish with a thin service layer.
- **Dashboard**: polished empty state, quick add, selected-contact import, voice note, check-ins due, upcoming birthdays, plans, gift ideas, quiet relationships, and recent activity.
- **People**: searchable/filterable list; rich profiles with a before-meeting brief, relationship health, interests, dislikes, personality notes, gifts, important dates, reminders, and a timeline.
- **Relationship health**: statuses (good / check in soon / going quiet / dormant / archived) computed from closeness, priority, last contact, open follow-ups, and upcoming dates. Cadence defaults are configurable in Settings; per-person overrides supported.
- **Voice notes**: record a live conversation as it happens, through a shared, pocket-tuned audio pipeline (speech-optimized recording, conservative enhancement, on-device transcription), then selected AI extraction, a review screen, and applies interests, gifts, reminders, dates, personality notes, and logs a timeline interaction.
- **Audio pipeline**: one shared recorder/enhancer/transcriber under every capture screen. Records speech-tuned AAC on the clearest available mic (AirPods/wired/Bluetooth/built-in), survives interruptions, backgrounding, and route changes via crash-safe segmenting, and drives a clear state machine (recording / paused / interrupted / processing / completed / failed). Before transcription it enhances a *copy* (the original is never overwritten): rumble high-pass, gentle noise reduction, speech EQ, light compression, and guarded gain that won't amplify silence. Long audio is chunked with overlap and recombined with preserved timestamps. Transcription is centralized and confidence-aware, keeps raw *and* cleaned text separately, retries failed chunks instead of failing the whole recording, and shows honest failure states (no speech / too quiet / too noisy / unavailable / partial). Processing is idempotent and retryable.
- **AI**: `AIService` protocol with `MockAIService` (keyword heuristics, fully offline) and a hosted provider for structured JSON extraction. API keys are stored only in iOS Keychain.
- **Search**: local search across everything, with natural-ish queries and matched context: *"who likes F1?"*, *"who did I talk to about internships?"*, *"birthdays in November"*.
- **Upcoming**: merged 60-day feed of birthdays, dates, reminders, and (optional, read-only) Google Calendar events that mention known people; swipe to track one as a planned hangout.
- **Contacts**: optional one-at-a-time import via the system picker. No mass import.
- **Nearby**: optional, on-demand: resolves your current city on-device (CoreLocation + reverse geocoding) and shows a dashboard card of saved people whose `location` field matches. One-shot lookup, no background tracking, nothing stored or transmitted; toggle it on in Settings → Integrations.
- **Instagram via Google Drive**: set Instagram's JSON "Download your information" export to deliver to Google Drive, then tap Sync in Settings. Both Meta's expanded folder tree and zip delivery formats are supported. New DMs become reviewable Instagram interactions on people's timelines (matched by Instagram username, contact method, or name), follower/following lists are diffed against the previous sync to catch new followers and unfollows, and everything is parsed on-device with the raw export deleted immediately. Same bring-your-own OAuth client as Calendar (enable the Drive API on the same project). An optional daily local notification reminds you to sync, since iOS won't run it in the background reliably.
- **Social Health**: a transparent 0-100 aggregate of your whole social life (from the Dashboard): average relationship score, interaction momentum vs. last month, breadth of people reached, relationships going quiet, and your Instagram follower trend, with every point attributed to a labeled factor, plus who unfollowed you and which relationships are pulling the score down.
- **Google Calendar**: read-only, bring-your-own OAuth client: create a free "iOS" OAuth Client ID in Google Cloud Console with the Calendar API enabled, paste it in Settings, and sign in via the standard PKCE flow (no client secret needed, no backend). Only a refresh token is stored, in iOS Keychain; events are fetched on demand and never saved to disk.
- **Notifications**: local-only, and now category-based: explicit reminders, follow-ups (incl. overdue), events, birthdays, important dates, relationship maintenance, periodic reviews for prioritized contacts, post-event "how did it go?" prompts, and a "captures need review" nudge. Permission is requested *contextually* (the first time you create a reminder/date/event), never cold on launch. A dedicated **Settings → Notifications** screen toggles each category and controls quiet hours, lock-screen preview privacy (generic by default, so relationship notes never leak), default snooze, and reminder frequency. Alerts carry actions (Mark Complete, Snooze, Open, Review, Log) that update the real data models without creating duplicates, use stable identifiers so an update replaces rather than stacks, respect quiet hours and time-zone changes, and are reconciled from current data on launch and whenever data changes.
- **Backup**: JSON export via the share sheet; import asks before merging by name and skips duplicate interactions.
- **Demo data**: available only in SwiftUI previews or the debug-only **Load Demo Data** action in Settings.
- **Privacy**: local-first by default. Contacts import is selected-contact only, Google Calendar and location are opt-in, and voice notes stay local unless explicitly analyzed with the selected LLM provider.

## Layout

```
SocialClimber/
  Models/        SwiftData models (Person, Interaction, GiftIdea, Reminder,
                 ImportantDate, VoiceNote, ConversationSummary)
  Services/      RelationshipHealth, AIService (+Mock/OpenRouter),
                 ExtractionApplier, Calendar/Contacts/Location services,
                 ExportImport, Search, SeedData, PreviewData
    Audio/       Shared capture pipeline: AudioSessionManager, VoiceRecorder,
                 SpeechEnhancer, AudioChunker, AudioFileMerger, RecordingProcessor,
                 AudioCaptureState (state machine), AudioLog
    Transcription/ TranscriptionService, TranscriptSegment, TranscriptCleaner
    Notifications/ NotificationService, NotificationSettings, QuietHours,
                 NotificationActionHandler, NotificationRouter
  ViewModels/    VoiceCaptureViewModel
  Views/         One folder per screen + reusable Components
SocialClimberTests/  Unit tests: audio state machine, chunk recombination,
                 transcript cleanup, quiet hours + time zones, notification
                 settings/gating, and reminder scheduling/cancellation/dedup.
```

## Tests

Open the project in Xcode and run **Product → Test** (⌘U). The `SocialClimberTests`
target covers the pure logic that the audio and notification features depend on:
the recording state machine, overlapping-chunk recombination and timestamp
re-basing, the conservative transcript cleaner (filler/repeat removal and
strong-only name normalization), quiet-hours math including time-zone changes,
notification category gating, and reminder scheduling/cancellation/dedup.
The signal-processing math (percentile, high-pass attenuation, gain) is
exercised on synthetic buffers with no audio files needed.
