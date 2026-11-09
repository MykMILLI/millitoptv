import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_connection.dart';
import '../services/watch_party/watch_party_service.dart';
import 'overnight_window_guard.dart';
import 'watch_party_guest_screen.dart';

WatchPartyService get _party => WatchPartyService.instance;

/// App-wide watch party layer: a pill showing the party, the side panel
/// (chat, people, invites, voice) and floating reactions. Lives above the
/// navigator so it stays visible on every screen.
class WatchPartyOverlay extends StatefulWidget {
  final Widget child;
  const WatchPartyOverlay({super.key, required this.child});

  @override
  State<WatchPartyOverlay> createState() => _WatchPartyOverlayState();
}

class _WatchPartyOverlayState extends State<WatchPartyOverlay> {
  final List<_FloatingReaction> _floating = [];
  StreamSubscription<(String, String)>? _reactionSub;
  int _reactionSeq = 0;

  @override
  void initState() {
    super.initState();
    _reactionSub = _party.reactionStream.listen((event) {
      final id = ++_reactionSeq;
      _floating.add(_FloatingReaction(id, event.$1, event.$2));
      if (_floating.length > 12) _floating.removeAt(0);
      _entry.markNeedsBuild();
      Timer(const Duration(milliseconds: 2600), () {
        _floating.removeWhere((r) => r.id == id);
        if (mounted) _entry.markNeedsBuild();
      });
    });
  }

  @override
  void dispose() {
    _reactionSub?.cancel();
    super.dispose();
  }

  // A single entry in a private Overlay so text fields in the panel have
  // somewhere to show selection handles; this layer sits outside the app
  // navigator's overlay.
  late final OverlayEntry _entry = OverlayEntry(
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([_party, _party.voice]),
      builder: (context, _) => _layer(context),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        Positioned.fill(child: Overlay(initialEntries: [_entry])),
      ],
    );
  }

  Widget _layer(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final panelWidth = size.width < 520 ? size.width : 380.0;
    final children = <Widget>[];
    if (_party.active && !_party.panelOpen) {
      children.add(
        Positioned(
          top: MediaQuery.paddingOf(context).top + 8,
          right: 12,
          child: _PartyPill(onTap: () => _party.setPanelOpen(true)),
        ),
      );
    }
    if (_party.active && _party.panelOpen) {
      children.add(
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: panelWidth,
          child: const WatchPartyPanel(),
        ),
      );
    }
    for (var i = 0; i < _floating.length; i++) {
      final reaction = _floating[i];
      children.add(
        Positioned(
          right:
              (_party.panelOpen ? panelWidth : 0) + 24 + (reaction.id % 4) * 26,
          bottom: 80,
          child: IgnorePointer(
            child: _ReactionBubble(
              key: ValueKey(reaction.id),
              reaction: reaction,
            ),
          ),
        ),
      );
    }
    final ended = _party.endedReason;
    if (ended != null && !_party.active) {
      children.add(
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Center(
            child: Material(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.groups_outlined, color: Colors.white70),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        ended,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    TextButton(
                      onPressed: _party.dismissEnded,
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Stack(children: children);
  }
}

class _FloatingReaction {
  final int id;
  final String emoji;
  final String name;
  _FloatingReaction(this.id, this.emoji, this.name);
}

class _ReactionBubble extends StatelessWidget {
  final _FloatingReaction reaction;
  const _ReactionBubble({super.key, required this.reaction});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 2400),
      builder: (context, t, child) => Opacity(
        opacity: t < 0.75 ? 1 : (1 - t) * 4,
        child: Transform.translate(offset: Offset(0, -220 * t), child: child),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(reaction.emoji, style: const TextStyle(fontSize: 36)),
          if (reaction.name.isNotEmpty)
            Text(
              reaction.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                shadows: [Shadow(blurRadius: 4)],
              ),
            ),
        ],
      ),
    );
  }
}

