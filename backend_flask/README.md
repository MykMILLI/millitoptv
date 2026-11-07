# Immich Flask Proxy

This service provides authenticated proxy routes for the shared family album slideshow.

## Routes

- `GET /api/immich/shared-family-album`
- `GET /api/immich/assets/<id>/thumbnail`
- `GET /api/immich/assets/<id>/playback`
- `GET /api/immich/assets/<id>/original`

All routes require an authenticated session (`session["authenticated"]` or `session["user_id"]`).

## Required environment variables

- `IMMICH_EXTERNAL_URL`
- `IMMICH_API_KEY`
- `IMMICH_SHARED_ALBUM` (used when `IMMICH_SHARED_ALBUM_ID` is not set)
- `IMMICH_SHARED_ALBUM_ID` (preferred)
- `IMMICH_USER_ID` (optional owner filter when resolving by album name)
- `IMMICH_PROXY_SESSION_SECRET` (recommended)

## Run locally

```bash
pip install -r requirements.txt
python immich_proxy_app.py
```

## Tests

```bash
pytest -q
```
