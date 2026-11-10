import 'dart:convert';
import '../../services/device_connection.dart';
import '../../services/home_preferences.dart';
import '../../services/music_service.dart';
import '../../services/live_tv_playlist.dart';
import '../../services/adult_content.dart';
import '../../services/sleep_mode.dart';
import '../../services/sleep_sounds_controller.dart';
import 'ai_models.dart';
import 'ai_service.dart';
import 'backend_ai_service.dart';
import 'mavae_catalog_service.dart';

class MavaeAgentService implements AiService {
  MavaeAgentService({
    required this.profileId,
    AiSender? planSend,
    AiService? chat,
  }) : _planSend = planSend,
       _chat = chat ?? BackendAiService.pairedDevice();
  final int profileId;
  final AiSender? _planSend;
  final AiService _chat;
  late final MavaeCatalogService catalog = MavaeCatalogService(
    profileId: profileId,
    fallback: _chat,
  );
  final Set<AiActionProposal> _consumed = {};
  bool _executing = false;

  static Map<String, dynamic> validatePlan(Map<String, dynamic> value) {
    final kind = value['kind'];
    final tool = value['tool'];
    final message = value['message'];
    final rawArgs = value['arguments'];
    if (!['chat', 'clarify', 'tool'].contains(kind) ||
        message is! String ||
        message.trim().isEmpty ||
        message.length > 1500 ||
        rawArgs is! Map ||
        value.keys.toSet().difference({
          'kind',
          'tool',
          'message',
          'arguments',
        }).isNotEmpty) {
      throw const FormatException('Invalid plan.');
    }
    final args = Map<String, dynamic>.from(rawArgs);
    bool exact(Set<String> keys) =>
        args.length == keys.length && args.keys.every(keys.contains);
    bool query() =>
        args['query'] is String &&
        (args['query'] as String).trim().isNotEmpty &&
        (args['query'] as String).length <= 200;
    var valid = false;
    if (kind != 'tool') {
      valid = tool == 'none' && args.isEmpty;
    } else {
      switch (tool) {
        case 'search_media':
          valid =
              exact({'query', 'mediaType'}) &&
              query() &&
              ['movie', 'series', 'all'].contains(args['mediaType']);
          break;
        case 'search_music':
          valid =
              exact({'query', 'category'}) &&
              query() &&
              ['track', 'artist', 'album', 'all'].contains(args['category']);
          break;
        case 'search_channels':
          valid = exact({'query'}) && query();
          break;
        case 'sleep_status':
        case 'preview_cancel_sleep_timer':
          valid = args.isEmpty;
          break;
        case 'preview_sleep_timer':
          valid =
              exact({'operation', 'minutes'}) &&
              ['start', 'extend'].contains(args['operation']) &&
              args['minutes'] is int &&
              (args['minutes'] as int) >= 1 &&
              (args['minutes'] as int) <= 720;
          break;
        case 'preview_sleep_sounds':
          valid =
              exact({'operation'}) &&
              ['start', 'stop', 'pause', 'resume'].contains(args['operation']);
          break;
        case 'preview_sound_layer':
          valid =
              exact({'soundId', 'enabled', 'volume'}) &&
              SleepSoundsController.simpleSoundIds.contains(args['soundId']) &&
              args['enabled'] is bool &&
              args['volume'] is int &&
              (args['volume'] as int) >= 0 &&
              (args['volume'] as int) <= 100;
          break;
      }
    }
    if (!valid) {
      throw const FormatException('Unsupported plan.');
    }
    return {'kind': kind, 'tool': tool, 'message': message, 'arguments': args};
  }

  @override
  Future<AiReply> reply(AiRequest request) async {
    if (request.profileId != profileId.toString()) {
      throw StateError('Profile changed.');
    }
    final connection = DeviceConnection.instance;
    if (_planSend == null) {
      await connection.start();
    }
    final key = connection.connectionKey;
    final history = request.messages;
    var start = history.length > 7 ? history.length - 7 : 0;
    while (start < history.length - 1 &&
        (history.skip(start).any((m) => m.text.length > 4000) ||
            history.skip(start).fold<int>(0, (n, m) => n + m.text.length) >
                12000)) {
      start += 2;
    }
    final payload = <String, dynamic>{
      'task': 'plan',
      'messages': [
        for (final m in history.skip(start))
          {'role': m.role.name, 'text': m.text},
      ],
    };
    final data = _planSend != null
        ? await _planSend(payload)
        : await connection.postDevice(
            '/api/device/ai/chat',
            payload,
            expectedConnection: key,
          );
    if (data['mode'] != 'local_plan' ||
        data['actionsEnabled'] != false ||
        data['plan'] is! Map) {
      throw const FormatException('Planner response invalid.');
    }
    final plan = validatePlan(Map<String, dynamic>.from(data['plan'] as Map));
    if (_planSend == null && connection.connectionKey != key) {
      throw StateError('Connection changed.');
    }
    if (plan['kind'] == 'clarify') {
      return AiReply(text: plan['message'] as String);
    }
    if (plan['kind'] == 'chat') {
      return _chat.reply(request);
    }
    final args = plan['arguments'] as Map<String, dynamic>;
    final tool = plan['tool'] as String;
    switch (tool) {
      case 'search_media':
        return catalog.search(
          args['query'] as String,
          mediaType: args['mediaType'] as String,
        );
      case 'search_music':
        return _music(args['query'] as String, args['category'] as String);
      case 'search_channels':
        return _channels(args['query'] as String);
      case 'sleep_status':
        return AiReply(text: _sleepStatus());
      default:
        return _preview(tool, args, key);
    }
  }

