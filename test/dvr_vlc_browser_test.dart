import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:millitop_tv/library/library_models.dart';
import 'package:millitop_tv/library/library_file_service.dart';
import 'package:millitop_tv/screens/library_browser_screen.dart';
import 'package:millitop_tv/screens/library_media_screen.dart';

class RecordingFiles extends LibraryFileService {
  final LibraryItem item;
  RecordingFiles(this.item);
  @override
  Future<LibrarySnapshot> browse(LibraryFolder folder, String path) async =>
      LibrarySnapshot(path, [item]);
  @override
  Future<String> resolveMedia(LibraryFolder folder, LibraryItem item) async =>
      item.path;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('DVR uses friendly labels and passes the original path to VLC', (
    tester,
  ) async {
    final root = p.absolute('dvr-fixture');
    const name = 'vlc-record-2026-10-24-20h03m16s-A&E (East) US-.mp4';
    final item = LibraryItem(
      path: p.join(root, name),
      name: name,
      kind: LibraryMediaKind.video,
    );
    final folder = LibraryFolder(
      id: '11111111-1111-4111-8111-111111111111',
      label: 'Recordings',
      path: root,
      recordings: true,
    );
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBrowserScreen(
          profileId: 1,
          folder: folder,
          files: RecordingFiles(item),
          playRecording: (context, path) async {
            opened = path;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('A&E (East) US'), findsOneWidget);
    expect(find.text('October 24, 2026 · 8:03 PM'), findsOneWidget);
    expect(find.text(name), findsNothing);
    expect(find.text(root), findsNothing);
    await tester.tap(find.text('A&E (East) US'));
    await tester.pumpAndSettle();
    expect(opened, item.path);
    expect(find.byType(LibraryMediaScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
