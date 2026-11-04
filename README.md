# millitop_tv

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Navidrome music

Music uses the existing Navidrome login and profile-scoped secure credential
storage. The charcoal/violet library has Home, Library (random library picks),
and Stations destinations. Desktop includes a Now Playing panel; the mobile
mini-player opens the full player. Artwork and grooved vinyl use server covers
with a missing-art fallback. Vinyl stops in place when paused and respects the
system's reduced-motion setting.

### Playback and radio architecture

- `lib/services/music_playback.dart` owns playback at app lifetime, not route
  lifetime. Its serialized, generation-guarded queue controller opens each song
  through media_kit, advances on completion, synchronizes index/metadata, and
  supports selecting queue items. Position/duration have a separate notifier.
  Switching/disconnecting profiles clears playback. Music pauses existing TV
  picture-in-picture audio; starting TV or resuming its mini-player pauses music.
  Neither medium automatically resumes the other.
- `lib/screens/music_screen.dart` handles connection, debounced search with stale
  response rejection, library/history, and station persistence.
  `lib/widgets/music_player.dart` provides artwork, vinyl, queue, transport,
  timeline, volume, and responsive player views.
- Song radio starts the seed immediately, then adds deduplicated
  `getSimilarSongs2` recommendations without restarting it. Unsupported/empty
  recommendations fall back to matching genre and/or a four-year window either
  side of the seed, round-robin across artists. The UI labels this metadata
  fallback; it is not AI or song similarity. With no suitable metadata/results,
  radio contains only the seed. Saving the actual queue is a separate action.

### Credential compatibility and security

Stream URLs are generated from current local credentials at every track open;
artwork URLs are generated when a cover/current connection is used, not saved.
Reading legacy recent tracks/stations rewrites them without `streamUrl`, while
retaining IDs, covers and missing-metadata tracks. Existing saved stations retain
their stored order; they are not silently regenerated.

The existing sync path is
`HomePreferences.liveTvProfileSyncState` → `MusicService.profileSyncState` →
`LiveTvControlService.pushConfig` → the paired device's live-TV config endpoint.
Profile selection, settings and library consumers use this same path. Music
exports no password or signed playback URLs; new devices must sign in locally.
Legacy password-bearing imports remain supported and store the password only in
FlutterSecureStorage, preserving compatibility with existing households. Older
clients may still export passwords until upgraded. This change cannot erase old
remote payloads, logs or backups: remove them and rotate credentials if exposed.
HTTP origins remain supported for compatibility; use HTTPS, especially outside a
trusted LAN. Subsonic salted MD5 tokens are protocol authentication, not transport
encryption. Music errors shown by this UI never include raw network/native
exceptions or authenticated URLs.

### Verification and device acceptance

Focused coverage is in `test/music_playback_test.dart`,
`test/music_service_test.dart`, and `test/music_widgets_test.dart`: queue
completion/index/boundaries, races/disposal/errors, radio seed/deduplication and
fallback, metadata, credential-free migrations/sync, narrow player layouts,
controls and reduced-motion/paused vinyl.

In the implementation environment, `dart format`, `flutter analyze`, the focused
tests, and `flutter build apk --debug` were attempted but could not start:
Flutter/Dart are absent (exit 127). The SDK endpoint returned HTTP 403. Static
diff/whitespace review is not a substitute for these checks. No executable UI,
screenshots, native playback, Windows build or Android device verification was
possible. Run on a Flutter-equipped machine before merging:

```sh
flutter pub get
dart format lib/services/music_playback.dart lib/services/music_service.dart lib/screens/music_screen.dart lib/widgets/music_player.dart lib/main.dart lib/profiles/profile_gate.dart lib/screens/live_tv_screen.dart lib/screens/live_tv_media_screen.dart test/music_playback_test.dart test/music_service_test.dart test/music_widgets_test.dart
flutter analyze
flutter test test/music_playback_test.dart test/music_service_test.dart test/music_widgets_test.dart
flutter test
```

**Windows:** run `flutter run -d windows` (and `flutter build windows --release`).
Sign in to a real Navidrome server; verify existing stations/history still load.
At 1280×800 and an ultrawide resolution, play a library pick, seek, change volume,
skip in both directions, select an upcoming track and let a short song finish.
Start song radio: the seed must begin once, followed by unique recommendations;
save, reopen and delete the station. Test a server without similarity support
and check the fallback description. Switch Vinyl/Artwork, pause/resume and enable
Windows reduced animations. Navigate away/back: audio must survive. Start TV,
minimize it, start music, and resume TV PiP: only the requested medium should play.
Switch profiles: old music must stop. Tab/Shift-Tab and Enter/Space must operate
buttons/sliders without a mouse. Disconnect networking during search/playback,
retry, and reconnect/change server settings without restarting the app.

**Android/TV:** run `flutter run -d <device-id>` and
`flutter build apk --debug`. Repeat playback/radio/TV/profile checks on a real
device. At a 320-logical-pixel phone width, open the mini-player, operate full
transport/timeline/volume/queue, and return without stopping music. Test
landscape, enlarged system text, reduced motion and a D-pad/keyboard. Verify
missing art/artist/album, empty search and rapid successive searches/selections.
Change the saved login and reopen an old station to verify URLs use the new
credentials. Device credentials must not appear in newly synced payloads.

Limitations: queues run until their end (no repeat), active position/queue is
in-memory rather than cross-device or restart-resumable, and saved station
availability depends on songs still existing on the server. Navigation survival
does not imply an Android background/lock-screen media service; OS suspension,
audio focus with external apps, and hardware playback need device testing.
