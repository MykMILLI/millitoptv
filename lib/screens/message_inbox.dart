import 'package:flutter/material.dart';
import '../services/remote_inbox.dart';
import '../theme/millitop_visual_theme.dart';

class MessageInbox extends StatelessWidget {
  final int profileId;
  const MessageInbox({super.key, required this.profileId});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Updates from your support team',
        style: TextStyle(fontSize: 34, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      ValueListenableBuilder<String>(
        valueListenable: RemoteInbox.instance.syncState,
        builder: (_, status, _) => Text(
          status,
          style: const TextStyle(fontSize: 18, color: Colors.white60),
        ),
      ),
      const SizedBox(height: 18),
      OutlinedButton.icon(
        onPressed: () => RemoteInbox.instance.sync(),
        icon: const Icon(Icons.refresh),
        label: const Text('Check for messages'),
      ),
      const SizedBox(height: 20),
      ValueListenableBuilder<List<RemoteNotice>>(
        valueListenable: RemoteInbox.instance.notices,
        builder: (context, messages, _) {
          if (messages.isEmpty) {
            return const Text(
              'No messages received yet.',
              style: TextStyle(fontSize: 23),
            );
          }
          return Column(
            children: [
              for (final message in messages)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(24),
                        alignment: Alignment.centerLeft,
                      ),
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => MessageDetails(
                            message: message,
                            profileId: profileId,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${message.opened ? '' : 'NEW · '}${message.title}',
                            style: const TextStyle(fontSize: 25),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            message.acknowledged
                                ? (message.ackSynced
                                      ? 'Acknowledged — confirmed by server'
                                      : 'Acknowledged on this PC — awaiting server')
                                : message.requiresAck
                                ? 'Acknowledgement required'
                                : 'Informational message',
                            style: const TextStyle(
                              fontSize: 18,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );
}

class MessageDetails extends StatefulWidget {
  final RemoteNotice message;
  final int profileId;
  const MessageDetails({
    super.key,
    required this.message,
    required this.profileId,
  });
  @override
  State<MessageDetails> createState() => _MessageDetailsState();
}

class _MessageDetailsState extends State<MessageDetails> {
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        RemoteInbox.instance
            .recordAction(widget.message.id, 'opened', widget.profileId)
            .catchError((Object _) {
              if (mounted) {
                setState(() => error = 'Could not save the opened receipt.');
              }
            });
      }
    });
  }

  Future<void> acknowledge() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await RemoteInbox.instance.recordAction(
        widget.message.id,
        'acknowledged',
        widget.profileId,
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not save acknowledgement. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Message')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(36),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: ValueListenableBuilder<List<RemoteNotice>>(
            valueListenable: RemoteInbox.instance.notices,
            builder: (context, messages, _) {
              final matches = messages.where((m) => m.id == widget.message.id);
              final message = matches.isEmpty ? widget.message : matches.first;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message.title, style: const TextStyle(fontSize: 36)),
                  const SizedBox(height: 24),
                  SelectableText(
                    message.body,
                    style: const TextStyle(fontSize: 24, height: 1.6),
                  ),
                  const SizedBox(height: 30),
                  if (message.requiresAck) ...[
                    if (message.acknowledged)
                      Text(
                        message.ackSynced
                            ? 'Acknowledgement confirmed by the server.'
                            : 'Acknowledged on this PC. It will be sent when connected.',
                        style: TextStyle(
                          fontSize: 21,
                          color: context.millitopTheme.accentColor,
                        ),
                      )
                    else
                      FilledButton.icon(
                        onPressed: busy ? null : acknowledge,
                        icon: const Icon(Icons.check_circle_outline),
                        label: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            busy ? 'Saving…' : "I've read this",
                            style: const TextStyle(fontSize: 22),
                          ),
                        ),
                      ),
                  ],
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Text(
                        error!,
                        style: const TextStyle(color: Colors.orangeAccent),
                      ),
                    ),
                  const SizedBox(height: 24),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Back to updates'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}
