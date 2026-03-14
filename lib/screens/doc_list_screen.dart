import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/doc_chunk.dart';
import '../providers/providers.dart';
import 'doc_reader_screen.dart';

/// Lists all documents within a single topic category.
///
/// Docs are loaded from the local SQLite database (docs table).
class DocListScreen extends ConsumerStatefulWidget {
  final DocTopic topic;
  const DocListScreen({super.key, required this.topic});

  @override
  ConsumerState<DocListScreen> createState() => _DocListScreenState();
}

class _DocListScreenState extends ConsumerState<DocListScreen> {
  List<Map<String, dynamic>>? _docs;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDocs();
  }

  Future<void> _loadDocs() async {
    final db = ref.read(databaseServiceProvider);
    final docs = await db.getDocsByTopic(widget.topic.key);
    setState(() {
      _docs = docs;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.topic.displayName),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _docs == null || _docs!.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.menu_book_outlined,
                            size: 48, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text(
                          'No docs available yet.\nSync over WiFi to download survival guides.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _docs!.length,
                  itemBuilder: (context, index) {
                    final doc = _docs![index];
                    final docId = doc['id'] as String;
                    final title = _titleFromId(docId);
                    return ListTile(
                      leading: const Icon(Icons.article_outlined),
                      title: Text(title),
                      subtitle: Text(
                        'v${doc['version']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DocReaderScreen(
                            docId: docId,
                            topic: widget.topic.key,
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  /// Convert doc ID like "medical/tourniquet" to "Tourniquet Application"
  String _titleFromId(String docId) {
    final name = docId.contains('/') ? docId.split('/').last : docId;
    return name
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }
}