class _PartyPill extends StatelessWidget {
  final VoidCallback onTap;
  const _PartyPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final online = _party.people.where((p) => p.online).length;
    final unread = _party.unreadChat;
    return Material(
      color: const Color(0xE61B1F2A),
      shape: const StadiumBorder(side: BorderSide(color: Color(0x33FFFFFF))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.circle,
                size: 9,
                color: _party.connected
                    ? Colors.greenAccent
                    : Colors.orangeAccent,
              ),
              const SizedBox(width: 8),
              const Icon(Icons.groups, size: 18, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                '${_party.isHost ? 'Hosting' : 'Watch party'} · $online',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_party.voice.active) ...[
                const SizedBox(width: 8),
                Icon(
                  _party.voice.muted ? Icons.mic_off : Icons.mic,
                  size: 16,
                  color: Colors.white70,
                ),
              ],
              if (unread > 0) ...[
                const SizedBox(width: 8),
                CircleAvatar(
                  radius: 9,
                  backgroundColor: Colors.redAccent,
                  child: Text(
                    unread > 9 ? '9+' : '$unread',
                    style: const TextStyle(fontSize: 10, color: Colors.white),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Side panel with chat, people and (for hosts) invites and controls.
class WatchPartyPanel extends StatefulWidget {
  final bool embedded;
  const WatchPartyPanel({super.key, this.embedded = false});

  @override
  State<WatchPartyPanel> createState() => _WatchPartyPanelState();
}

class _WatchPartyPanelState extends State<WatchPartyPanel> {
  int _tab = 0;
  final _chat = TextEditingController();
  final _emails = TextEditingController();
  final _note = TextEditingController();
  final _scroll = ScrollController();
  String? _status;
  bool _busy = false;
  int _lastCount = 0;

  @override
  void dispose() {
    _chat.dispose();
    _emails.dispose();
    _note.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await action();
      if (mounted && success != null) setState(() => _status = success);
    } catch (error) {
      if (mounted) setState(() => _status = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_party, _party.voice]),
      builder: (context, _) {
        if (_party.messages.length != _lastCount) {
          _lastCount = _party.messages.length;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            }
          });
        }
        return Material(
          color: const Color(0xF2121520),
          elevation: widget.embedded ? 0 : 12,
          child: SafeArea(
            left: false,
            child: DefaultTextStyle(
              style: const TextStyle(color: Colors.white),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context),
                  if (_party.relayWarning != null && _party.isHost)
                    Container(
                      color: const Color(0x33FFA000),
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        _party.relayWarning!,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  _tabs(),
                  const Divider(height: 1, color: Colors.white12),
                  Expanded(
                    child: switch (_tab) {
                      0 => _chatTab(),
                      1 => _peopleTab(),
                      _ => _inviteTab(),
                    },
                  ),
                  if (_status != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Text(
                        _status!,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context) {
    final media = _party.media;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _party.partyTitle ?? 'Watch party',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!widget.embedded)
                IconButton(
                  tooltip: 'Close panel',
                  color: Colors.white,
                  onPressed: () => _party.setPanelOpen(false),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
          Text(
            media == null
                ? (_party.isHost
                      ? 'Play something to share it with the party.'
                      : 'Waiting for ${_party.hostName} to play something.')
                : '${media.queueLabel != null ? '${media.queueLabel} · ' : ''}${media.title}',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_party.joinCode != null)
                ActionChip(
                  avatar: const Icon(Icons.copy, size: 16),
                  label: Text('Code ${_party.joinCode}'),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: _party.joinUrl ?? _party.joinCode!),
                    );
                    if (mounted) setState(() => _status = 'Join link copied.');
                  },
                ),
              _voiceButton(),
              if (_party.voice.active)
                IconButton.filledTonal(
                  tooltip: _party.voice.muted ? 'Unmute' : 'Mute',
                  onPressed: _party.voice.listenOnly
                      ? null
                      : () => _party.voice.setMuted(!_party.voice.muted),
                  icon: Icon(_party.voice.muted ? Icons.mic_off : Icons.mic),
                ),
              if (_party.isHost)
                IconButton.filledTonal(
                  tooltip: _party.locked
                      ? 'Unlock party'
                      : 'Lock party (no new guests)',
                  onPressed: _busy
                      ? null
                      : () => _run(() => _party.setLocked(!_party.locked)),
                  icon: Icon(_party.locked ? Icons.lock : Icons.lock_open),
                ),
              if (_party.isHost && _party.hasLocalPlayback)
                IconButton.filledTonal(
                  tooltip: 'Share what is playing again',
                  onPressed: _busy
                      ? null
                      : () => _run(
                          _party.shareNow,
                          success: 'Shared ${_party.localTitle ?? ''}.',
                        ),
                  icon: const Icon(Icons.sync),
                ),
              if (_party.isGuest && !widget.embedded)
                IconButton.filledTonal(
                  tooltip: 'Open the party player',
                  onPressed: openWatchPartyGuestScreen,
                  icon: const Icon(Icons.ondemand_video),
                ),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0x55E53935),
                  foregroundColor: Colors.white,
                ),
                onPressed: _busy ? null : _confirmLeave,
                icon: Icon(
                  _party.isHost ? Icons.stop_circle_outlined : Icons.logout,
                ),
                label: Text(_party.isHost ? 'End party' : 'Leave'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 2,
            children: [
              for (final emoji in WatchPartyService.reactions)
                IconButton(
                  tooltip: 'React $emoji',
                  onPressed: () => _party.react(emoji).catchError((_) {}),
                  icon: Text(emoji, style: const TextStyle(fontSize: 20)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _voiceButton() {
    final voice = _party.voice;
    return FilledButton.tonalIcon(
      onPressed: _busy
          ? null
          : () => _run(voice.active ? voice.leave : voice.join),
      icon: Icon(voice.active ? Icons.call_end : Icons.headset_mic),
      label: Text(voice.active ? 'Leave voice' : 'Join voice'),
    );
  }

  Future<void> _confirmLeave() async {
    final host = _party.isHost;
    final context = overnightNavigatorKey.currentContext;
    if (context == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(host ? 'End the watch party?' : 'Leave the watch party?'),
        content: Text(
          host
              ? 'Everyone will be disconnected.'
              : 'You can rejoin with the code while it is running.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(host ? 'End party' : 'Leave'),
          ),
        ],
      ),
    );
    if (ok == true) await _run(_party.leave);
  }

  Widget _tabs() {
    final labels = [
      'Chat${_party.unreadChat > 0 ? ' (${_party.unreadChat})' : ''}',
      'People (${_party.people.length})',
      if (_party.isHost) 'Invite',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            TextButton(
              onPressed: () => setState(() => _tab = i),
              style: TextButton.styleFrom(
                foregroundColor: _tab == i ? Colors.white : Colors.white54,
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  fontWeight: _tab == i ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chatTab() {
    final messages = _party.messages;
    return Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? const Center(
                  child: Text(
                    'No messages yet.',
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final m = messages[index];
                    if (m.notice) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          m.body,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      );
                    }
                    final mine = m.from == _party.meId;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: mine
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.name,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          Container(
                            margin: const EdgeInsets.only(top: 2),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: mine
                                  ? const Color(0xFF2F4A8A)
                                  : const Color(0xFF262B38),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(m.body),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 4, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chat,
                  maxLength: 1000,
                  style: const TextStyle(color: Colors.white),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendChat(),
                  decoration: const InputDecoration(
                    hintText: 'Message the party',
                    counterText: '',
                    isDense: true,
                    hintStyle: TextStyle(color: Colors.white38),
                  ),
                ),
              ),
              IconButton(
                color: Colors.white,
                tooltip: 'Send',
                onPressed: _sendChat,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _sendChat() {
    final text = _chat.text;
    if (text.trim().isEmpty) return;
    _chat.clear();
    _party.sendChat(text).catchError((Object error) {
      if (mounted) setState(() => _status = error.toString());
    });
  }

  Widget _peopleTab() {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final p in _party.people)
          ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 14,
              backgroundColor: p.online
                  ? const Color(0xFF2E7D32)
                  : Colors.white24,
              child: Text(
                p.name.isEmpty ? '?' : p.name.characters.first.toUpperCase(),
                style: const TextStyle(fontSize: 12, color: Colors.white),
              ),
            ),
            title: Text(
              '${p.name}${p.id == _party.meId ? ' (you)' : ''}',
              style: const TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              [
                if (p.isHost) 'Host',
                p.client == 'app' ? 'MILLITOP TV app' : 'Browser',
                if (!p.online) 'Away',
                if (p.inVoice)
                  p.listenOnly ? 'Listening' : (p.muted ? 'Muted' : 'In voice'),
              ].join(' · '),
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            trailing: _party.isHost && !p.isHost
                ? IconButton(
                    tooltip: 'Remove ${p.name}',
                    color: Colors.white70,
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => _party.remove(p.id),
                            success: '${p.name} was removed.',
                          ),
                    icon: const Icon(Icons.person_remove_outlined),
                  )
                : null,
          ),
      ],
    );
  }

  Widget _inviteTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text(
          'Invite by email',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        const Text(
          'Guests get a link that opens in any browser, or they can enter the code in the MILLITOP TV app.',
          style: TextStyle(color: Colors.white60, fontSize: 12),
        ),
        TextField(
          controller: _emails,
          style: const TextStyle(color: Colors.white),
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Email addresses (comma separated)',
            labelStyle: TextStyle(color: Colors.white60),
          ),
        ),
        TextField(
          controller: _note,
          maxLength: 300,
          maxLines: 2,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Note (optional)',
            labelStyle: TextStyle(color: Colors.white60),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _sendInvites,
          icon: const Icon(Icons.send),
          label: const Text('Send invites'),
        ),
        const SizedBox(height: 16),
        if (_party.joinUrl != null)
          SelectableText(
            _party.joinUrl!,
            style: const TextStyle(color: Colors.white70),
          ),
      ],
    );
  }

  Future<void> _sendInvites() async {
    final emails = _emails.text
        .split(RegExp(r'[\s,;]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (emails.isEmpty) {
      setState(() => _status = 'Add at least one email address.');
      return;
    }
    await _run(() async {
      final results = await _party.invite(emails, note: _note.text);
      final failed = results.where((r) => r['delivered'] != true).toList();
      if (failed.isEmpty) {
        _emails.clear();
        _note.clear();
        _status =
            'Sent ${results.length} invite${results.length == 1 ? '' : 's'}.';
      } else {
        _status =
            'Could not email ${failed.map((r) => r['email']).join(', ')}: ${failed.first['error'] ?? 'unknown error'}. Share the link instead.';
      }
    });
  }
}

// -----------------------------------------------------------------------------
// Entry points

/// Starts a party from a player. Shares what is currently playing.
Future<void> showStartWatchParty(BuildContext context) async {
  if (_party.active) {
    _party.setPanelOpen(true);
    return;
  }
  if (DeviceConnection.instance.serverUri == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'Pair this device with tvadmin in Settings to host watch parties.',
        ),
      ),
    );
    return;
  }
  final name = TextEditingController(text: await _party.savedDisplayName());
  final title = TextEditingController(
    text: _party.localTitle == null
        ? 'Watch party'
        : 'Watching ${_party.localTitle}',
  );
  if (!context.mounted) return;
  final error = ValueNotifier<String?>(null);
  final busy = ValueNotifier(false);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Start a watch party'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Friends watch along through tvadmin, in a browser or the app. Your media servers stay private.',
            ),
            TextField(
              controller: name,
              autofocus: true,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Your name'),
            ),
            TextField(
              controller: title,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Party name'),
            ),
            ValueListenableBuilder(
              valueListenable: error,
              builder: (_, value, _) => value == null
                  ? const SizedBox.shrink()
                  : Text(
                      value,
                      style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.error,
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder(
          valueListenable: busy,
          builder: (_, isBusy, _) => FilledButton(
            onPressed: isBusy
                ? null
                : () async {
                    if (name.text.trim().isEmpty) {
                      error.value = 'Enter your name.';
                      return;
                    }
                    busy.value = true;
                    error.value = null;
                    try {
                      await _party.startParty(
                        title: title.text.trim().isEmpty
                            ? 'Watch party'
                            : title.text.trim(),
                        displayName: name.text.trim(),
                      );
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      _party.setPanelOpen(true);
                    } catch (e) {
                      error.value = e is StateError
                          ? 'This device is not connected to tvadmin right now.'
                          : '$e';
                    } finally {
                      busy.value = false;
                    }
                  },
            child: const Text('Start party'),
          ),
        ),
      ],
    ),
  );
}

