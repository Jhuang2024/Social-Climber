# Social Climber

A private, local-first relationship memory app for iPhone. It helps you remember the people you care about — interactions, birthdays, gift ideas, follow-ups — and tells you when a relationship is going quiet.

**Not** a social network, not a CRM product, not for the App Store. Everything stays on your phone: no accounts, no backend, no cloud sync, no analytics.

## Install on your iPhone

1. Open `SocialClimber.xcodeproj` in Xcode 16 or newer.
2. Select the **SocialClimber** target → *Signing & Capabilities* → pick your personal team (a free Apple ID works). Xcode manages signing automatically. If the bundle ID collides, change `com.jerryhuang.SocialClimber` to anything unique.
3. Plug in your iPhone (iOS 17+), select it as the run destination, and hit **Run**.
4. First run on a free account: on the phone, go to *Settings → General → VPN & Device Management* and trust your developer certificate.

Free-account builds expire after 7 days — just hit Run again to reinstall (data is kept). A paid developer account extends this to a year.

## What's inside

- **SwiftUI + SwiftData**, iOS 17+, iPhone only, MVVM-ish with a thin service layer.
- **Dashboard** — polished empty state, quick add, selected-contact import, voice note, check-ins due, upcoming birthdays, plans, gift ideas, quiet relationships, and recent activity.
- **People** — searchable/filterable list; rich profiles with a before-meeting brief, relationship health, interests, dislikes, personality notes, gifts, important dates, reminders, and a timeline.
- **Relationship health** — statuses (good / check in soon / going quiet / dormant / archived) computed from closeness, priority, last contact, open follow-ups, and upcoming dates. Cadence defaults are configurable in Settings; per-person overrides supported.
- **Voice notes** — record a live conversation as it happens → on-device transcription (Speech framework, mock fallback in the Simulator) → selected AI extraction → review screen → applies interests, gifts, reminders, dates, personality notes, and logs a timeline interaction.
- **AI** — `AIService` protocol with `MockAIService` (keyword heuristics, fully offline) and `OpenRouterAIService` for structured JSON extraction. API keys are stored only in iOS Keychain. Example documentation placeholder: `OPENROUTER_API_KEY_PLACEHOLDER`.
- **Search** — local search across everything, with natural-ish queries and matched context: *"who likes F1?"*, *"who did I talk to about internships?"*, *"birthdays in November"*.
- **Upcoming** — merged 60-day feed of birthdays, dates, reminders, and (optional, read-only) Calendar events that mention known people — swipe to track one as a planned hangout.
- **Contacts** — optional one-at-a-time import via the system picker. No mass import.
- **Notifications** — local-only: birthdays at 9 AM, reminders on their due date.
- **Backup** — JSON export via the share sheet; import asks before merging by name and skips duplicate interactions.
- **Demo data** — available only in SwiftUI previews or the debug-only **Load Demo Data** action in Settings.
- **Privacy** — local-first by default. Contacts import is selected-contact only, Calendar access is optional, and voice notes stay local unless explicitly analyzed with the selected LLM provider.

## Layout

```
SocialClimber/
  Models/        SwiftData models (Person, Interaction, GiftIdea, Reminder,
                 ImportantDate, VoiceNote, ConversationSummary)
  Services/      RelationshipHealth, AIService (+Mock/OpenRouter),
                 ExtractionApplier, Notification/Calendar/Contacts services,
                 ExportImport, Search, SeedData, PreviewData
  ViewModels/    VoiceCaptureViewModel
  Views/         One folder per screen + reusable Components
```
