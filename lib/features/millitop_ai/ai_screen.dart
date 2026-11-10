import 'package:flutter/material.dart';
import 'ai_controller.dart';
import 'ai_models.dart';
import 'ai_service.dart';

/// The hosting route must recreate this screen when the active profile changes.
class MillitopAiScreen extends StatefulWidget {
  const MillitopAiScreen({
    super.key,
    required this.profileId,
    required this.service,
    this.demoMode = true,
  });
  final String profileId;
  final AiService service;
  final bool demoMode;
  @override
  State<MillitopAiScreen> createState() => _MillitopAiScreenState();
}

class _MillitopAiScreenState extends State<MillitopAiScreen> {
  late AiController _controller;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    _createController();
  }

  void _createController() {
    _controller = AiController(
      service: widget.service,
      profileId: widget.profileId,
    )..addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant MillitopAiScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profileId != widget.profileId ||
        oldWidget.service != widget.service) {
      _controller.removeListener(_changed);
      _controller.dispose();
      _input.clear();
      _createController();
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send([String? suggestion]) {
    final text = suggestion ?? _input.text;
    if (_controller.busy || text.trim().isEmpty) return;
    if (text.trim().length <= 4000) _input.clear();
    _controller.send(text);
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MILLITOP AI'),
        actions: [
          IconButton(
            tooltip: 'Clear conversation',
            onPressed: _controller.clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!widget.demoMode)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'Local AI chat. No live web search, library or guide access, playback, or recording.',
                        ),
                      ),
                    ),
                  if (widget.demoMode)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'DEMO MODE — no live AI, web search, playback or recording.',
                        ),
                      ),
                    ),
                  Expanded(
                    child: _controller.messages.isEmpty
                        ? SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 28),
                                Text(
                                  'What would you like to discuss?',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.headlineMedium,
                                ),
                                const SizedBox(height: 18),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children:
                                      [
                                            'Suggest three science documentaries',
                                            'Explain basketball overtime rules',
                                            'Suggest movies similar to Interstellar',
                                            'What can you access in MILLITOP TV?',
                                          ]
                                          .map(
                                            (text) => ActionChip(
                                              label: Text(text),
                                              onPressed: _controller.busy
                                                  ? null
                                                  : () => _send(text),
                                            ),
                                          )
                                          .toList(),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            itemCount: _controller.messages.length,
                            itemBuilder: (context, index) {
                              final message = _controller.messages[index];
                              final user = message.role == AiRole.user;
                              return Align(
                                alignment: user
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Card(
                                  color: user
                                      ? Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer
                                      : Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerHighest,
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          user ? 'You' : 'MILLITOP AI',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelLarge,
                                        ),
                                        const SizedBox(height: 6),
                                        SelectableText(message.text),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  if (_controller.busy) const LinearProgressIndicator(),
                  if (_controller.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        _controller.error!,
                        semanticsLabel: _controller.error,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 4,
                          maxLength: 4000,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            labelText: 'Ask MILLITOP AI',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filled(
                        tooltip: 'Send message',
                        onPressed: _controller.busy ? null : () => _send(),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