  Future<AiReply> _music(String query, String category) async {
    final tracks = await MusicService().loadLibraryCache(profileId);
    bool matches(MusicTrack t) {
      final haystack = switch (category) {
        'artist' => t.artist,
        'album' => t.album,
        'track' => t.title,
        _ => '${t.title} ${t.artist} ${t.album}',
      };
      return mavaeMatchesTitle(haystack, query);
    }

    final found = tracks.where(matches).toList();
    return AiReply(
      text: tracks.isEmpty
          ? 'No cached music library is available for this profile. Open Music and load the library, then retry.'
          : 'Found ${found.length} matching track(s) in the cached music library: ${found.take(12).map((t) => '${t.title} by ${t.artist}').join('; ')}. Artist/album searches return matching tracks; this does not check live server availability.',
      media: [
        for (final t in found.take(12))
          AiMediaMatch(
            sourceId: 'music-cache',
            sourceName: 'Cached music library',
            mediaId: t.id,
            title: t.title,
            mediaType: 'music',
            cachedAt: DateTime.fromMillisecondsSinceEpoch(0),
            year: t.year,
            overview:
                '${t.artist} | ${t.album} | ${t.durationSeconds ~/ 60}:${(t.durationSeconds % 60).toString().padLeft(2, '0')}',
            genres: [if (t.genre != null) t.genre!],
          ),
      ],
    );
  }

  Future<AiReply> _channels(String query) async {
    final sources = await HomePreferences().liveTvSources(profileId);
    final cards = <AiMediaMatch>[];
    final failed = <String>[];
    for (final source in sources) {
      if (AdultContent.isAdultLabel(source.name)) {
        continue;
      }
      try {
        final list = await const LiveTvPlaylistService()
            .loadFromSource(source)
            .timeout(const Duration(seconds: 15));
        for (final channel in list.channels) {
          if (AdultContent.isAdultLabel(channel.group) ||
              AdultContent.isAdultTitle(channel.title) ||
              !mavaeMatchesTitle(
                '${channel.title} ${channel.group ?? ''}',
                query,
              )) {
            continue;
          }
          if (cards.length < 12) {
            cards.add(
              AiMediaMatch(
                sourceId: source.id,
                sourceName: source.name,
                mediaId: channel.title,
                title: channel.title,
                mediaType: 'channel',
                cachedAt: DateTime.now(),
                posterUrl: channel.logo,
                overview: channel.group,
              ),
            );
          }
        }
      } catch (_) {
        failed.add(source.name);
      }
    }
    return AiReply(
      text:
          'Found ${cards.length} displayed channel match(es): ${cards.map((c) => c.title).join('; ')}. Showing at most 12. Channel names/groups searched; program guide search and direct tuning are not connected in this client candidate.'
          '${failed.isEmpty ? '' : '\nCould not check: ${failed.join(', ')}.'}',
      media: cards,
    );
  }

  String _stateKey() {
    final timer = SleepMode.instance;
    final sounds = SleepSoundsController.instance;
    return jsonEncode([
      timer.deadline?.toIso8601String(),
      timer.applying,
      sounds.activeProfileId,
      sounds.state.name,
      sounds.backend.name,
      sounds.soundEnabled,
      sounds.perSoundVolume,
      sounds.volume,
      sounds.selectedPreset,
    ]);
  }

  String _sleepStatus() {
    final timer = SleepMode.instance;
    final sounds = SleepSoundsController.instance;
    final timerText = timer.deadline == null
        ? 'No viewing timer is active.'
        : 'Viewing timer deadline: ${timer.deadline!.toLocal()}. About ${timer.remaining.inMinutes} minutes remain.';
    if (sounds.activeProfileId != null && sounds.activeProfileId != profileId) {
      return '$timerText\nSleep audio belongs to another profile; its mix is not shown.';
    }
    return '$timerText\nSleep sounds: ${sounds.state.name}. Viewing timer expiry leaves sleep sounds unchanged.';
  }

