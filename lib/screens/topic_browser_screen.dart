import 'package:flutter/material.dart';
import '../models/doc_chunk.dart';
import 'doc_list_screen.dart';

/// Displays a grid of survival topic categories.
/// Tapping a category shows the docs in that topic.
class TopicBrowserScreen extends StatelessWidget {
  const TopicBrowserScreen({super.key});

  static const _topics = [
    _TopicTile(topic: DocTopic.war, icon: Icons.shield_outlined, color: Color(0xFFB71C1C)),
    _TopicTile(topic: DocTopic.medical, icon: Icons.medical_services_outlined, color: Color(0xFF1565C0)),
    _TopicTile(topic: DocTopic.jungle, icon: Icons.forest_outlined, color: Color(0xFF2E7D32)),
    _TopicTile(topic: DocTopic.desert, icon: Icons.wb_sunny_outlined, color: Color(0xFFF57F17)),
    _TopicTile(topic: DocTopic.urban, icon: Icons.location_city_outlined, color: Color(0xFF4527A0)),
    _TopicTile(topic: DocTopic.general, icon: Icons.star_outline, color: Color(0xFF00695C)),
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.2,
      ),
      itemCount: _topics.length,
      itemBuilder: (context, index) => _TopicCard(tile: _topics[index]),
    );
  }
}

class _TopicCard extends StatelessWidget {
  final _TopicTile tile;
  const _TopicCard({required this.tile});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DocListScreen(topic: tile.topic),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(tile.icon, size: 40, color: tile.color),
              const SizedBox(height: 8),
              Text(
                tile.topic.displayName,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopicTile {
  final DocTopic topic;
  final IconData icon;
  final Color color;
  const _TopicTile({required this.topic, required this.icon, required this.color});
}
