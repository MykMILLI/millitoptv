import test from 'node:test';
import assert from 'node:assert/strict';
import { WatchPartyKeys, hashToken, newToken, newRelayKey, newJoinCode, turnCredentials, loadMasterSecret } from './watch-party-crypto.mjs';
import { rewritePlaylist, assertRelayTarget, isPlaylistResponse, looksLikeTransportStream, RelayError } from './watch-party-relay.mjs';
import { composeInvite } from './watch-party-mailer.mjs';
import * as v from './watch-party-validation.mjs';

test('relay blobs are sealed and tamper-evident', () => {
  const keys = new WatchPartyKeys('unit-test-secret-123');
  const blob = keys.sealRelay({ u: 'http://10.0.0.5/a.ts', p: 'party', r: 2 });
  assert.deepEqual(keys.openRelay(blob), { u: 'http://10.0.0.5/a.ts', p: 'party', r: 2 });
  assert.equal(keys.openRelay(blob.slice(0, -2) + (blob.endsWith('AA') ? 'BB' : 'AA')), null);
  assert.equal(new WatchPartyKeys('another-secret-456').openRelay(blob), null);
  assert.equal(keys.openSetting(blob), null, 'relay and settings keys are separate');
});

test('tokens, codes and relay keys have the expected shapes', () => {
  assert.match(newToken('wp_'), /^wp_[A-Za-z0-9_-]{43}$/);
  assert.match(newRelayKey(), /^[A-Za-z0-9_-]{24}$/);
  for (let i = 0; i < 200; i += 1) assert.match(newJoinCode(), /^[A-HJ-NP-Z2-9]{8}$/);
  assert.equal(hashToken('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

test('master secret prefers WATCH_PARTY_SECRET then db_password', () => {
  assert.equal(loadMasterSecret({ env: { WATCH_PARTY_SECRET: ' explicit ' }, read: () => 'db' }), 'explicit');
  assert.equal(loadMasterSecret({ env: {}, read: () => 'dbsecret\n' }), 'dbsecret');
  assert.throws(() => loadMasterSecret({ env: {}, read: () => { throw new Error('missing'); } }));
});

test('coturn REST credentials', () => {
  const creds = turnCredentials('secret', 'pid', 3600, 1_000_000_000);
  assert.equal(creds.username, `${1_000_000 + 3600}:pid`);
  assert.match(creds.credential, /^[A-Za-z0-9+/]+=*$/);
});

test('HLS playlists are rewritten through the relay', () => {
  const source = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:4,\nseg0.ts\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttp://other.example/v/index.m3u8?x=1\n';
  const calls = [];
  const out = rewritePlaylist(source, 'http://jf.local:8096/videos/1/main.m3u8?api_key=k', (url, playlist) => { calls.push([url, playlist]); return `/R${calls.length}`; });
  assert.ok(out.includes('URI="/R1"'));
  assert.ok(out.includes('URI="/R2"'));
  assert.deepEqual(calls[2], ['http://jf.local:8096/videos/1/seg0.ts', false]);
  assert.deepEqual(calls[3], ['http://other.example/v/index.m3u8?x=1', true]);
  assert.ok(!out.includes('api_key'), 'upstream credentials never reach guests');
});

test('content sniffing', () => {
  assert.equal(isPlaylistResponse('http://x/a', 'text/plain', Buffer.from('#EXTM3U\n')), true);
  assert.equal(isPlaylistResponse('http://x/a', 'text/plain', Buffer.from('\uFEFF#EXTM3U\n')), true);
  assert.equal(isPlaylistResponse('http://x/movie.mkv', 'video/x-matroska', Buffer.from([0x1a, 0x45])), false);
  assert.equal(looksLikeTransportStream('http://x/live', 'application/octet-stream', (() => { const b = Buffer.alloc(188 * 3); b[0] = b[188] = b[376] = 0x47; return b; })()), true);
});

test('relay target guard blocks loopback, link-local and multicast but allows LAN', async () => {
  for (const url of ['http://127.0.0.1/x', 'http://169.254.169.254/latest', 'http://[::1]/x', 'http://224.0.0.1/x', 'file:///etc/passwd']) {
    await assert.rejects(assertRelayTarget(url), RelayError, url);
  }
  await assertRelayTarget('http://192.168.1.20:8096/x');
  await assertRelayTarget('http://jellyfin.lan/x', async () => [{ address: '10.0.0.9' }]);
  await assert.rejects(assertRelayTarget('http://evil.example/x', async () => [{ address: '10.0.0.9' }, { address: '127.0.0.1' }]), RelayError);
});

test('validation', () => {
  assert.equal(v.joinCode(' abcd2345 '), 'ABCD2345');
  assert.throws(() => v.joinCode('ABC'), v.ValidationError);
  assert.deepEqual(v.emailList('a@x.com, b@y.org; a@x.com'), ['a@x.com', 'b@y.org']);
  assert.throws(() => v.media({ kind: 'movie', title: 'x' }), /stream URL/);
  assert.throws(() => v.media({ kind: 'youtube', title: 'x', youtubeId: 'bad' }), /YouTube/);
  const parsed = v.media({ kind: 'movie', title: 'Film', upstream: { url: 'http://10.0.0.2/a.m3u8', headers: { 'X-Emby-Token': 't', Cookie: 'drop' } } });
  assert.deepEqual(parsed.upstream.headers, { 'x-emby-token': 't' });
  assert.equal(parsed.publicMedia.upstream, undefined, 'upstream never part of public media');
  assert.throws(() => v.playback({ mediaRev: 1, positionMs: -1 }), v.ValidationError);
  assert.equal(v.smtpSettings({ host: 'smtp.x', port: 587, security: 'starttls', fromEmail: 'a@x.com', password: '' }).password, undefined);
  assert.throws(() => v.voiceSettings({ turnUrls: 'http://bad' }), /TURN/);
  assert.equal(v.limitSettings({}).maxParticipants, 12);
});

test('invite email escapes user content', () => {
  const mail = composeInvite({ hostName: '<b>Host</b>', partyTitle: 'Night & Day', nowPlaying: 'Film', joinUrl: 'https://tvadmin.millitop.net/watch/ABCD2345?invite=wi_x', code: 'ABCD2345', note: '<script>' });
  assert.ok(!mail.html.includes('<script>'));
  assert.ok(mail.html.includes('&lt;b&gt;Host&lt;/b&gt;'));
  assert.ok(mail.text.includes('https://tvadmin.millitop.net/watch/ABCD2345?invite=wi_x'));
});
