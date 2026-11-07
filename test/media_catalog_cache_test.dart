import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/live_tv_playlist.dart';
import 'package:millitop_tv/services/live_tv_source.dart';
import 'package:millitop_tv/services/media_catalog_cache.dart';

void main() {
  late Directory dir;
  setUp(() async {
    MediaCatalogCache.resetMemoryForTest();
    dir = await Directory.systemTemp.createTemp('catalog-cache');
  });
  tearDown(() async {
    MediaCatalogCache.resetMemoryForTest();
    await dir.delete(recursive: true);
  });

  const source = LiveTvSource(
    id: 'src-1',
    name: 'Provider',
    type: 'xtream',
    serverUrl: 'http://provider.example',
    username: 'user',
    password: 'pass',
  );
  const movie = LiveTvMediaItem(
    id: 'm1',
    title: 'Alpha',
    streamUrl: 'http://provider.example/movie/1.mkv',
    posterUrl: 'http://img/alpha.jpg',
    genres: ['Drama'],
    year: 2020,
  );

  test('catalog survives an app restart (disk round trip)', () async {
    final cache = MediaCatalogCache(directory: () async => dir);
    await cache.saveSource(1, source, movies: [movie], series: const []);
    MediaCatalogCache.resetMemoryForTest();
    final entry = await MediaCatalogCache(
      directory: () async => dir,
    ).source(1, source);
    expect(entry, isNotNull);
    expect(entry!.movies.single.title, 'Alpha');
    expect(entry.movies.single.genres, ['Drama']);
    expect(entry.movies.single.year, 2020);
  });

  test('editing the source login invalidates its cache', () async {
    final cache = MediaCatalogCache(directory: () async => dir);
    await cache.saveSource(1, source, movies: [movie], series: const []);
    expect(await cache.source(1, source.copyWith(password: 'changed')), isNull);
    expect(await cache.source(2, source), isNull);
  });

  test('fresh lists keep enriched metadata and pick up new titles', () {
    const bare = LiveTvMediaItem(
      id: 'm1',
      title: 'Alpha',
      streamUrl: 'http://provider.example/movie/1.mkv',
    );
    const added = LiveTvMediaItem(
      id: 'm2',
      title: 'Beta',
      streamUrl: 'http://provider.example/movie/2.mkv',
    );
    final merged = MediaCatalogCache.mergeKeepingMetadata(
      [bare, added],
      [movie],
    );
    expect(merged.first.posterUrl, 'http://img/alpha.jpg');
    expect(merged.first.genres, ['Drama']);
    expect(merged.last.id, 'm2');
    expect(
      MediaCatalogCache.signature([movie], const []),
      isNot(MediaCatalogCache.signature(merged, const [])),
    );
  });

  test('managed catalog is tied to the paired connection', () async {
    final cache = MediaCatalogCache(directory: () async => dir);
    await cache.saveManagedCatalog(1, 'conn-a', {
      'libraries': [],
    }, version: 'v1');
    expect((await cache.managedCatalog(1, 'conn-a'))!.version, 'v1');
    expect(await cache.managedCatalog(1, 'conn-b'), isNull);
    final raw = await File(
      '${dir.path}/media_catalog_cache/profile-1.json',
    ).readAsString();
    expect(raw.contains('conn-a'), isFalse);
  });
}
