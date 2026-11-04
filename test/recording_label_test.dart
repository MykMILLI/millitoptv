import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/library/recording_label.dart';

void main() {
  test('VLC recording displays channel and readable recording timestamp', () {
    final label = RecordingLabel.fromFilename(
      'vlc-record-2026-10-24-20h03m16s-A&E (East) US-.mp4',
    );
    expect(label.channel, 'A&E (East) US');
    expect(label.subtitle, 'October 24, 2026 · 8:03 PM');
  });
  test('unknown filenames keep readable title without inventing dates', () {
    final label = RecordingLabel.fromFilename('Family_show.mp4');
    expect(label.channel, 'Family show');
    expect(label.recordedAt, isNull);
    expect(label.subtitle, 'Play in VLC');
  });
  test('invalid recording dates do not normalize silently', () {
    final label = RecordingLabel.fromFilename(
      'vlc-record-2026-02-30-20h03m16s-News-.mp4',
    );
    expect(label.recordedAt, isNull);
  });
  test('midnight and noon format correctly', () {
    expect(
      RecordingLabel.fromFilename(
        'vlc-record-2026-10-24-00h01m00s-News-.ts',
      ).subtitle,
      contains('12:01 AM'),
    );
    expect(
      RecordingLabel.fromFilename(
        'vlc-record-2026-10-24-12h01m00s-News-.ts',
      ).subtitle,
      contains('12:01 PM'),
    );
  });
}
