import 'package:flutter_test/flutter_test.dart';
import 'package:millitop_tv/services/adult_content.dart';
import 'package:millitop_tv/services/live_tv_playlist.dart';

LiveTvMediaItem _item(
  String title, {
  String? group,
  List<String> genres = const [],
}) => LiveTvMediaItem(
  id: title,
  title: title,
  streamUrl: 'https://example.invalid/$title',
  group: group,
  genres: genres,
);

void main() {
  test('IPTV XXX title prefix is adult', () {
    expect(AdultContent.isAdultTitle('XXX - Some Movie'), isTrue);
    expect(AdultContent.isAdultTitle('XXX: Another'), isTrue);
    expect(AdultContent.isAdultTitle('[XXX] Bracketed'), isTrue);
    expect(AdultContent.isAdultTitle('18+ | Late Night'), isTrue);
    expect(AdultContent.isAdultTitle('xXx: Return of Xander Cage'), isFalse);
    expect(AdultContent.isAdultTitle('XXXTentacion Documentary'), isFalse);
    expect(AdultContent.isAdultTitle('The Matrix'), isFalse);
  });

  test('adult categories and libraries are detected', () {
    expect(AdultContent.isAdultLabel('For Adults'), isTrue);
    expect(AdultContent.isAdultLabel('Adult'), isTrue);
    expect(AdultContent.isAdultLabel('Adult (Jellyfin)'), isTrue);
    expect(AdultContent.isAdultLabel('VOD | XXX'), isTrue);
    expect(AdultContent.isAdultLabel('Adults Only'), isTrue);
  });

  test('regular categories that mention adult are not adult', () {
    expect(AdultContent.isAdultLabel('Adult Swim'), isFalse);
    expect(AdultContent.isAdultLabel('Young Adult'), isFalse);
    expect(AdultContent.isAdultLabel('Adult Animation'), isFalse);
    expect(AdultContent.isAdultLabel('Movies'), isFalse);
    expect(AdultContent.isAdultLabel(null), isFalse);
    expect(AdultContent.isAdultLabel('Documentary'), isFalse);
  });

  test('items are adult by title, group or genre', () {
    expect(AdultContent.isAdult(_item('XXX - A')), isTrue);
    expect(AdultContent.isAdult(_item('A', group: 'For Adults')), isTrue);
    expect(AdultContent.isAdult(_item('A', group: 'Adult')), isTrue);
    expect(AdultContent.isAdult(_item('A', genres: ['Adult'])), isTrue);
    expect(AdultContent.isAdult(_item('A', group: 'Action')), isFalse);
  });
}
