import 'live_tv_playlist.dart';

/// Detects adult titles so they never mix with regular Movies & Series.
///
/// Sources label adult content differently:
/// * IPTV providers prefix titles with `XXX -` and file them under a
///   category such as "For Adults".
/// * Jellyfin keeps them in a library named "Adult" (the library name is
///   stored as the item's group), or tags them with an Adult genre.
class AdultContent {
  const AdultContent._();

  // Upper-case "XXX" only: providers write "XXX - Title", while real films
  // such as "xXx: Return of Xander Cage" use mixed case.
  static final RegExp _titlePrefix = RegExp(
    r'^\s*[\[(]?\s*(XXX|18\+|[Aa]dults?\s+[Oo]nly|ADULTS?\s+ONLY)\s*[\])]?\s*([-:|–—]|\s)',
  );

  static final RegExp _label = RegExp(
    r'(^|[^a-z])(xxx|for adults?|adults?( only| content| movies?| \(jellyfin\))?|18\+|porn\w*|erotic\w*|x-rated|hentai)([^a-z]|$)',
    caseSensitive: false,
  );

  // Regular categories that merely contain the word "adult".
  static final RegExp _notAdult = RegExp(
    r'adult\s*swim|young\s+adults?|adult\s+(education|learning|animation)',
    caseSensitive: false,
  );

  /// True for a title like "XXX - Some Movie".
  static bool isAdultTitle(String title) => _titlePrefix.hasMatch(title);

  /// True for a category, library or source name such as "For Adults",
  /// "Adult" or "XXX Movies".
  static bool isAdultLabel(String? label) {
    final text = label?.trim() ?? '';
    if (text.isEmpty || _notAdult.hasMatch(text)) {
      return false;
    }
    return _label.hasMatch(text);
  }

  static bool isAdult(LiveTvMediaItem item) =>
      isAdultTitle(item.title) ||
      isAdultLabel(item.group) ||
      item.genres.any(isAdultLabel);

  /// For saved rows (history, favorites) where only text survives.
  static bool isAdultEntry({required String title, String? sourceName}) =>
      isAdultTitle(title) || isAdultLabel(sourceName);
}
