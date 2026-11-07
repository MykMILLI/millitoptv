# PsTube engine provenance

Derived from [prateekmedia/pstube](https://github.com/prateekmedia/pstube),
revision `d5d193ab42e497b7eff8545d4b018ac5a6e6df16`, under GPLv3.
Copyright remains with PsTube's original contributors.

This package adapts the stream extraction, metadata conversion, search and
YouTubeExplode-first/Piped-fallback flow from:

- `lib/foundation/services/youtube_explode_dart_service.dart`
- `lib/foundation/services/youtube_service.dart`
- `lib/foundation/services/piped_service.dart`
- `lib/foundation/services/piped_instances.dart`

Modifications for MILLITOPTV:

- Removes upstream UI, Riverpod/global state and generated Piped models.
- Uses typed transport models and the same Piped HTTP contracts.
- Updates YouTubeExplode to 3.1.0 and uses its public API.
- Preserves search pagination, supplies explicit errors instead of silent nulls,
  and exposes configurable Piped server, channels, playlists and subtitles.
- Leaves profile data, playback and UI in the host application.

This is an adapted engine, not an unmodified copy of the entire PsTube app.
No Google authentication, uploads, private/purchased content, comment posting
or official YouTube-account subscriptions are provided.
