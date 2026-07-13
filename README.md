# Social Climber

A private, local-first relationship memory app for iPhone. It helps you remember the people you care about — interactions, birthdays, gift ideas, follow-ups — and tells you when a relationship is going quiet.

**Not** a social network, not a CRM product, not for the App Store. Everything stays on your phone: no accounts, no backend, no cloud sync, no analytics.

## Install on your iPhone

1. Open `SocialClimber.xcodeproj` in Xcode 16 or newer.
2. Select the **SocialClimber** target → *Signing & Capabilities* → pick your personal team (a free Apple ID works). Xcode manages signing automatically. If the bundle ID collides, change `com.jerryhuang.SocialClimber` to anything unique.
3. Plug in your iPhone (iOS 17+), select it as the run destination, and hit **Run**.
4. First run on a free account: on the phone, go to *Settings → General → VPN & Device Management* and trust your developer certificate.

Free-account builds expire after 7 days — just hit Run again to reinstall (data is kept). A paid developer account extends this to a year.

## Connecting Google Calendar (optional)

1. In [Google Cloud Console](https://console.cloud.google.com/), create (or reuse) a project, then enable the **Google Calendar API** under APIs & Services.
2. Under *APIs & Services → Credentials → Create Credentials → OAuth client ID*, choose application type **iOS**, and set the bundle ID to match your build (`com.jerryhuang.SocialClimber`, or whatever you changed it to).
3. Copy the generated Client ID and paste it into Social Climber's **Settings → Google Calendar**, then tap **Connect Google Calendar** and sign in.
4. No client secret is ever needed or requested — the app uses the standard PKCE flow for native apps. Only a refresh token is stored, in iOS Keychain.

## What's inside

- **SwiftUI + SwiftData**, iOS 17+, iPhone only, MVVM-ish with a thin service layer.
- **Dashboard** — polished empty state, quick add, selected-contact import, voice note, check-ins due, upcoming birthdays, plans, gift ideas, quiet relationships, and recent activity.
- **People** — searchable/filterable list; rich profiles with a before-meeting brief, relationship health, interests, dislikes, personality notes, gifts, important dates, reminders, and a timeline.
- **Relationship health** — statuses (good / check in soon / going quiet / dormant / archived) computed from closeness, priority, last contact, open follow-ups, and upcoming dates. Cadence defaults are configurable in Settings; per-person overrides supported.
- **Voice notes** — record a live conversation as it happens → on-device transcription (Speech framework, mock fallback in the Simulator) → selected AI extraction → review screen → applies interests, gifts, reminders, dates, personality notes, and logs a timeline interaction.
- **AI** — `AIService` protocol with `MockAIService` (keyword heuristics, fully offline) and `OpenRouterAIService` for structured JSON extraction. API keys are stored only in iOS Keychain. Example documentation placeholder: `OPENROUTER_API_KEY_PLACEHOLDER`.
- **Search** — local search across everything, with natural-ish queries and matched context: *"who likes F1?"*, *"who did I talk to about internships?"*, *"birthdays in November"*.
- **Upcoming** — merged 60-day feed of birthdays, dates, reminders, and (optional, read-only) Google Calendar events that mention known people — swipe to track one as a planned hangout.
- **Contacts** — optional one-at-a-time import via the system picker. No mass import.
- **Nearby** — optional, on-demand: resolves your current city on-device (CoreLocation + reverse geocoding) and shows a dashboard card of saved people whose `location` field matches. One-shot lookup, no background tracking, nothing stored or transmitted; toggle it on in Settings → Integrations.
- **Instagram via Google Drive** — set Instagram's "Download your information" to deliver a daily export to Google Drive, then tap Sync in Settings: new DMs become reviewable Instagram interactions on people's timelines (matched by Instagram username, contact method, or name), follower/following lists are diffed against the previous sync to catch new followers and unfollows, and everything is parsed on-device with the raw export deleted immediately. Same bring-your-own OAuth client as Calendar (enable the Drive API on the same project). An optional daily local notification reminds you to sync, since iOS won't run it in the background reliably.
- **Social Health** — a transparent 0–100 aggregate of your whole social life (from the Dashboard): average relationship score, interaction momentum vs. last month, breadth of people reached, relationships going quiet, and your Instagram follower trend — every point attributed to a labeled factor, plus who unfollowed you and which relationships are pulling the score down.
- **Google Calendar** — read-only, bring-your-own OAuth client (same spirit as the OpenRouter AI key): create a free "iOS" OAuth Client ID in Google Cloud Console with the Calendar API enabled, paste it in Settings, and sign in via the standard PKCE flow (no client secret needed, no backend). Only a refresh token is stored, in iOS Keychain; events are fetched on demand and never saved to disk.
- **Notifications** — local-only: birthdays at 9 AM, reminders on their due date.
- **Backup** — JSON export via the share sheet; import asks before merging by name and skips duplicate interactions.
- **Demo data** — available only in SwiftUI previews or the debug-only **Load Demo Data** action in Settings.
- **Privacy** — local-first by default. Contacts import is selected-contact only, Google Calendar and location are opt-in, and voice notes stay local unless explicitly analyzed with the selected LLM provider.

## Layout

```
SocialClimber/
  Models/        SwiftData models (Person, Interaction, GiftIdea, Reminder,
                 ImportantDate, VoiceNote, ConversationSummary)
  Services/      RelationshipHealth, AIService (+Mock/OpenRouter),
                 ExtractionApplier, Notification/Calendar/Contacts/Location services,
                 ExportImport, Search, SeedData, PreviewData
  ViewModels/    VoiceCaptureViewModel
  Views/         One folder per screen + reusable Components
```
