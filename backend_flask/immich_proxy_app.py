import os
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional

import requests
from flask import Flask, Response, jsonify, request, session, stream_with_context
from werkzeug.exceptions import BadGateway, InternalServerError, Unauthorized


class ImmichProxyError(Exception):
  pass


@dataclass(frozen=True)
class ImmichConfig:
  external_url: str
  api_key: str
  shared_album_name: str
  shared_album_id: str
  user_id: str

  @staticmethod
  def from_env() -> "ImmichConfig":
    return ImmichConfig(
      external_url=os.getenv("IMMICH_EXTERNAL_URL", "").strip().rstrip("/"),
      api_key=os.getenv("IMMICH_API_KEY", "").strip(),
      shared_album_name=os.getenv("IMMICH_SHARED_ALBUM", "").strip(),
      shared_album_id=os.getenv("IMMICH_SHARED_ALBUM_ID", "").strip(),
      user_id=os.getenv("IMMICH_USER_ID", "").strip(),
    )


class ImmichHttpClient:
  def __init__(self, config: ImmichConfig):
    if not config.external_url:
      raise ImmichProxyError("IMMICH_EXTERNAL_URL is required.")
    if not config.api_key:
      raise ImmichProxyError("IMMICH_API_KEY is required.")
    self._config = config
    self._session = requests.Session()
    self._session.headers.update(
      {
        "accept": "application/json",
        "x-api-key": self._config.api_key,
      }
    )

  def _url(self, path: str) -> str:
    return f"{self._config.external_url}{path}"

  def list_albums(self) -> List[Dict]:
    response = self._session.get(self._url("/api/albums"), timeout=20)
    if response.status_code < 200 or response.status_code >= 300:
      raise ImmichProxyError(
        f"Immich albums request failed with status {response.status_code}."
      )
    payload = response.json()
    if not isinstance(payload, list):
      raise ImmichProxyError("Immich albums response is invalid.")
    return payload

  def search_metadata(self, album_id: str, page: int, size: int = 500) -> Dict:
    payload = {
      "size": size,
      "page": page,
      "albumIds": [album_id],
      "withArchived": False,
    }
    response = self._session.post(
      self._url("/api/search/metadata"),
      json=payload,
      timeout=30,
    )
    if response.status_code < 200 or response.status_code >= 300:
      raise ImmichProxyError(
        f"Immich metadata request failed with status {response.status_code}."
      )
    body = response.json()
    if not isinstance(body, dict):
      raise ImmichProxyError("Immich metadata response is invalid.")
    return body

  def fetch_thumbnail(self, asset_id: str) -> requests.Response:
    response = self._session.get(
      self._url(f"/api/assets/{asset_id}/thumbnail"),
      timeout=30,
    )
    if response.status_code < 200 or response.status_code >= 300:
      raise ImmichProxyError(
        f"Immich thumbnail request failed with status {response.status_code}."
      )
    return response

  def stream_asset(self, asset_id: str, variant: str, range_header: Optional[str]) -> requests.Response:
    headers = {}
    if range_header:
      headers["Range"] = range_header
    suffix = "/video/playback" if variant == "playback" else "/original"
    response = self._session.get(
      self._url(f"/api/assets/{asset_id}{suffix}"),
      headers=headers,
      stream=True,
      timeout=60,
    )
    if response.status_code not in (200, 206):
      raise ImmichProxyError(
        f"Immich {variant} request failed with status {response.status_code}."
      )
    return response


def require_authenticated_session() -> None:
  # Session-auth gate required by spec.
  if not session.get("authenticated") and not session.get("user_id"):
    raise Unauthorized("Authenticated session required.")


def _resolve_album(config: ImmichConfig, client: ImmichHttpClient) -> Dict[str, str]:
  album_id = config.shared_album_id
  album_name = config.shared_album_name

  if album_id:
    return {"id": album_id, "name": album_name or album_id}

  if not album_name:
    raise InternalServerError(
      "IMMICH_SHARED_ALBUM_ID or IMMICH_SHARED_ALBUM must be configured."
    )

  albums = client.list_albums()
  for entry in albums:
    if not isinstance(entry, dict):
      continue
    current_id = str(entry.get("id", "")).strip()
    current_name = str(entry.get("albumName", "")).strip()
    owner_id = str(entry.get("ownerId", "")).strip()
    if not current_id or not current_name:
      continue
    if current_name != album_name:
      continue
    if config.user_id and owner_id and owner_id != config.user_id:
      continue
    return {"id": current_id, "name": current_name}

  raise InternalServerError("Configured shared album could not be resolved.")


def _load_album_assets(client: ImmichHttpClient, album_ids: List[str]) -> List[Dict[str, str]]:
  seen = set()
  results: List[Dict[str, str]] = []
  for album_id in album_ids:
    page = 0
    while True:
      payload = client.search_metadata(album_id=album_id, page=page, size=500)
      assets = payload.get("assets", {})
      if not isinstance(assets, dict):
        break
      items = assets.get("items", [])
      if not isinstance(items, list) or not items:
        break
      for item in items:
        if not isinstance(item, dict):
          continue
        asset_id = str(item.get("id", "")).strip()
        asset_type = str(item.get("type", "")).strip().upper()
        filename = str(item.get("originalFileName", "")).strip()
        if not asset_id or not filename:
          continue
        if asset_type not in {"IMAGE", "VIDEO"}:
          continue
        if asset_id in seen:
          continue
        seen.add(asset_id)
        results.append(
          {"id": asset_id, "type": asset_type, "filename": filename}
        )
      if len(items) < 500:
        break
      page += 1
  return results


