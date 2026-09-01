import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/doc_topic.dart';
import 'chat_screen.dart';

/// Renders a bundled survival guide as formatted Markdown.
///
/// Guides are read from the app bundle rather than from the synced copy on
/// disk: the bundle is guaranteed present offline from first launch, which is
/// the whole point of the app. Synced updates reach the user through RAG
/// answers; the reader always shows the shipped baseline.
class GuideReaderScreen extends StatefulWidget {
  final DocTopic topic;
  final Color accent;

  const GuideReaderScreen({
    super.key,
    required this.topic,
    required this.accent,
  });

  @override
  State<GuideReaderScreen> createState() => _GuideReaderScreenState();
}

class _GuideReaderScreenState extends State<GuideReaderScreen> {
  String? _markdown;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final content = await rootBundle.loadString(widget.topic.assetPath);
      if (mounted) setState(() => _markdown = content);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.topic.displayName),
        backgroundColor: widget.accent.withValues(alpha: 0.08),
      ),
      body: switch ((_markdown, _error)) {
        (final String md, _) => Markdown(
          data: md,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
          selectable: true,
        ),
        (_, final String err) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(err, style: TextStyle(color: Colors.red[700])),
          ),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: Text('Ask: ${widget.topic.displayName}')),
              body: ChatScreen(topicFilter: widget.topic.key),
            ),
          ),
        ),
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('Ask AI'),
      ),
    );
  }
}