  Future<AiReply> _preview(
    String tool,
    Map<String, dynamic> args,
    String key,
  ) async {
    final sounds = SleepSoundsController.instance;
    if (tool == 'preview_sleep_sounds' || tool == 'preview_sound_layer') {
      if (sounds.running && sounds.activeProfileId != profileId) {
        return const AiReply(
          text:
              'Sleep sounds are active for another profile. Open Sleep Sounds to change the active session.',
        );
      }
      if (!sounds.running) {
        await sounds.loadPreferences(profileId);
      }
    }

    final summary = switch (tool) {
      'preview_sleep_timer' =>
        '${args['operation'] == 'start' ? 'Start/replace the viewing timer with' : 'Extend the active viewing timer by'} ${args['minutes']} minutes. At expiry, end app-owned viewing and request displays off; leave sleep sounds unchanged.',
      'preview_cancel_sleep_timer' =>
        'Cancel the current viewing timer. Leave sleep sounds unchanged.',
      'preview_sleep_sounds' =>
        '${args['operation']} sleep sounds for the current profile. Start uses the currently configured mix.',
      'preview_sound_layer' =>
        'Set ${args['soundId']} ${args['enabled'] == true ? 'enabled' : 'disabled'} at ${args['volume']}%. This changes the current mix; it does not create a future schedule.',
      _ => throw const FormatException('Unsupported action.'),
    };
    final mix = tool == 'preview_sleep_sounds' && args['operation'] == 'start'
        ? '\nEnabled mix: ${sounds.soundEnabled.entries.where((e) => e.value).map((e) => '${e.key} ${sounds.perSoundVolume[e.key]}%').join(', ')}. Master ${sounds.volume}%.'
        : '';
    return AiReply(
      text: 'Review the requested action below. Nothing has changed yet.',
      proposal: AiActionProposal(
        tool: tool,
        arguments: args,
        summary: summary + mix,
        connectionKey: key,
        stateKey: _stateKey(),
      ),
    );
  }

  Future<String> executeConfirmed(AiActionProposal proposal) async {
    if (_executing ||
        _consumed.contains(proposal) ||
        DateTime.now().difference(proposal.createdAt) >
            const Duration(minutes: 5) ||
        DeviceConnection.instance.connectionKey != proposal.connectionKey ||
        _stateKey() != proposal.stateKey) {
      throw StateError(
        'Action expired, changed, or was already applied. Ask again.',
      );
    }
    validatePlan({
      'kind': 'tool',
      'message': 'Validated action preview',
      'tool': proposal.tool,
      'arguments': proposal.arguments,
    });
    _executing = true;
    _consumed.add(proposal);
    try {
      final args = proposal.arguments;
      final timer = SleepMode.instance;
      final sounds = SleepSoundsController.instance;
      if (timer.applying) {
        throw StateError('Viewing timer is finishing. Retry afterward.');
      }
      switch (proposal.tool) {
        case 'preview_sleep_timer':
          final minutes = args['minutes'] as int;
          if (args['operation'] == 'start') {
            await timer.startTimer(minutes);
          } else {
            if (timer.deadline == null) {
              throw StateError('No active timer to extend.');
            }
            timer.extend(minutes);
          }
          if (timer.deadline == null) {
            throw StateError('Timer did not become active.');
          }
          return 'Viewing timer deadline: ${timer.deadline!.toLocal()}. Sleep sounds are unchanged.';
        case 'preview_cancel_sleep_timer':
          timer.cancelTimer();
          if (timer.deadline != null) {
            throw StateError('Timer was not cancelled.');
          }
          return 'Viewing timer cancelled. Sleep sounds are unchanged.';
        case 'preview_sleep_sounds':
        case 'preview_sound_layer':
          if (sounds.activeProfileId != null &&
              sounds.activeProfileId != profileId &&
              sounds.running) {
            throw StateError(
              'Sleep sounds belong to another profile. Change them from Sleep Sounds first.',
            );
          }
          if (!sounds.running) {
            await sounds.loadPreferences(profileId);
          }
          if (sounds.backend != SleepSoundsBackend.embeddedWebView) {
            throw StateError(
              'Mavae controls embedded sleep sounds only. Select in-app playback in Sleep Sounds.',
            );
          }
          if (proposal.tool == 'preview_sound_layer') {
            if (sounds.running && !sounds.capabilities.supportsPerSoundVolume) {
              throw StateError(
                'This backend cannot control individual layers.',
              );
            }
            await sounds.setPerSoundVolume(
              args['soundId'] as String,
              (args['volume'] as int).toDouble(),
            );
            await sounds.setSoundEnabled(
              args['soundId'] as String,
              args['enabled'] as bool,
            );
            return sounds.running
                ? 'Mix change submitted to the sleep-sounds controller. Check the mixer for playback state.'
                : 'Current mix updated; sounds are not playing. This candidate does not persist mix changes across restarts.';
          }
          switch (args['operation']) {
            case 'start':
              if (sounds.running) {
                throw StateError('Sleep sounds are already active.');
              }
              await sounds.play(
                profileId: profileId,
                url: 'https://sleep.millitop.net',
              );
              break;
            case 'stop':
              await sounds.stop();
              break;
            case 'pause':
              await sounds.pause();
              break;
            case 'resume':
              await sounds.resume();
              break;
          }
          if (sounds.state == SleepSoundsState.error ||
              sounds.error.isNotEmpty) {
            throw StateError(
              'Sleep-sounds controller reported an error. Open the mixer.',
            );
          }
          return 'Sleep-sounds controller state: ${sounds.state.name}.';
        default:
          throw StateError('Unsupported action.');
      }
    } finally {
      _executing = false;
    }
  }
}
