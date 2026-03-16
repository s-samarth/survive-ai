import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/doc_chunk.dart';

/// Displays a list of survival situation categories.
/// Tapping a situation opens the full guide rendered as Markdown.
class TopicBrowserScreen extends StatelessWidget {
  const TopicBrowserScreen({super.key});

  static const _situations = [
    _SituationItem(topic: DocTopic.war, icon: Icons.shield_outlined, color: Color(0xFFB71C1C)),
    _SituationItem(topic: DocTopic.medical, icon: Icons.medical_services_outlined, color: Color(0xFF1565C0)),
    _SituationItem(topic: DocTopic.jungle, icon: Icons.forest_outlined, color: Color(0xFF2E7D32)),
    _SituationItem(topic: DocTopic.desert, icon: Icons.wb_sunny_outlined, color: Color(0xFFF57F17)),
    _SituationItem(topic: DocTopic.urban, icon: Icons.location_city_outlined, color: Color(0xFF4527A0)),
    _SituationItem(topic: DocTopic.general, icon: Icons.star_outline, color: Color(0xFF00695C)),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _situations.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = _situations[index];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: item.color.withValues(alpha: 0.12),
            child: Icon(item.icon, color: item.color, size: 22),
          ),
          title: Text(item.topic.displayName),
          subtitle: Text('${item.topic.displayName} survival guide'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => _GuideScreen(topic: item.topic, color: item.color),
            ),
          ),
        );
      },
    );
  }
}

class _SituationItem {
  final DocTopic topic;
  final IconData icon;
  final Color color;
  const _SituationItem({required this.topic, required this.icon, required this.color});
}

/// Renders a bundled survival guide as formatted Markdown.
class _GuideScreen extends StatefulWidget {
  final DocTopic topic;
  final Color color;
  const _GuideScreen({required this.topic, required this.color});

  @override
  State<_GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<_GuideScreen> {
  String? _markdown;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final content = await rootBundle.loadString(
        'docs/survival_guides/${widget.topic.name}.md',
      );
      if (mounted) setState(() => _markdown = content);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.topic.displayName} Survival'),
        backgroundColor: widget.color.withValues(alpha: 0.08),
      ),
      body: _markdown != null
          ? Markdown(data: _markdown!, padding: const EdgeInsets.all(16), selectable: true)
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(_error!, style: TextStyle(color: Colors.red[700])),
                  ),
                )
              : const Center(child: CircularProgressIndicator()),
    );
  }
}
