# Patch Notes

## Unreleased: Instagram Google Drive folder imports

- Fixed Instagram sync incorrectly requiring a zip inside the selected Drive folder.
- Added recursive support for Meta's expanded folder delivery, including nested message, follower, and following JSON files.
- Kept existing single-part and multi-part zip support.
- Added Drive pagination so exports with more than 100 files or folders are fully discovered.
- Updated setup guidance to require JSON format and explain both folder and zip deliveries.
- Instagram conversations applied from Drive now appear in Recent Captures with their Instagram source, person, summary, and capture-linked results.
- Retrying the same import backfills older Instagram interactions instead of creating duplicate captures or interactions.
- Raw downloaded files are still temporary, parsed on-device, and deleted immediately after the sync.

## Unreleased — Audio pipeline & notifications overhaul

Two production-focused upgrades. No existing feature, data model, capture flow,
or transcription behavior was removed — everything additive and backward
compatible (SwiftData lightweight migration handles the new `VoiceNote` fields).

### 1. Shared, pocket-tuned audio pipeline

All audio capture now runs through one shared pipeline instead of per-screen
logic, so every entry point behaves identically and reliably — even with the
phone in a pocket.

**Recording**
- Speech-optimized AAC settings (mono, 32 kHz, ~48 kbps) — clear voice, small files.
- Voice-tuned `AVAudioSession` configuration with interruption recovery.
- Picks the clearest available input (wired → Bluetooth/AirPods → built-in) and
  **pins** it so the route can't silently switch mid-recording.
- Survives phone calls, Siri, other audio apps, backgrounding, focus loss, and
  media-server resets: the recording is finalized into crash-safe segments and
  auto-resumed where appropriate. A crash costs at most the current segment.
- The original recording is always preserved and never overwritten.
- An honest capture state machine: recording / paused / interrupted /
  processing / completed / failed. Every recording can be manually retried.

**Pocket-recording enhancement (on a copy, before transcription)**
- Detects speech level and noise floor.
- Guarded automatic gain that raises quiet speech but never amplifies
  silence/noise.
- Gentle noise reduction for constant background (traffic, AC, hum, fabric).
- High-pass removal of low-frequency rumble from walking/handling.
- Speech-presence EQ and light dynamic-range compression.
- Deliberately conservative — tuned for intelligibility, not an artificially
  clean sound (aggressive denoising that eats consonants is avoided).
- Extremely long audio is split into overlapping chunks and recombined with
  preserved timestamps.

**Transcription**
- One centralized on-device transcription service for every audio entry point.
- Confidence-aware: uncertain words are flagged internally, never invented.
- Raw (verbatim) and cleaned transcripts are stored separately.
- Cleaned copy removes filler and immediate repeats and normalizes names only on
  a strong, unambiguous match to a known contact (hints, never forced rewrites).
- Failed chunks are retried instead of failing the whole recording.
- Idempotent and guarded: reopening the app never creates duplicate transcripts,
  memories, interactions, or reminders; pending/failed captures are picked back
  up when the app becomes active.
- Honest failure states: no speech, too quiet, too much background noise,
  transcription unavailable, partial transcription.
- Voice notes can be replayed, reviewed, edited, and re-transcribed from the
  interaction detail screen.

### 2. Notifications & reminders

- Local-only, now organized into categories: explicit reminders, follow-ups,
  overdue follow-ups, events, birthdays, important dates, relationship
  maintenance, periodic reviews for prioritized contacts, and capture-review
  nudges.
- Permission is requested **contextually** (first time you create a
  reminder/date/event), never cold on first launch.
- New **Settings → Notifications** screen: master toggle, per-category toggles,
  quiet hours, lock-screen preview privacy, default snooze, and reminder
  frequency — using the app's existing visual system.
- Privacy-safe text by default ("A saved reminder is due.") that never exposes
  relationship notes on the lock screen; opt in to detailed previews.
- Notification actions (Mark Complete, Snooze, Open, Review, Log) update the
  authoritative data models without creating duplicates.
- Stable, persisted identifiers so updates replace rather than stack; alerts are
  automatically cancelled/updated when the underlying item changes, completes,
  or is deleted.
- Respects quiet hours and handles time-zone changes; reconciles the full
  scheduled set on launch and whenever relevant data changes.

### Reliability

- All current user data preserved; migration is automatic and additive.
- No duplicate reminders or transcripts after migration (idempotent processing
  and stable notification identifiers).
- New `SocialClimberTests` unit-test target covering the audio state machine,
  transcription chunk recombination, transcript cleanup, quiet-hours/time-zone
  math, notification gating, and reminder scheduling/cancellation/dedup.
- Development logging that never records private transcript contents.
