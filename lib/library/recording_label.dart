import 'package:path/path.dart' as p;

class RecordingLabel {
  final String channel;
  final DateTime? recordedAt;
  const RecordingLabel(this.channel, this.recordedAt);

  factory RecordingLabel.fromFilename(String filename) {
    final stem = p.basenameWithoutExtension(filename);
    final match = RegExp(
      r'^vlc-record-(\d{4})-(\d{2})-(\d{2})-(\d{2})h(\d{2})m(\d{2})s-(.+)$',
      caseSensitive: false,
    ).firstMatch(stem);
    if (match == null) return RecordingLabel(stem.replaceAll('_', ' '), null);
    final numbers = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
    final date = DateTime(
      numbers[0],
      numbers[1],
      numbers[2],
      numbers[3],
      numbers[4],
      numbers[5],
    );
    final valid =
        date.year == numbers[0] &&
        date.month == numbers[1] &&
        date.day == numbers[2] &&
        date.hour == numbers[3] &&
        date.minute == numbers[4] &&
        date.second == numbers[5];
    var channel = match
        .group(7)!
        .replaceAll(RegExp(r'[-_\s]+$'), '')
        .replaceAll('_', ' ')
        .trim();
    if (channel.isEmpty) channel = 'Recording';
    return RecordingLabel(channel, valid ? date : null);
  }

  String get subtitle {
    final date = recordedAt;
    if (date == null) return 'Play in VLC';
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final minute = date.minute.toString().padLeft(2, '0');
    return '${months[date.month - 1]} ${date.day}, ${date.year} · $hour:$minute ${date.hour < 12 ? 'AM' : 'PM'}';
  }
}
