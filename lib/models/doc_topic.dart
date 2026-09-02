/// The survival-guide categories bundled with the app.
///
/// Each topic maps 1:1 to a Markdown file at
/// `docs/survival_guides/{name}.md` and to the `topic` column in the
/// `chunks` table, so [name] is the single source of truth for asset
/// paths, database keys, and RAG topic filters.
///
/// The set is India-specific: the taxonomy is organised around the
/// situations that actually cut Indian users off from a network, rather
/// than around generic biomes.
enum DocTopic {
  firstResponse,
  blackout,
  medical,
  earthquake,
  flood,
  cyclone,
  landslide,
  fire,
  crowd,
  unrest,
  blast,
  war,
  chemical,
  heatCold,
  bites,
  waterFood,
  shelter,
  vulnerable;

  /// Database key and Markdown filename stem — e.g. `first_response`.
  ///
  /// Dart enum names are lowerCamelCase; assets and SQL use snake_case.
  String get key => switch (this) {
    DocTopic.firstResponse => 'first_response',
    DocTopic.blackout => 'blackout',
    DocTopic.medical => 'medical',
    DocTopic.earthquake => 'earthquake',
    DocTopic.flood => 'flood',
    DocTopic.cyclone => 'cyclone',
    DocTopic.landslide => 'landslide',
    DocTopic.fire => 'fire',
    DocTopic.crowd => 'crowd',
    DocTopic.unrest => 'unrest',
    DocTopic.blast => 'blast',
    DocTopic.war => 'war',
    DocTopic.chemical => 'chemical',
    DocTopic.heatCold => 'heat_cold',
    DocTopic.bites => 'bites',
    DocTopic.waterFood => 'water_food',
    DocTopic.shelter => 'shelter',
    DocTopic.vulnerable => 'vulnerable',
  };

  String get displayName => switch (this) {
    DocTopic.firstResponse => 'First Response',
    DocTopic.blackout => 'No Network',
    DocTopic.medical => 'Medical Emergency',
    DocTopic.earthquake => 'Earthquake & Collapse',
    DocTopic.flood => 'Flood & Drowning',
    DocTopic.cyclone => 'Cyclone & Tsunami',
    DocTopic.landslide => 'Landslide & Mountains',
    DocTopic.fire => 'Fire & Gas',
    DocTopic.crowd => 'Stampede & Crowds',
    DocTopic.unrest => 'Riot & Curfew',
    DocTopic.blast => 'Blast & Attack',
    DocTopic.war => 'War & Air Raid',
    DocTopic.chemical => 'Chemical & Industrial',
    DocTopic.heatCold => 'Heatwave & Cold Wave',
    DocTopic.bites => 'Snakebite & Animals',
    DocTopic.waterFood => 'Water, Food & Disease',
    DocTopic.shelter => 'Shelter & Stranded',
    DocTopic.vulnerable => 'Children & Elderly',
  };

  /// One-line subtitle shown in the situation browser.
  String get summary => switch (this) {
    DocTopic.firstResponse =>
      'The first five minutes, triage, and what to do first',
    DocTopic.blackout =>
      'Internet shutdowns, dead towers, and reaching help anyway',
    DocTopic.medical =>
      'Bleeding, CPR, burns, fractures, and shock without a hospital',
    DocTopic.earthquake =>
      'During the shaking, reading damage, and being trapped in rubble',
    DocTopic.flood =>
      'Rising water, flash floods, drowning rescue, and afterwards',
    DocTopic.cyclone => 'Warnings, storm surge, the eye, and tsunami',
    DocTopic.landslide => 'Warning signs, being cut off, and Himalayan hazards',
    DocTopic.fire => 'Escaping smoke, LPG leaks, and slum fires',
    DocTopic.crowd => 'Crowd crush, how to breathe, and how to get out',
    DocTopic.unrest => 'Riots, tear gas, lathi charge, and sheltering',
    DocTopic.blast => 'Explosions, gunmen, and secondary devices',
    DocTopic.war => 'Air raids, shelling, drones, and blackout discipline',
    DocTopic.chemical => 'Gas leaks, going upwind, and decontamination',
    DocTopic.heatCold => 'Heat stroke, hypothermia, and surviving both',
    DocTopic.bites => 'The Big Four snakes, rabies, stings, and leeches',
    DocTopic.waterFood => 'Making water safe, ORS, and post-flood disease',
    DocTopic.shelter => 'Shade, warmth, fire, navigation, and signalling',
    DocTopic.vulnerable =>
      'Infants, childbirth, elderly, disability, and mental health',
  };

  /// Asset path of the bundled Markdown guide for this topic.
  String get assetPath => 'docs/survival_guides/$key.md';

  /// Stable document id used in the `docs` registry.
  String get docId => '${key}_guide';

  /// Resolve a database `topic` value back to its enum, or null if unknown
  /// (for example a topic added by a newer manifest than this build knows).
  static DocTopic? fromKey(String key) {
    for (final topic in DocTopic.values) {
      if (topic.key == key) return topic;
    }
    return null;
  }
}
