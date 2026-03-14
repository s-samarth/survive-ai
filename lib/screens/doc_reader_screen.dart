import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'chat_screen.dart';

/// Renders a survival doc in full Markdown, read from local storage.
///
/// Includes a button to open a scoped chat about this doc's topic.
class DocReaderScreen extends StatefulWidget {
  final String docId;
  final String topic;

  const DocReaderScreen({
    super.key,
    required this.docId,
    required this.topic,
  });

  @override
  State<DocReaderScreen> createState() => _DocReaderScreenState();
}

class _DocReaderScreenState extends State<DocReaderScreen> {
  String? _markdown;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDoc();
  }

  Future<void> _loadDoc() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      // Doc ID is like "medical/tourniquet", filename is the last part + .md
      final filename = widget.docId.contains('/')
          ? '${widget.docId.split('/').last}.md'
          : '${widget.docId}.md';
      final filePath = p.join(appDir.path, 'docs', widget.topic, filename);
      final file = File(filePath);

      if (await file.exists()) {
        final content = await file.readAsString();
        setState(() {
          _markdown = content;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Document file not found.';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.docId.contains('/')
        ? widget.docId.split('/').last.replaceAll('_', ' ')
        : widget.docId;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(_error!, style: TextStyle(color: Colors.red[700])),
                  ),
                )
              : Markdown(
                  data: _markdown!,
                  padding: const EdgeInsets.all(16),
                  selectable: true,
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: Text('Ask about $title')),
              body: ChatScreen(topicFilter: widget.topic),
            ),
          ),
        ),
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('Ask AI'),
      ),
    );
  }
}
