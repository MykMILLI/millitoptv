from typing import Dict, List, Optional

from immich_proxy_app import ImmichConfig, create_app


class FakeStreamResponse:
  def __init__(self, status_code: int, headers: Dict[str, str], chunks: List[bytes]):
    self.status_code = status_code
    self.headers = headers
    self._chunks = chunks

  def iter_content(self, chunk_size: int = 65536):
    del chunk_size
    for chunk in self._chunks:
      yield chunk


class FakeClient:
  def __init__(self):
    self.search_pages: Dict[int, Dict] = {}
    self.last_range_header: Optional[str] = None
    self.searched_album_ids: List[str] = []

  def list_albums(self):
    return [
      {"id": "album-001", "albumName": "Family", "ownerId": "user-1"},
      {"id": "album-002", "albumName": "Other", "ownerId": "user-1"},
    ]

  def search_metadata(self, album_id: str, page: int, size: int = 500):
    self.searched_album_ids.append(album_id)
    assert size == 500
    return self.search_pages.get(
      page,
      {"assets": {"items": []}},
    )

  def fetch_thumbnail(self, asset_id: str):
    class Thumb:
      status_code = 200
      content = b"thumb-bytes"
      headers = {"Content-Type": "image/jpeg", "Cache-Control": "public,max-age=120"}

    assert asset_id
    return Thumb()

  def stream_asset(self, asset_id: str, variant: str, range_header: Optional[str]):
    assert asset_id == "asset-1"
    assert variant in {"playback", "original"}
    self.last_range_header = range_header
    return FakeStreamResponse(
      206,
      {
        "Content-Type": "video/mp4",
        "Accept-Ranges": "bytes",
        "Content-Length": "4",
        "Content-Range": "bytes 0-3/10",
      },
      [b"test"],
    )


def build_client(fake: FakeClient):
  app = create_app(
    config_override=ImmichConfig(
      external_url="https://immich.example.com",
      api_key="abc123",
      shared_album_name="Family",
      shared_album_id="",
      user_id="user-1",
    ),
    client_override=fake,
  )
  app.config["TESTING"] = True
  return app.test_client()


def authenticate(client):
  with client.session_transaction() as session:
    session["authenticated"] = True


def test_shared_album_pagination_dedupes_and_filters():
  fake = FakeClient()
  fake.search_pages = {
    0: {
      "assets": {
        "items": [
          {"id": "asset-1", "type": "IMAGE", "originalFileName": "one.jpg"},
          {"id": "asset-2", "type": "VIDEO", "originalFileName": "two.mp4"},
          {"id": "asset-1", "type": "IMAGE", "originalFileName": "dup.jpg"},
          {"id": "asset-3", "type": "AUDIO", "originalFileName": "skip.mp3"},
        ]
      }
    },
    1: {"assets": {"items": []}},
  }
  client = build_client(fake)
  authenticate(client)

  response = client.get("/api/immich/shared-family-album")
  assert response.status_code == 200
  data = response.get_json()
  assert data["albumId"] == "album-001"
  assert data["albumName"] == "Family"
  assert [asset["id"] for asset in data["assets"]] == ["asset-1", "asset-2"]
  assert all("thumbnailUrl" in asset for asset in data["assets"])
  assert all("playbackUrl" in asset for asset in data["assets"])
  assert all("originalUrl" in asset for asset in data["assets"])


def test_playback_proxy_forwards_range_and_preserves_206_headers():
  fake = FakeClient()
  client = build_client(fake)
  authenticate(client)

  response = client.get(
    "/api/immich/assets/asset-1/playback",
    headers={"Range": "bytes=0-3"},
  )
  assert response.status_code == 206
  assert fake.last_range_header == "bytes=0-3"
  assert response.headers["Accept-Ranges"] == "bytes"
  assert response.headers["Content-Length"] == "4"
  assert response.headers["Content-Range"] == "bytes 0-3/10"
  assert response.data == b"test"


def test_routes_require_authenticated_session():
  fake = FakeClient()
  client = build_client(fake)
  response = client.get("/api/immich/shared-family-album")
  assert response.status_code == 401


def test_shared_album_accepts_album_id_overrides():
  fake = FakeClient()
  fake.search_pages = {
    0: {"assets": {"items": []}},
  }
  client = build_client(fake)
  authenticate(client)
  response = client.get(
    "/api/immich/shared-family-album",
    headers={"X-Immich-Album-Ids": "alpha,beta"},
  )
  assert response.status_code == 200
  assert fake.searched_album_ids.count("alpha") == 1
  assert fake.searched_album_ids.count("beta") == 1


def test_albums_route_filters_and_sorts():
  fake = FakeClient()
  client = build_client(fake)
  authenticate(client)
  response = client.get("/api/immich/albums")
  assert response.status_code == 200
  data = response.get_json()
  assert "albums" in data
  assert data["albums"][0]["id"] == "album-001"
