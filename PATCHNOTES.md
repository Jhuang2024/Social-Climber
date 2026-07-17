# Patch Notes

## Unreleased — Instagram sync moved out of Settings

Syncing is a daily action, not configuration, so the "Sync Now" button left
Settings and now lives where the day starts.

- The Home dashboard shows an Instagram Sync card whenever Google Drive is connected: last-synced time, live progress while syncing, and the same review sheet afterwards. It also appears on an empty dashboard, since a first sync can create your first people.
- Social Health's Instagram card gained the same Sync Now action, so the page that shows follower changes can also refresh them, instead of sending you to Settings.
- Settings keeps only the one-time plumbing: connect/disconnect Google Drive, the export folder name, the daily reminder toggle, and the setup guide. Its copy (and the 10 AM reminder notification) now point at the Home screen.

## Unreleased — People widget navigation and Learned Automatically junk

- Fixed the dashboard People card's list: tapping a person there landed back on the same list instead of opening their profile. Rows now push the profile directly (same for the Social Health "Pulling the Score Down" rows, which used the identical fragile pattern).
- Learned Automatically no longer surfaces chat banter dressed up as facts: values containing emoji, first/second-person wording ("Selling my grades"), or message slang ("Ts game", "ong", "fr") are treated as quoted chat fragments and filtered. The filter is applied live, so existing junk rows disappear without touching user-confirmed facts.
- The AI extraction prompt now demands durable, third-person facts, tells the model that one-off banter and jokes are not interests, caps personality notes, and forbids "how they text" observations — so real-AI extractions stop producing the junk the heuristic path was already blocked from producing.

## Unreleased — Rolling voice segments, Mandarin, and speaker attribution

Live voice recording now works in 30-second slices so long conversations are
processed as they happen instead of in one slow pass at the end. All additive
and backward compatible (SwiftData lightweight migration handles the new
`VoiceNote.conversationData` field).

- Long-form voice recording now auto-rotates every 30 seconds: the finished slice is enhanced + transcribed in the background while a fresh slice keeps recording, attributed to the same person and conversation. A two-minute chat is transcribed as four slices, not one long wait.
- The live transcript builds up slice-by-slice as you talk, with a "transcribing as you talk" progress line; the slices are merged into one canonical original recording for playback on stop.
- Added a recording language picker (English / 中文). Mandarin is transcribed with the Mandarin recognizer, then auto-translated to English (Apple's on-device Translation, iOS 18+) before analysis; the original Mandarin transcript is always preserved and viewable.
- On iOS versions without on-device translation, a Mandarin recording is still transcribed in Mandarin and the app says so instead of failing silently.
- Conversations now show "who said what": given the people you pick before recording (plus you, the narrator), the AI attributes each line to its likely speaker. Shown in review and on the saved note; it's a reading aid and never a source of facts.
- Interruptions, backgrounding, and pauses still finalize and hand off the current slice safely, so a crash costs at most the open slice.

## Unreleased — Notification delivery reliability

- Fixed foreground alerts omitting the Notification Center `.list` presentation option, which let iOS report a test as delivered even though it vanished when its banner was suppressed.
- Delivery tests now clear stale delivered tests first and record whether `willPresent` actually ran, rather than blaming Focus based on an old notification with the same identifier.
- Fixed date-only reminders due today being converted into already-past 9 AM triggers and silently never firing.
- Overdue follow-ups now use the existing overdue category and schedule for the next reminder window instead of being dropped.
- Birthdays and important dates scheduled after 9 AM on the day now alert shortly instead of skipping to the following year.
- Production notification requests now record and display scheduling errors, and Settings exposes the actual iOS Time Sensitive permission state.

## Unreleased: Instagram Google Drive folder imports

- Fixed Instagram sync incorrectly requiring a zip inside the selected Drive folder.
- Added recursive support for Meta's expanded folder delivery, including nested message, follower, and following JSON files.
- Kept existing single-part and multi-part zip support.
- Added Drive pagination so exports with more than 100 files or folders are fully discovered.
- Updated setup guidance to require JSON format and explain both folder and zip deliveries.
- Instagram conversations applied from Drive now appear in Recent Captures with their Instagram source, person, summary, and capture-linked results.
- Retrying the same import backfills older Instagram interactions instead of creating duplicate captures or interactions.
- Routed Instagram conversations through the full capture pipeline so summaries, learned facts, search, undo, and provenance all use the same system as typed and voice captures.
- Instagram-derived dates, reminders, gifts, interests, and personality details are now reviewable evidence-linked suggestions instead of silently mutating profiles or scheduling notifications.
- Added an idempotent legacy repair that collapses duplicate Instagram interactions and removes the repeated generic dates, auto-follow-ups, and raw transcript lines created by the original importer.
- Fixed Social Health showing the disconnected hint after a successful first sync; it now recognizes Drive independently from whether any gain/loss events exist.
- Added last-updated status and separate 30-day follower change metrics.
- Made follower parsing accept every Meta wrapper shape and every username in grouped `string_list_data`, with source-file counts shown after sync.
- Large partial-to-complete export jumps now replace the baseline instead of being misreported as hundreds of overnight follows or unfollows.
- Removed misleading follower/following totals for date-limited Meta exports; Social Health now focuses only on detected changes between snapshots.
- Added person-level history for all four Instagram changes: followed you, unfollowed you, you followed, and you unfollowed.
- Added a smoothed, selectable Social Health score chart with week, month, year, and all-time ranges; dragging shows the exact score and date.
- Removed Social Health chart drag lag by caching historical score points and isolating high-frequency selection updates from the rest of the screen.
- Fixed the daily Instagram reminder appearing enabled while master notifications were off, moved it to 10 AM, and added live iOS permission, pending-request diagnostics, and a test notification.
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