/// Joins a party by code or link, then opens the guest player.
Future<void> showJoinWatchParty(BuildContext context, {String? initial}) async {
  final code = TextEditingController(text: initial ?? '');
  final name = TextEditingController(text: await _party.savedDisplayName());
  if (!context.mounted) return;
  final error = ValueNotifier<String?>(null);
  final busy = ValueNotifier(false);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Join a watch party'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: code,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Party code or invite link',
              ),
            ),
            TextField(
              controller: name,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Your name'),
            ),
            ValueListenableBuilder(
              valueListenable: error,
              builder: (_, value, _) => value == null
                  ? const SizedBox.shrink()
                  : Text(
                      value,
                      style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.error,
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder(
          valueListenable: busy,
          builder: (_, isBusy, _) => FilledButton(
            onPressed: isBusy
                ? null
                : () async {
                    final parsed = WatchPartyService.parseJoinInput(code.text);
                    if (parsed == null) {
                      error.value = 'Party codes have 8 letters and numbers.';
                      return;
                    }
                    if (name.text.trim().isEmpty) {
                      error.value = 'Enter your name.';
                      return;
                    }
                    busy.value = true;
                    error.value = null;
                    try {
                      await _party.joinParty(
                        code: parsed.code,
                        displayName: name.text.trim(),
                        invite: parsed.invite,
                        server: parsed.server,
                      );
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      openWatchPartyGuestScreen();
                    } catch (e) {
                      error.value = '$e';
                    } finally {
                      busy.value = false;
                    }
                  },
            child: const Text('Join'),
          ),
        ),
      ],
    ),
  );
}

bool _guestScreenOpen = false;

void openWatchPartyGuestScreen() {
  final navigator = overnightNavigatorKey.currentState;
  if (navigator == null || _guestScreenOpen || !_party.isGuest) return;
  _guestScreenOpen = true;
  _party.setPanelOpen(false);
  navigator
      .push(
        MaterialPageRoute<void>(builder: (_) => const WatchPartyGuestScreen()),
      )
      .whenComplete(() => _guestScreenOpen = false);
}

/// Toolbar button: starts a watch party for what is playing, or opens the
/// party panel when one is running.
class WatchPartyIconButton extends StatelessWidget {
  final Color? color;
  const WatchPartyIconButton({super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _party,
      builder: (context, _) => IconButton(
        tooltip: _party.active ? 'Watch party' : 'Start a watch party',
        color: color,
        onPressed: () => _party.active
            ? _party.setPanelOpen(true)
            : unawaited(showStartWatchParty(context)),
        icon: Icon(_party.active ? Icons.groups : Icons.groups_outlined),
      ),
    );
  }
}
