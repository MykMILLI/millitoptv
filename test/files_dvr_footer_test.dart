import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:millitop_tv/library/library_models.dart';
import 'package:millitop_tv/library/library_repository.dart';
import 'package:millitop_tv/library/library_file_service.dart';
import 'package:millitop_tv/screens/media_library_home.dart';
import 'package:millitop_tv/screens/library_browser_screen.dart';
import 'package:millitop_tv/widgets/launcher_footer.dart';
import 'package:millitop_tv/profiles/profile_gate.dart';
import 'package:millitop_tv/profiles/household_store.dart';

LibraryFolder folder(String path, {bool recordings = false}) => LibraryFolder(
  id: '11111111-1111-4111-8111-111111111111',
  label: 'Test folder',
  path: path,
  recordings: recordings,
);

class WidgetFiles extends LibraryFileService {
  final List<LibraryItem> entries;
  WidgetFiles(this.entries);
  @override
  Future<LibrarySnapshot> browse(LibraryFolder folder, String path) async =>
      LibrarySnapshot(path, entries);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('file types distinguish media from executable/playlist shortcuts', () {
    expect(libraryMediaKind('recording.TS'), LibraryMediaKind.video);
    expect(libraryMediaKind('music.FLAC'), LibraryMediaKind.audio);
    expect(libraryMediaKind('photo.JPEG'), LibraryMediaKind.image);
    for (final name in [
      'run.exe',
      'run.ps1',
      'run.cmd',
      'remote.url',
      'playlist.m3u8',
      'shortcut.lnk',
    ]) {
      expect(libraryMediaKind(name), LibraryMediaKind.unsupported);
    }
  });
  test('Windows containment rejects sibling-prefix and traversal paths', () {
    final windows = p.Context(style: p.Style.windows);
    expect(
      libraryContains(r'C:\Videos', r'C:\Videos\movie.mp4', context: windows),
      isTrue,
    );
    expect(
      libraryContains(r'C:\Videos', r'C:\Videos2\movie.mp4', context: windows),
      isFalse,
    );
    expect(
      libraryContains(
        r'C:\Videos',
        r'C:\Videos\..\Secrets\movie.mp4',
        context: windows,
      ),
      isFalse,
    );
    expect(
      libraryContains(
        r'\\server\share',
        r'\\server\share\DVR',
        context: windows,
      ),
      isTrue,
    );
    expect(
      libraryContains(
        r'\\server\share',
        r'\\other\share\DVR',
        context: windows,
      ),
      isFalse,
    );
  });
  test(
    'folder configuration roundtrips without requiring an online drive',
    () async {
      final root = await Directory.systemTemp.createTemp('millitop-lib-model-');
      try {
        final original = folder(root.path);
        expect(LibraryFolder.fromJson(original.toJson()).path, root.path);
        expect(
          () => LibraryFolder.fromJson({
            ...original.toJson(),
            'path': 'https://example.invalid',
          }),
          throwsFormatException,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'folder shortcuts are isolated by profile and recordings category',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'millitop-lib-profile-',
      );
      final repo = MediaLibraryRepository();
      try {
        await repo.add(1, path: root.path, label: 'Movies');
        await repo.add(
          1,
          path: root.path,
          label: 'Recordings',
          recordings: true,
        );
        expect((await repo.load(1)).length, 2);
        expect(await repo.load(2), isEmpty);
        await repo.add(1, path: root.path, label: 'Renamed movies');
        expect((await repo.load(1)).length, 2);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test('concurrent shortcut saves do not overwrite one another', () async {
    final root = await Directory.systemTemp.createTemp(
      'millitop-lib-concurrent-',
    );
    final repo = MediaLibraryRepository();
    try {
      final a = await Directory(p.join(root.path, 'a')).create();
      final b = await Directory(p.join(root.path, 'b')).create();
      await Future.wait([
        repo.add(1, path: a.path, label: 'A'),
        repo.add(1, path: b.path, label: 'B'),
      ]);
      expect((await repo.load(1)).length, 2);
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('removing a shortcut leaves the actual files untouched', () async {
    final root = await Directory.systemTemp.createTemp('millitop-lib-remove-');
    final file = File(p.join(root.path, 'keep.mp4'));
    await file.writeAsString('test');
    final repo = MediaLibraryRepository();
    try {
      await repo.add(1, path: root.path, label: 'Movies');
      await repo.remove(1, (await repo.load(1)).single.id);
      expect(await repo.load(1), isEmpty);
      expect(await file.exists(), isTrue);
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('invalid saved configuration fails without deleting it', () async {
    SharedPreferences.setMockInitialValues({
      'library.folders.v1.1': 'not valid json',
    });
    await expectLater(
      MediaLibraryRepository().load(1),
      throwsA(isA<LibraryProblem>()),
    );
    expect(
      (await SharedPreferences.getInstance()).getString('library.folders.v1.1'),
      'not valid json',
    );
  });
  test(
    'directory browser puts folders first and DVR filters non-recording files',
    () async {
      final root = await Directory.systemTemp.createTemp('millitop-lib-list-');
      try {
        await Directory(p.join(root.path, 'Subfolder')).create();
        for (final name in ['a.mp4', 'b.ts', 'c.mp3', 'd.jpg', 'e.exe']) {
          await File(p.join(root.path, name)).writeAsString('test');
        }
        final service = LibraryFileService();
        final normal = await service.browse(folder(root.path), root.path);
        expect(normal.items.first.kind, LibraryMediaKind.folder);
        expect(normal.items.length, 6);
        final dvr = await service.browse(
          folder(root.path, recordings: true),
          root.path,
        );
        expect(
          dvr.items.map((i) => i.name),
          containsAll(['Subfolder', 'a.mp4', 'b.ts', 'c.mp3']),
        );
        expect(
          dvr.items.any((i) => i.name == 'd.jpg' || i.name == 'e.exe'),
          isFalse,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test('opening or browsing outside the chosen root is refused', () async {
    final base = await Directory.systemTemp.createTemp(
      'millitop-lib-boundary-',
    );
    try {
      final root = await Directory(p.join(base.path, 'Videos')).create();
      final outside = await Directory(p.join(base.path, 'Videos2')).create();
      final file = File(p.join(outside.path, 'movie.mp4'));
      await file.writeAsString('test');
      final service = LibraryFileService();
      await expectLater(
        service.browse(folder(root.path), outside.path),
        throwsA(isA<LibraryProblem>()),
      );
      await expectLater(
        service.resolveMedia(
          folder(root.path),
          LibraryItem(
            path: file.path,
            name: 'movie.mp4',
            kind: LibraryMediaKind.video,
          ),
        ),
        throwsA(isA<LibraryProblem>()),
      );
    } finally {
      await base.delete(recursive: true);
    }
  });
  test('unsupported files are not passed to a media decoder', () async {
    final root = await Directory.systemTemp.createTemp(
      'millitop-lib-unsupported-',
    );
    try {
      final file = File(p.join(root.path, 'run.exe'));
      await file.writeAsString('test');
      await expectLater(
        LibraryFileService().resolveMedia(
          folder(root.path),
          LibraryItem(
            path: file.path,
            name: 'run.exe',
            kind: LibraryMediaKind.unsupported,
          ),
        ),
        throwsA(isA<LibraryProblem>()),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
  testWidgets(
    'Files and DVR have real folder controls, not placeholder notices',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: MediaLibraryHome(profileId: 1)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-library-folder')), findsOneWidget);
      expect(find.textContaining('No folders selected'), findsOneWidget);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MediaLibraryHome(profileId: 2, recordings: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cloud-dvr-panel')), findsOneWidget);
      expect(find.textContaining('Pair this device'), findsOneWidget);
      await tester.tap(find.text('Recording settings'));
      await tester.pumpAndSettle();
      expect(find.text('Schedule from EPG guide'), findsOneWidget);
      expect(find.text('Open IPTVnator (legacy)'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-dvr-folder')), findsOneWidget);
      expect(find.textContaining('Record now and Schedule'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'browser displays and searches local folder entries inside Millitop',
    (tester) async {
      // Widget tests use fake async: no createTemp/write/delete calls here.
      // Real filesystem behavior is covered by the service tests above.
      final root = p.absolute('test-fixtures', 'library-browser');
      final service = WidgetFiles([
        LibraryItem(
          path: p.join(root, 'movie.mp4'),
          name: 'movie.mp4',
          kind: LibraryMediaKind.video,
        ),
        LibraryItem(
          path: p.join(root, 'song.mp3'),
          name: 'song.mp3',
          kind: LibraryMediaKind.audio,
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryBrowserScreen(profileId: 1, folder: folder(root), files: service),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('movie.mp4'), findsOneWidget);
      expect(find.text('song.mp3'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'movie');
      await tester.pump();
      expect(find.text('movie.mp4'), findsOneWidget);
      expect(find.text('song.mp3'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  for (final width in [320.0, 640.0, 1280.0]) {
    testWidgets('all footer actions remain separate at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: width,
                child: LauncherFooter(
                  connection: OutlinedButton(
                    key: const ValueKey('connection-test'),
                    onPressed: () {},
                    child: const Text('Connected'),
                  ),
                  profileName: 'An exceptionally long household profile name',
                  onSwitchProfile: () {},
                  onQuit: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final connection = tester.getRect(
        find.byKey(const ValueKey('connection-test')),
      );
      final profile = tester.getRect(
        find.byKey(const ValueKey('footer-switch-profile')),
      );
      final quit = tester.getRect(find.byKey(const ValueKey('millitop-quit')));
      expect(connection.overlaps(profile), isFalse);
      expect(profile.overlaps(quit), isFalse);
      expect(connection.overlaps(quit), isFalse);
      for (final rect in [connection, profile, quit]) {
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(width + 0.1));
        expect(rect.bottom, lessThanOrEqualTo(720));
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('footer switch and quit invoke distinct actions', (tester) async {
    var switched = 0;
    var quit = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LauncherFooter(
            connection: const Text('Connected'),
            profileName: 'Test',
            onSwitchProfile: () => switched++,
            onQuit: () async {
              quit++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('footer-switch-profile')));
    await tester.pump();
    expect(switched, 1);
    expect(quit, 0);
    await tester.tap(find.byKey(const ValueKey('millitop-quit')));
    await tester.pumpAndSettle();
    expect(quit, 1);
  });
  testWidgets(
    'profile scope carries switch action without a positioned overlay',
    (tester) async {
      var switched = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SelectedProfileScope(
            profile: const HouseholdProfile(id: 1, name: 'Test'),
            switchProfile: () => switched++,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: SelectedProfileScope.maybeOf(context)!.switchProfile,
                child: const Text('Switch'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Switch'));
      expect(switched, 1);
      expect(find.byType(SelectedProfileScope), findsOneWidget);
    },
  );
}
