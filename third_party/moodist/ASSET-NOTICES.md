Moodist sleep-sound asset manifest (pinned import)
==================================================

Source repository: https://github.com/remvze/moodist
Pinned upstream commit: `11c0be2200116a3635880d600fd6953899cc51a3`

Upstream code references inspected:
- `src/hooks/use-sound.ts`
- `src/components/sounds/sound/sound.tsx`
- `src/data/sounds/rain.tsx`
- `src/data/sounds/noise.tsx`
- `src/helpers/path.ts`

Selected local assets bundled in this repository:

| Local path | Upstream path | Size (bytes) | SHA-256 |
|---|---|---:|---|
| `assets/native/sleep_sounds/moodist/rain/heavy-rain.mp3` | `public/sounds/rain/heavy-rain.mp3` | 541741 | `6910161b347a4f616bc42d0b3118982c243d149fe45e55fef74c9a9e1aa08560` |
| `assets/native/sleep_sounds/moodist/rain/thunder.mp3` | `public/sounds/rain/thunder.mp3` | 2193449 | `c96dde1068d5c96a40ad47cccc767a88d907b3d3fdcb84819e18b81dcd6bd2bd` |
| `assets/native/sleep_sounds/moodist/noise/white-noise.wav` | `public/sounds/noise/white-noise.wav` | 1676232 | `02ccb2013118b57c76607f7e3e5d9d479e5a9aaa7868e1a07194cde77c0ea6dd` |
| `assets/native/sleep_sounds/moodist/noise/pink-noise.wav` | `public/sounds/noise/pink-noise.wav` | 1676972 | `075eecefd60c4103da3ec8672db1c96ba54f073f8a5bc4e7cc1b587c96854fb4` |

Howler runtime bundled locally:

| Local path | Upstream source | Size (bytes) | SHA-256 |
|---|---|---:|---|
| `assets/native/sleep_sounds/howler/howler-2.2.4.min.js` | `https://unpkg.com/howler@2.2.4/dist/howler.min.js` | 36173 | `736c339444c88baad593e24afdf1d6e8f574019b4e37a110ecb453ff745ffd41` |

License notes
-------------

- Moodist code is MIT licensed (`third_party/moodist/LICENSE`).
- Howler.js is MIT licensed (`third_party/howler/LICENSE.md`).
- Moodist upstream README states some sound files are third-party and may be under Pixabay Content License and/or CC0.
- Upstream does not provide per-file provenance/license mapping in-repo for these four files; this repository therefore preserves upstream attribution context but cannot assert a file-by-file source provider beyond Moodist’s published statement.
