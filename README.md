# millitop_tv

A new Flutter project.

## Native Podcasts

The Home **Podcasts** app opens a theme-aware podcast library with Apple Podcasts
directory search, audio/video filters, followed shows, latest episodes and
continue-listening cards. Playback uses the publisher's public RSS enclosure;
Apple sign-in is not required and paid/private Apple subscriptions are not accessed.
Video episodes are offered only when the publisher includes video in its feed.

Controls include play/pause, resume/restart, 15-second rewind, 30-second forward,
seeking, playback speed, queue auto-advance, volume, sleep timer and video fullscreen.
Playback continues when returning Home using the podcast mini-player.
Following, queue, speed and listening progress are saved separately per profile
and included in the existing dashboard profile-sync payload. Downloads are local
to the device/profile, selected from episode details, and automatically used for
offline playback. Downloaded files are not uploaded through profile sync.

The dashboard server must accept the expanded profile payload on
`/api/device/live-tv/config` (1 MB JSON limit, matching the profile-sync endpoint).
Network, publisher-feed and synchronization failures are displayed explicitly.
Directory discovery is search-based, not Apple editorial charts or personalized
recommendations. Transcripts and notification scheduling are not implemented.

## Native YouTube / PsTube

The Home **YouTube** card opens a native screen styled after the supplied desktop
reference: sidebar navigation, integrated search, horizontal category chips,
responsive video grid, rounded thumbnails and channel metadata. It uses
MILLITOPTV's active theme; compact screens use a navigation drawer.

The engine is adapted from PsTube revision
`d5d193ab42e497b7eff8545d4b018ac5a6e6df16`, not a webview. See
[upstream provenance](third_party/pstube_engine/UPSTREAM.md). Search and stream
extraction use YouTubeExplode first with Piped fallback; trending and read-only
comments use Piped. The Piped API server can be changed in the screen's engine
settings. Public instance availability and YouTube extraction may change.

Features include native video playback, fullscreen, quality selection with
external audio for adaptive streams, playback speed, subtitles when available,
search pagination, channel browsing, public playlists, local subscriptions,
history/resume, Watch later, local likes, local playlists and offline combined
audio/video downloads. Adaptive-only and live downloads are explicitly rejected;
downloads are device-local and limited to 2 GB per video.

Local library changes and history use timestamp-based profile synchronization,
including deletion tombstones. Google-account libraries are not imported.
Category chips are topic searches or local history filters, not the official
YouTube personalized recommendation engine. Shorts displays short search
results, not YouTube's authenticated Shorts feed. Voice search, uploads,
notifications, paid/private content and comment posting are not provided.
Playback stops when leaving this screen.

Per the approved integration decision, this combined application is distributed
under [GPLv3](LICENSE), retaining upstream attribution and license notices.
Distributing binaries requires making the corresponding source and license
available as required by GPLv3; a private GitHub repository alone is not a public
source offer. Existing third-party dependencies retain their own licenses.

## Release builds and responsive layouts

### Playlists and Favorites

Home's **Playlists** section replaces Files. Its separate **Favorites** tab brings
together saved channels, movies, series, episodes, songs, podcast episodes and
liked YouTube videos for the active profile. Items open their native player or
series view with the original source and media identifiers. Search and media/source
filters work across the combined library, including cached data while offline.
Unavailable sources and sync failures are reported rather than playing a different
item.

Saved Music and Movies/TV playlists, podcast queues, YouTube playlists and Watch
later are visible alongside user-created mixed-media playlists. Source-owned lists
remain managed in their original apps; explicitly copy one to a global playlist
to edit a mixed-media version. Global playlists support naming, adding/removing
saved media, ordering and deletion. Favorites and playlist membership are separate.

**For you** ranks existing favorites using recent viewing/listening, artists,
channels/shows and music play counts. **Recently enjoyed** provides quick access
to existing history. Recommendations respect excluded music sessions, create no
new tracking, and never automatically edit saved playlists. Global playlists,
podcast/channel favorites and deletion records travel through the existing
profile-sync payload; offline changes remain on-device with explicit sync errors.

Files and folder management remain available under **Settings → General →
Your entertainment → Files**. DVR retains its existing Home section.

Settings switches to a category selector on compact screens; the desktop sidebar
scrolls on short windows. Live TV uses a vertical video/channel layout on phones,
with scrollable source/filter controls and a compact options menu. Movies/Series
filters, Music setup and expanded player, and Podcast episode rows adapt without
removing their existing actions. Tests exercise 320, 360 and 412 logical-pixel
phones, 740x360 landscape, and 1280x720 / 1920x1080 TV layouts across all six themes.
Logical dimensions are not device hardware pixel resolutions. Physical phone,
TV remote and populated-library playback checks are still needed before rollout.

Movies & Series shows a blocking loading modal immediately on entry and reload,
including while profile/source discovery is pending. It reports the current phase,
source, movie/series counts, elapsed time and a source-phase-based remaining-time
estimate. The modal closes when loading completes, fails, or finds no sources;
errors and setup guidance remain on the screen. Loading-modal tests cover the
phone, landscape and TV sizes above across all six themes.

Movies & Series filters use selectable pill buttons for Source and Media Type
(Movies/Series); Category remains a compact dropdown so long group lists don't
push the results grid off-screen. Genres (backfilled in bulk from TMDB alongside
posters/overviews, for M3U and managed sources only — Xtream catalogs skip bulk
enrichment to avoid long load times on large libraries) appear as multi-select
chips with a shuffle button that opens a random title from the current filter
selection. Sort adds "In Theaters" (closest to the current date by release date)
and "Recently Added" (newest `addedAt`/Xtream `added`/`last_modified` first).
Seasonal themed collections (Halloween, Thanksgiving, Christmas, and a Romance
example for February) are suggested automatically when their date window is
active, matching by TMDB genre or title/description/category keywords; selecting
one filters the grid to matching titles. All of this filtering runs in a single
pass over the catalog (group/version-count lookups are precomputed once) so
selecting a category or genre on large libraries stays responsive instead of
freezing.

Windows publication uses [the existing release pipeline](tools/README-release.md).
The Android APK is explicitly a **development-key-signed sideload/test build**;
do not uninstall an existing installation to work around a signature mismatch.
Dashboard Quick downloads provides the APK and GPLv3 corresponding-source ZIP.
Windows releases are registered paused; publication does not assign devices.
Android packages include the TV launcher/banner and do not require a touchscreen.
Weather location and media foreground-service permissions are declared; playback
uses the audio-service activity, releasing the foreground service when paused.

Source archives include the application's build inputs, adapted PsTube engine,
license and locked dependency versions, but exclude local SDK paths, keystores,
environment files and generated build caches. `SOURCE-MANIFEST.json` records
every included file hash. Use Flutter **3.47.9 / Dart 3.13.7**, Android SDK 37,
the Gradle wrapper/JDK 21, and Visual Studio 2022 C++ desktop tools on Windows:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release --build-name=2.1.0 --build-number=30
flutter build apk --release --build-name=2.1.0 --build-number=30
```

Use the version/build listed on the downloaded release and source manifest if
different. Flutter resolves plugin sources from `pubspec.lock`; those packages
retain their own licenses. Windows installer compilation additionally uses the
Inno Setup helper and signed Microsoft prerequisites described in the release
guide. Signing credentials are not required to compile the application.

## Getting Started

Home welcome sayings vary between profile visits and automatically rotate every
20 seconds with a short fade. The Apps panel no longer includes factory Emby or
VLC tiles. Emby remains available when configured as a console-managed web app;
legacy factory Emby overrides are excluded. VLC's existing file/DVR integrations
are unchanged.

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