def _stream_proxy(response: requests.Response) -> Iterable[bytes]:
  for chunk in response.iter_content(chunk_size=65536):
    if chunk:
      yield chunk


def create_app(
  config_override: Optional[ImmichConfig] = None,
  client_override: Optional[ImmichHttpClient] = None,
) -> Flask:
  app = Flask(__name__)
  app.secret_key = os.getenv("IMMICH_PROXY_SESSION_SECRET", "change-me")
  config = config_override or ImmichConfig.from_env()

  def request_config() -> ImmichConfig:
    return ImmichConfig(
      external_url=request.headers.get("X-Immich-External-Url", "").strip()
      or config.external_url,
      api_key=request.headers.get("X-Immich-Api-Key", "").strip() or config.api_key,
      shared_album_name=request.headers.get("X-Immich-Album-Name", "").strip()
      or config.shared_album_name,
      shared_album_id=request.headers.get("X-Immich-Album-Id", "").strip()
      or config.shared_album_id,
      user_id=request.headers.get("X-Immich-User-Id", "").strip() or config.user_id,
    )

  def request_client() -> ImmichHttpClient:
    return client_override or ImmichHttpClient(request_config())

  @app.errorhandler(ImmichProxyError)
  def handle_proxy_error(error: ImmichProxyError):
    return jsonify({"error": str(error)}), 502

  @app.get("/api/immich/shared-family-album")
  def shared_family_album():
    require_authenticated_session()
    cfg = request_config()
    client = request_client()
    raw_album_ids = request.headers.get("X-Immich-Album-Ids", "").strip()
    album_ids = [
      value.strip()
      for value in raw_album_ids.split(",")
      if value.strip()
    ]
    album_name = cfg.shared_album_name
    if not album_ids:
      album = _resolve_album(cfg, client)
      album_ids = [album["id"]]
      album_name = album["name"]
    assets = _load_album_assets(client, album_ids)
    enriched_assets = [
      {
        **asset,
        "thumbnailUrl": f"/api/immich/assets/{asset['id']}/thumbnail",
        "playbackUrl": f"/api/immich/assets/{asset['id']}/playback",
        "originalUrl": f"/api/immich/assets/{asset['id']}/original",
      }
      for asset in assets
    ]
    return jsonify(
      {
        "albumId": album_ids[0],
        "albumIds": album_ids,
        "albumName": album_name,
        "assets": enriched_assets,
      }
    )

  @app.get("/api/immich/albums")
  def list_albums():
    require_authenticated_session()
    cfg = request_config()
    client = request_client()
    albums = client.list_albums()
    values = []
    for entry in albums:
      if not isinstance(entry, dict):
        continue
      album_id = str(entry.get("id", "")).strip()
      album_name = str(entry.get("albumName", "")).strip()
      if not album_id or not album_name:
        continue
      owner_id = str(entry.get("ownerId", "")).strip()
      if cfg.user_id and owner_id and owner_id != cfg.user_id:
        continue
      asset_count = entry.get("assetCount", 0)
      try:
        count = int(asset_count)
      except (TypeError, ValueError):
        count = 0
      values.append({"id": album_id, "name": album_name, "assetCount": count})
    values.sort(key=lambda item: item["name"].lower())
    return jsonify({"albums": values})

  @app.get("/api/immich/assets/<asset_id>/thumbnail")
  def asset_thumbnail(asset_id: str):
    require_authenticated_session()
    client = request_client()
    upstream = client.fetch_thumbnail(asset_id)
    response = Response(upstream.content, status=upstream.status_code)
    content_type = upstream.headers.get("Content-Type")
    if content_type:
      response.headers["Content-Type"] = content_type
    cache_control = upstream.headers.get("Cache-Control")
    if cache_control:
      response.headers["Cache-Control"] = cache_control
    return response

  @app.get("/api/immich/assets/<asset_id>/playback")
  def asset_playback(asset_id: str):
    require_authenticated_session()
    client = request_client()
    range_header = request.headers.get("Range")
    upstream = client.stream_asset(asset_id, "playback", range_header)
    response = Response(
      stream_with_context(_stream_proxy(upstream)),
      status=upstream.status_code,
      direct_passthrough=True,
    )
    for header in ("Content-Type", "Accept-Ranges", "Content-Length", "Content-Range"):
      value = upstream.headers.get(header)
      if value:
        response.headers[header] = value
    return response

  @app.get("/api/immich/assets/<asset_id>/original")
  def asset_original(asset_id: str):
    require_authenticated_session()
    client = request_client()
    range_header = request.headers.get("Range")
    upstream = client.stream_asset(asset_id, "original", range_header)
    response = Response(
      stream_with_context(_stream_proxy(upstream)),
      status=upstream.status_code,
      direct_passthrough=True,
    )
    for header in ("Content-Type", "Accept-Ranges", "Content-Length", "Content-Range"):
      value = upstream.headers.get(header)
      if value:
        response.headers[header] = value
    return response

  @app.get("/api/immich/health")
  def health():
    return jsonify({"status": "ok"})

  return app


if __name__ == "__main__":
  create_app().run(host="0.0.0.0", port=int(os.getenv("PORT", "8090")))
