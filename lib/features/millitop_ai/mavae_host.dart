import 'package:flutter/material.dart';
import 'ai_controller.dart';
import 'ai_models.dart';
import 'backend_ai_service.dart';
import 'mavae_catalog_service.dart';
import '../../screens/live_tv_media_screen.dart';
import '../../services/device_connection.dart';

class MavaeHost extends StatefulWidget {
  const MavaeHost({super.key, required this.profileId, required this.child});
  final int profileId;
  final Widget child;
  @override
  State<MavaeHost> createState() => _MavaeHostState();
}

class _MavaeHostState extends State<MavaeHost> {
  late final MavaeCatalogService _catalog = MavaeCatalogService(
    profileId: widget.profileId,
    fallback: BackendAiService.pairedDevice(),
  );
  late final AiController _controller = AiController(
    service: _catalog,
    profileId: widget.profileId.toString(),
  );
  bool _open = false;

  Future<void> _show() async {
    if (_open) return;
    _open = true;
    var expanded = false;
    try {
      final selected = await showDialog<AiMediaMatch>(
        context: context,
        useRootNavigator: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) {
            final size = MediaQuery.sizeOf(context);
            final full = expanded || size.width < 700;
            return Dialog(
              insetPadding: EdgeInsets.all(full ? 8 : 24),
              child: SizedBox(
                width: full ? size.width : 620,
                height: full ? size.height : size.height * .82,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Row(
                        children: [
                          const Icon(Icons.auto_awesome),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Mavae',
                              style: TextStyle(
                                fontFamily: 'Arial',
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (size.width >= 700)
                            IconButton(
                              tooltip: expanded
                                  ? 'Compact chat'
                                  : 'Expand Mavae',
                              onPressed: () =>
                                  update(() => expanded = !expanded),
                              icon: Icon(
                                expanded
                                    ? Icons.fullscreen_exit
                                    : Icons.fullscreen,
                              ),
                            ),
                          IconButton(
                            tooltip: 'Close Mavae',
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _MavaeConversation(
                        controller: _controller,
                        onOpen: (item) => Navigator.of(dialogContext).pop(item),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
      if (selected != null && mounted) {
        final connection = DeviceConnection.instance.connectionKey;
        final listed = await _catalog.stillListed(selected);
        if (!mounted) return;
        if (!listed || DeviceConnection.instance.connectionKey != connection) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'This source or cached title changed. Search again.',
              ),
            ),
          );
          return;
        }
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => LiveTvMediaScreen(
              profileId: widget.profileId,
              initialSourceId: selected.sourceId,
              initialMediaType: selected.mediaType,
              initialMediaId: selected.mediaId,
              autoResume: true,
            ),
          ),
        );
      }
    } finally {
      _open = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      Positioned(
        right: 18,
        bottom: 150,
        child: SafeArea(
          child: Material(
            elevation: 6,
            color: Theme.of(context).colorScheme.primaryContainer,
            shape: const CircleBorder(),
            child: IconButton(
              key: const ValueKey('mavae-launcher'),
              tooltip: 'Open Mavae',
              iconSize: 28,
              padding: const EdgeInsets.all(16),
              onPressed: _show,
              icon: const Icon(Icons.auto_awesome),
            ),
          ),
        ),
      ),
    ],
  );
}

class _MavaeConversation extends StatefulWidget {
  const _MavaeConversation({required this.controller, required this.onOpen});
  final ValueChanged<AiMediaMatch> onOpen;
  final AiController controller;
  @override
  State<_MavaeConversation> createState() => _MavaeConversationState();
}

class _MavaeConversationState extends State<_MavaeConversation> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrollToLatest);
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _send() {
    if (widget.controller.busy) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    widget.controller.send(text);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scrollToLatest);
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final messages = controller.messages;
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            const Text(
              'Mavae: local chat + cached IPTV/Jellyfin title lookup. Search history is not connected yet.',
              style: TextStyle(fontFamily: 'Arial', fontSize: 13, height: 1.4),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: controller.busy ? null : controller.clear,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Clear chat'),
              ),
            ),
            Expanded(
              child: messages.isEmpty
                  ? const Center(
                      child: Text(
                        'Hi, I am Mavae. What would you like to discuss?',
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final message = messages[index];
                        final user = message.role == AiRole.user;
                        return Align(
                          alignment: user
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Card(
                            color: user
                                ? Theme.of(context).colorScheme.primaryContainer
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    user ? 'You' : 'Mavae',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  SelectableText(
                                    message.text,
                                    style: const TextStyle(
                                      fontFamily: 'Arial',
                                      fontSize: 16,
                                      height: 1.5,
                                    ),
                                  ),
                                  for (final item in message.media)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Theme.of(
                                              context,
                                            ).dividerColor,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item.title,
                                              style: const TextStyle(
                                                fontFamily: 'Arial',
                                                fontSize: 17,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            Text(
                                              '${item.year ?? "Year unknown"} | ${item.mediaType} | ${item.sourceName}',
                                            ),
                                            Text(
                                              'Catalog cached: ${item.cachedAt.toLocal().toString().split(".").first}',
                                            ),
                                            const SizedBox(height: 8),
                                            FilledButton.icon(
                                              onPressed: controller.busy
                                                  ? null
                                                  : () => widget.onOpen(item),
                                              icon: Icon(
                                                item.mediaType == 'series'
                                                    ? Icons.video_library
                                                    : Icons.play_arrow,
                                              ),
                                              label: Text(
                                                item.mediaType == 'series'
                                                    ? 'Open series'
                                                    : 'Play movie',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (controller.busy) const LinearProgressIndicator(),
            if (controller.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(controller.error!),
              ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    style: const TextStyle(
                      fontFamily: 'Arial',
                      fontSize: 16,
                      height: 1.4,
                    ),
                    enabled: !controller.busy,
                    minLines: 1,
                    maxLines: 3,
                    maxLength: 4000,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      labelText: 'Ask Mavae',
                      labelStyle: TextStyle(fontFamily: 'Arial', fontSize: 16),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send message',
                  onPressed: controller.busy ? null : _send,
                  icon: const Icon(Icons.arrow_upward),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
