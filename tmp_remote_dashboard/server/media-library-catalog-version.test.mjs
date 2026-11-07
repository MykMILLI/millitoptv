import test from 'node:test';
import assert from 'node:assert/strict';
import { catalogResponse, catalogVersionOf } from './media-library-routes.mjs';

const libraries = [{ id: 'lib-1', name: 'Movies', items: [{ id: 'a', title: 'Alpha', path: '//nas/movies/alpha.mkv' }] }];

test('catalog includes a stable version', () => {
  const first = catalogResponse({ body: {} }, 1, libraries);
  assert.equal(first.catalogVersion, catalogVersionOf(1, libraries));
  assert.deepEqual(first.libraries, libraries);
  assert.equal(catalogResponse({ body: {} }, 1, structuredClone(libraries)).catalogVersion, first.catalogVersion);
});

test('matching version returns unchanged without libraries', () => {
  const version = catalogVersionOf(1, libraries);
  const reply = catalogResponse({ body: { catalogVersion: version } }, 1, libraries, { fallback: true });
  assert.equal(reply.unchanged, true);
  assert.equal(reply.libraries, undefined);
  assert.equal(reply.fallback, true);
});

test('any library change or other profile produces a new version', () => {
  const version = catalogVersionOf(1, libraries);
  const changed = structuredClone(libraries);
  changed[0].items.push({ id: 'b', title: 'Beta', path: '//nas/movies/beta.mkv' });
  assert.notEqual(catalogVersionOf(1, changed), version);
  assert.notEqual(catalogVersionOf(2, libraries), version);
  const reply = catalogResponse({ body: { catalogVersion: version } }, 1, changed);
  assert.equal(reply.unchanged, undefined);
  assert.equal(reply.libraries.length, 1);
});
