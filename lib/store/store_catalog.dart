class StoreApp {
  final String key;
  final String title;
  final String description;
  final String? packageId;
  final String? scope;
  final String? website;
  const StoreApp(
    this.key,
    this.title,
    this.description, {
    this.packageId,
    this.scope,
    this.website,
  });
  bool get isWebsite => website != null;
}

const storeApps = [
  StoreApp(
    'iptvnator',
    'IPTVnator',
    'Watch your configured IPTV sources.',
    packageId: '4gray.iptvnator',
    scope: 'user',
  ),
  StoreApp(
    'vlc',
    'VLC player',
    'Play local video and audio files.',
    packageId: 'VideoLAN.VLC',
    scope: 'machine',
  ),
  StoreApp(
    'emby',
    'Emby',
    'Open your Millitop Emby website.',
    website: 'https://watch.millitop.net',
  ),
  StoreApp(
    'jellyfin',
    'Jellyfin',
    'Open your Millitop Jellyfin website.',
    website: 'https://stream.millitop.net',
  ),
];
StoreApp nativeStoreApp(String key) => storeApps.firstWhere(
  (a) => a.key == key && !a.isWebsite,
  orElse: () => throw ArgumentError('This application is not approved.'),
);
