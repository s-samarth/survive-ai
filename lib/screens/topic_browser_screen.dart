import 'package:flutter/material.dart';
import '../models/doc_topic.dart';
import 'guide_reader_screen.dart';

/// Lists every survival situation the app carries offline.
///
/// Ordered by how urgently a user is likely to need it, not alphabetically:
/// the first two entries answer "something just happened" and "my phone is
/// dead", which is the state most users open this app in.
class TopicBrowserScreen extends StatelessWidget {
  const TopicBrowserScreen({super.key});

  static const _accents = <DocTopic, (IconData, Color)>{
    DocTopic.firstResponse: (Icons.bolt_outlined, Color(0xFFC62828)),
    DocTopic.blackout: (Icons.signal_cellular_off, Color(0xFF37474F)),
    DocTopic.medical: (Icons.medical_services_outlined, Color(0xFF1565C0)),
    DocTopic.earthquake: (Icons.foundation_outlined, Color(0xFF6D4C41)),
    DocTopic.flood: (Icons.water_outlined, Color(0xFF0277BD)),
    DocTopic.cyclone: (Icons.cyclone_outlined, Color(0xFF00838F)),
    DocTopic.landslide: (Icons.terrain_outlined, Color(0xFF558B2F)),
    DocTopic.fire: (Icons.local_fire_department_outlined, Color(0xFFE65100)),
    DocTopic.crowd: (Icons.groups_outlined, Color(0xFF6A1B9A)),
    DocTopic.unrest: (Icons.report_gmailerrorred_outlined, Color(0xFF4527A0)),
    DocTopic.blast: (Icons.dangerous_outlined, Color(0xFFB71C1C)),
    DocTopic.war: (Icons.shield_outlined, Color(0xFF33691E)),
    DocTopic.chemical: (Icons.science_outlined, Color(0xFF00695C)),
    DocTopic.heatCold: (Icons.thermostat_outlined, Color(0xFFEF6C00)),
    DocTopic.bites: (Icons.pest_control_outlined, Color(0xFF827717)),
    DocTopic.waterFood: (Icons.water_drop_outlined, Color(0xFF0097A7)),
    DocTopic.shelter: (Icons.cabin_outlined, Color(0xFF5D4037)),
    DocTopic.vulnerable: (Icons.escalator_warning_outlined, Color(0xFFAD1457)),
  };

  static (IconData, Color) _accentFor(DocTopic topic) =>
      _accents[topic] ?? (Icons.article_outlined, const Color(0xFF546E7A));

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: DocTopic.values.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final topic = DocTopic.values[index];
        final (icon, color) = _accentFor(topic);
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(icon, color: color, size: 22),
          ),
          title: Text(topic.displayName),
          subtitle: Text(topic.summary),
          isThreeLine: false,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GuideReaderScreen(topic: topic, accent: color),
            ),
          ),
        );
      },
    );
  }
}
