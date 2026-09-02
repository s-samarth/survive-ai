import '../models/doc_topic.dart';

/// The two answers the app gives without running a model at all.
///
/// Both are deliberately fixed text. A capability question and a refusal are
/// the two places where a 2B model has the least to add and the most to get
/// wrong, and both are common enough to be worth answering instantly: "what
/// can you do" is usually someone's first message, and a refusal is what
/// stands between the user and improvised advice on a subject the guides do
/// not cover.
///
/// Neither ends flat. A survival app that answers "I can't help with that"
/// and stops has failed a person who may be about to face something it *can*
/// help with, so both close by naming what is available.
///
/// Mirrors `python/survive_rag/responses.py`.
class AppResponses {
  /// Situations listed in a capability answer, before "and more".
  static const int capabilityTopicCount = 8;

  /// Situations listed in a refusal, which must stay short.
  static const int declineTopicCount = 6;

  static String _topicLines(int limit) {
    final topics = DocTopic.values.take(limit);
    final lines = topics.map((t) => '- ${t.displayName}').join('\n');
    return DocTopic.values.length > limit
        ? '$lines\n- …and ${DocTopic.values.length - limit} more'
        : lines;
  }

  /// What the app is and what it can do — the answer to a first message.
  static String capability() =>
      "I'm **Survive AI** — an offline emergency guide for India. I work with "
      'no network, no SIM and no internet, so I keep working during floods, '
      'cyclones, blackouts and shutdowns.\n\n'
      "Tell me what's happening and I'll give you the steps, drawn from guides "
      'written for Indian conditions — with a link to the exact paragraph so '
      'you can read it yourself.\n\n'
      'I cover:\n'
      '${_topicLines(capabilityTopicCount)}\n\n'
      'You can type in English or Hinglish — "saanp ne kaata", "aag lag gayi", '
      '"khoon nikal raha hai" all work.\n\n'
      "**What's happening?**";

  /// A refusal that still tells the user what is available.
  static String decline() =>
      "That's outside what I can help with. I only answer from a set of Indian "
      'emergency and survival guides stored on this phone — I have no '
      "internet, and I won't guess at something this important.\n\n"
      'What I can help with:\n'
      '${_topicLines(declineTopicCount)}\n\n'
      "If you're facing any of those, tell me what's happening. In a "
      'life-threatening emergency, call **112**.';

  /// Appended when the model's answer dropped a warning the guides carry.
  ///
  /// Phrased as the guides phrase it, because the guide text is never wrong
  /// and the model's paraphrase might be.
  static String warningFooter(List<String> omissions) {
    if (omissions.isEmpty) return '';
    final lines = omissions.map((a) => '- **Do not $a.**').join('\n');
    return '\n\n**From the guides — important:**\n$lines';
  }

  /// Shown in place of an answer that contradicted its own reference material.
  static String blocked(List<String> violations) {
    final lines = violations.map((a) => '- **Do not $a.**').join('\n');
    return "I'm not going to answer that from memory — what I drafted "
        'contradicted the guides, so here is what the guides actually say:\n\n'
        '$lines\n\n'
        'Open the guide below for the full steps. In a life-threatening '
        'emergency, call **112**.';
  }
}
