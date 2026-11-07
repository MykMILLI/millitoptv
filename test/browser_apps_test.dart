import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:millitop_tv/services/web_app_definition.dart';
import 'package:millitop_tv/services/web_app_catalog.dart';
import 'package:millitop_tv/screens/home_app_tiles.dart';

const appId = '11111111-1111-4111-8111-111111111111';

class FakeManaged implements ManagedWebAppSource {
  @override
  String key = 'test/device-a';
  @override
  bool allowed = true;
  List<WebAppDefinition> apps = [];
  bool fail = false;
  @override
  Future<List<WebAppDefinition>> fetch() async {
    if (fail) {
      throw StateError('offline');
    }
    return apps;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final url in [
    'https://example.com',
    'http://192.168.1.10:8096',
    'http://10.0.0.1',
    'http://172.16.0.1',
    'http://localhost:8080',
    'http://nas.local',
    'http://[::1]:8096',
  ]) {
    test('allows web app $url', () => expect(validateAppUrl(url), isNotEmpty));
  }
  for (final url in [
    'javascript:alert(1)',
    'file:///C:/private',
    'data:text/html,test',
    'ftp://example.com',
    'http://example.com',
    'https://user:pass@example.com',
    'https://example.com/?token=secret',
    'https://example.com/#access_token=secret',
  ]) {
    test(
      'rejects unsafe web app $url',
      () => expect(() => validateAppUrl(url), throwsFormatException),
    );
  }
  test('web-app model rejects invalid IDs, icons and Boolean values', () {
    final base = {
      'id': 'emby',
      'title': 'Cinema',
      'url': 'https://example.com',
      'icon': 'emby',
      'enabled': true,
      'revision': 1,
    };
    expect(WebAppDefinition.fromJson(base).builtin, isTrue);
    expect(
      () => WebAppDefinition.fromJson({...base, 'id': 'managed:bad'}),
      throwsFormatException,
    );
    expect(
      () => WebAppDefinition.fromJson({...base, 'icon': 'remote-image'}),
      throwsFormatException,
    );
    expect(
      () => WebAppDefinition.fromJson({...base, 'enabled': 'yes'}),
      throwsFormatException,
    );
  });
  test(
    'local edits/reset are per profile and preserve factory identity',
    () async {
      final source = FakeManaged()..allowed = false;
      final catalog = WebAppCatalog(source: source);
      await catalog.save(
        1,
        id: 'jellyfin',
        title: 'Our Cinema',
        url: 'http://192.168.1.10:8096',
        icon: 'jellyfin',
      );
      final local = await catalog.load(1);
      expect(local.firstWhere((a) => a.id == 'jellyfin').title, 'Our Cinema');
      expect(
        (await catalog.load(2)).firstWhere((a) => a.id == 'jellyfin').title,
        'Jellyfin',
      );
      await catalog.removeOrReset(1, local.firstWhere((a) => a.id == 'jellyfin'));
      expect(
        (await catalog.load(1)).firstWhere((a) => a.id == 'jellyfin').title,
        'Jellyfin',
      );
      catalog.dispose();
    },
  );
  test(
    'custom URL apps can be added, hidden and removed without affecting builtins',
    () async {
      final catalog = WebAppCatalog(source: FakeManaged()..allowed = false);
      await catalog.save(1, title: 'Family site', url: 'https://example.com');
      final app = (await catalog.load(
        1,
      )).firstWhere((a) => a.title == 'Family site');
      expect(app.id, startsWith('local:'));
      await catalog.save(
        1,
        id: app.id,
        title: app.title,
        url: app.url,
        enabled: false,
      );
      expect((await catalog.load(1)).any((a) => a.id == app.id), isFalse);
      expect(
        (await catalog.load(1, includeHidden: true)).any((a) => a.id == app.id),
        isTrue,
      );
      await catalog.removeOrReset(1, app);
      expect((await catalog.load(1, includeHidden: true)).length, 1);
      catalog.dispose();
    },
  );
  test(
    'managed sync replaces rows and is hidden after revocation or device change',
    () async {
      final source = FakeManaged()
        ..apps = [
          const WebAppDefinition(
            id: 'managed:$appId',
            title: 'Managed',
            url: 'https://example.com',
            managed: true,
          ),
        ];
      final catalog = WebAppCatalog(source: source);
      await catalog.sync();
      expect((await catalog.load(1)).any((a) => a.managed), isTrue);
      source.apps = [];
      await catalog.sync();
      expect((await catalog.load(1)).any((a) => a.managed), isFalse);
      source.apps = [
        const WebAppDefinition(
          id: 'managed:$appId',
          title: 'Managed',
          url: 'https://example.com',
          managed: true,
        ),
      ];
      await catalog.sync();
      source.allowed = false;
      expect((await catalog.load(1)).any((a) => a.managed), isFalse);
      source.allowed = true;
      source.key = 'test/device-b';
      expect((await catalog.load(1)).any((a) => a.managed), isFalse);
      catalog.dispose();
    },
  );
  test('managed app definitions cannot be locally rewritten', () async {
    final catalog = WebAppCatalog(source: FakeManaged());
    await expectLater(
      catalog.save(
        1,
        id: 'managed:$appId',
        title: 'Rewrite',
        url: 'https://example.com',
      ),
      throwsA(anything),
    );
    await expectLater(
      catalog.removeOrReset(
        1,
        const WebAppDefinition(
          id: 'managed:$appId',
          title: 'Managed',
          url: 'https://example.com',
          managed: true,
        ),
      ),
      throwsStateError,
    );
    catalog.dispose();
  });
  testWidgets(
    'home keeps native and default web app tiles and exposes add action',
    (tester) async {
      final catalog = WebAppCatalog(source: FakeManaged()..allowed = false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HomeAppTiles(profileId: 1, catalog: catalog),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      for (final title in [
        'Live TV',
        'Podcasts',
        'YouTube',
        'Jellyfin',
        'Add URL app',
      ]) {
        expect(find.text(title), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      catalog.dispose();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
  test('corrupt local app settings are not silently overwritten', () async {
    SharedPreferences.setMockInitialValues({'webapps.local.v1.1': 'not json'});
    final catalog = WebAppCatalog(source: FakeManaged()..allowed = false);
    await expectLater(catalog.load(1), throwsA(anything));
    expect(
      (await SharedPreferences.getInstance()).getString('webapps.local.v1.1'),
      'not json',
    );
    catalog.dispose();
  });
}
