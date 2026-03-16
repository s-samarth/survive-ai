/// Expands queries with domain-specific survival synonyms and related terms.
///
/// This provides a "semantic-like" retrieval signal by bridging vocabulary
/// gaps between user queries and survival doc terminology. The expanded
/// query is used as a second BM25 search leg in RRF, giving the retrieval
/// pipeline two independent signals to merge.
///
/// Example: "I'm bleeding" → "I'm bleeding hemorrhage wound blood tourniquet
/// pressure dressing bandage"
///
/// Why not a neural embedding model? On 4 GB Android devices, any additional
/// ML runtime (TFLite, MediaPipe, ONNX) alongside the 1.6 GB Gemma model
/// causes OOM. Query expansion is pure Dart, zero memory overhead, and
/// addresses the core retrieval gap: matching user language to medical/
/// survival terminology.
class QueryExpander {
  /// Map from trigger terms to expansion terms.
  /// When a trigger term appears in the query, expansion terms are added.
  static const Map<String, List<String>> _expansions = {
    // ── Medical: bleeding/wounds ──
    'bleeding': ['hemorrhage', 'wound', 'blood', 'tourniquet', 'pressure', 'dressing', 'bandage'],
    'blood': ['bleeding', 'hemorrhage', 'wound', 'tourniquet', 'clotting'],
    'cut': ['wound', 'laceration', 'bleeding', 'bandage', 'stitches', 'suture'],
    'wound': ['bleeding', 'hemorrhage', 'infection', 'bandage', 'dressing', 'tourniquet'],
    'tourniquet': ['bleeding', 'hemorrhage', 'limb', 'arterial', 'pressure'],

    // ── Medical: breathing/airway ──
    'breathe': ['respiratory', 'airway', 'choking', 'breathing', 'cpr', 'oxygen'],
    'breathing': ['respiratory', 'airway', 'choking', 'cpr', 'ventilation'],
    'choking': ['airway', 'heimlich', 'obstruction', 'breathing', 'abdominal', 'thrust'],
    'cpr': ['resuscitation', 'chest', 'compressions', 'breathing', 'cardiac', 'pulse'],
    'drowning': ['water', 'breathing', 'resuscitation', 'cpr', 'airway'],

    // ── Medical: bones/injuries ──
    'broken': ['fracture', 'splint', 'immobilize', 'bone', 'dislocation'],
    'fracture': ['broken', 'splint', 'immobilize', 'bone', 'reduction'],
    'sprain': ['strain', 'swelling', 'ice', 'compress', 'elevate', 'rice'],
    'burn': ['scald', 'blister', 'cool', 'dressing', 'thermal', 'degree'],
    'head': ['concussion', 'skull', 'brain', 'consciousness', 'trauma'],

    // ── Medical: conditions ──
    'fever': ['infection', 'temperature', 'inflammation', 'sepsis', 'antipyretic'],
    'infection': ['wound', 'fever', 'sepsis', 'antibacterial', 'clean', 'pus'],
    'shock': ['circulation', 'pale', 'unconscious', 'blood', 'pressure', 'elevate', 'hypovolemic'],
    'unconscious': ['consciousness', 'faint', 'recovery', 'position', 'airway', 'unresponsive'],
    'faint': ['unconscious', 'dizzy', 'recovery', 'position', 'blood', 'pressure'],
    'dehydration': ['water', 'fluid', 'electrolyte', 'thirst', 'rehydration', 'oral'],
    'hypothermia': ['cold', 'exposure', 'warming', 'temperature', 'shelter', 'insulation', 'shivering'],
    'heatstroke': ['heat', 'overheating', 'cooling', 'temperature', 'shade', 'water', 'exertion'],
    'poison': ['toxic', 'venom', 'antidote', 'ingestion', 'contaminated', 'chemical'],
    'venom': ['snake', 'bite', 'sting', 'poison', 'antivenom', 'swelling'],
    'bite': ['snake', 'venom', 'animal', 'wound', 'infection', 'rabies'],
    'sting': ['insect', 'venom', 'allergic', 'anaphylaxis', 'swelling'],
    'allergic': ['anaphylaxis', 'swelling', 'breathing', 'epinephrine', 'reaction'],
    'seizure': ['convulsion', 'epilepsy', 'recovery', 'position', 'protect'],
    'heart': ['cardiac', 'chest', 'pain', 'attack', 'cpr', 'compressions'],
    'stroke': ['brain', 'paralysis', 'speech', 'face', 'arm', 'fast'],
    'pain': ['injury', 'wound', 'relief', 'compress', 'immobilize'],

    // ── War/conflict ──
    'bomb': ['explosion', 'blast', 'shelling', 'artillery', 'bombardment', 'shelter', 'cover'],
    'bombs': ['explosion', 'blast', 'shelling', 'artillery', 'bombardment', 'shelter'],
    'explosion': ['blast', 'bomb', 'shelling', 'shrapnel', 'detonation', 'cover'],
    'shelling': ['artillery', 'bombardment', 'explosion', 'shelter', 'cover', 'blast'],
    'artillery': ['shelling', 'bombardment', 'explosion', 'shelter', 'cover'],
    'shooting': ['gunfire', 'sniper', 'active', 'shooter', 'cover', 'concealment'],
    'gunfire': ['shooting', 'sniper', 'bullet', 'cover', 'concealment'],
    'sniper': ['shooting', 'gunfire', 'cover', 'concealment', 'movement'],
    'airstrike': ['bombing', 'aircraft', 'shelter', 'basement', 'cover', 'blast'],
    'missile': ['rocket', 'airstrike', 'shelter', 'blast', 'warning', 'siren'],
    'mine': ['landmine', 'explosive', 'ied', 'tripwire', 'ordnance'],
    'ied': ['improvised', 'explosive', 'bomb', 'roadside', 'mine'],
    'chemical': ['gas', 'nerve', 'agent', 'mask', 'decontamination', 'exposure'],
    'radiation': ['nuclear', 'fallout', 'shelter', 'iodine', 'contamination'],
    'checkpoint': ['military', 'crossing', 'identification', 'vehicle', 'inspection'],
    'evacuate': ['evacuation', 'escape', 'route', 'leave', 'flee', 'transport'],
    'war': ['conflict', 'combat', 'military', 'attack', 'defense', 'shelter'],

    // ── Movement/escape ──
    'escape': ['evacuate', 'flee', 'route', 'exit', 'hide', 'evade'],
    'hide': ['concealment', 'cover', 'shelter', 'camouflage', 'escape'],
    'trapped': ['rescue', 'rubble', 'debris', 'collapse', 'extricate', 'signal'],
    'run': ['flee', 'escape', 'sprint', 'evacuate', 'distance'],

    // ── Water ──
    'water': ['hydration', 'purification', 'filter', 'boil', 'drinking', 'source'],
    'thirsty': ['water', 'dehydration', 'hydration', 'fluid', 'drinking'],
    'purify': ['water', 'filter', 'boil', 'disinfect', 'iodine', 'chlorine'],
    'filter': ['water', 'purify', 'clean', 'strain', 'charcoal'],
    'drink': ['water', 'hydration', 'safe', 'purify', 'contaminated'],

    // ── Shelter ──
    'shelter': ['cover', 'protection', 'roof', 'building', 'lean-to', 'debris'],
    'cold': ['hypothermia', 'insulation', 'warmth', 'shelter', 'fire', 'exposure', 'frostbite'],
    'hot': ['heat', 'shade', 'cooling', 'heatstroke', 'water', 'dehydration'],
    'rain': ['wet', 'shelter', 'waterproof', 'hypothermia', 'tarp'],
    'wind': ['windbreak', 'shelter', 'exposure', 'windchill', 'hypothermia'],

    // ── Food ──
    'food': ['nutrition', 'edible', 'forage', 'hunt', 'trap', 'calories'],
    'hungry': ['food', 'nutrition', 'edible', 'forage', 'calories', 'starvation'],
    'eat': ['food', 'edible', 'safe', 'toxic', 'plant', 'forage'],
    'edible': ['food', 'plants', 'forage', 'safe', 'toxic', 'identify'],
    'hunt': ['trap', 'snare', 'food', 'animal', 'fish', 'calories'],

    // ── Fire ──
    'fire': ['flame', 'ignite', 'warmth', 'heat', 'signal', 'bow', 'drill', 'ferro'],
    'smoke': ['fire', 'signal', 'inhalation', 'escape', 'low', 'crawl'],

    // ── Navigation ──
    'lost': ['navigation', 'direction', 'compass', 'stars', 'sun', 'signal'],
    'direction': ['navigation', 'compass', 'north', 'stars', 'sun', 'map'],
    'navigate': ['direction', 'compass', 'stars', 'sun', 'map', 'landmark'],
    'compass': ['direction', 'north', 'navigation', 'bearing', 'magnetic'],

    // ── Signals/rescue ──
    'rescue': ['signal', 'help', 'emergency', 'flare', 'mirror', 'fire', 'whistle'],
    'help': ['rescue', 'signal', 'emergency', 'sos', 'distress'],
    'signal': ['rescue', 'help', 'fire', 'mirror', 'flare', 'whistle', 'sos'],
    'sos': ['signal', 'rescue', 'distress', 'help', 'emergency'],

    // ── Urban/disaster ──
    'earthquake': ['quake', 'tremor', 'collapse', 'aftershock', 'shelter', 'rubble'],
    'flood': ['flooding', 'water', 'rising', 'evacuation', 'high', 'ground'],
    'tsunami': ['wave', 'flood', 'evacuation', 'high', 'ground', 'coast'],
    'collapse': ['rubble', 'debris', 'trapped', 'structural', 'building'],
    'rubble': ['collapse', 'debris', 'trapped', 'rescue', 'dig', 'signal'],
    'tornado': ['wind', 'storm', 'shelter', 'basement', 'debris'],
    'hurricane': ['storm', 'wind', 'flood', 'evacuation', 'shelter'],
    'landslide': ['mud', 'debris', 'evacuation', 'slope', 'rain'],

    // ── Jungle ──
    'jungle': ['tropical', 'rainforest', 'humidity', 'vegetation', 'canopy'],
    'snake': ['venom', 'bite', 'reptile', 'antivenom', 'identify'],
    'malaria': ['mosquito', 'fever', 'parasite', 'prevention', 'net'],
    'mosquito': ['malaria', 'dengue', 'repellent', 'net', 'bite'],
    'leech': ['blood', 'parasite', 'remove', 'salt', 'tropical'],

    // ── Desert ──
    'desert': ['arid', 'sand', 'heat', 'water', 'shade', 'navigation'],
    'sandstorm': ['sand', 'wind', 'cover', 'breathing', 'protection', 'visibility'],
    'scorpion': ['sting', 'venom', 'desert', 'nocturnal', 'pain'],

    // ── Psychological ──
    'scared': ['fear', 'panic', 'calm', 'breathing', 'focus', 'stop'],
    'panic': ['fear', 'calm', 'breathing', 'focus', 'control', 'stop', 'think'],
    'afraid': ['fear', 'panic', 'calm', 'breathing', 'focus'],
    'stress': ['calm', 'breathing', 'focus', 'control', 'mindset'],
    'anxiety': ['panic', 'calm', 'breathing', 'control', 'grounding'],

    // ── General survival ──
    'survive': ['survival', 'emergency', 'danger', 'safety', 'prepare'],
    'danger': ['threat', 'hazard', 'risk', 'safety', 'avoid', 'escape'],
    'die': ['death', 'fatal', 'lethal', 'critical', 'emergency', 'urgent'],
    'dying': ['death', 'fatal', 'critical', 'emergency', 'urgent'],
    'hurt': ['injury', 'wound', 'pain', 'damage', 'first', 'aid'],
    'injured': ['injury', 'wound', 'trauma', 'first', 'aid', 'medical'],
    'emergency': ['urgent', 'critical', 'danger', 'immediate', 'help'],
    'first': ['aid', 'response', 'immediate', 'triage', 'stabilize'],
    'accident': ['injury', 'crash', 'trauma', 'emergency', 'response'],
    'kids': ['child', 'children', 'pediatric', 'infant', 'baby'],
    'child': ['children', 'pediatric', 'infant', 'baby', 'small'],
    'baby': ['infant', 'child', 'newborn', 'pediatric'],
    'pregnant': ['pregnancy', 'labor', 'delivery', 'birth', 'maternal'],
    'elderly': ['older', 'aged', 'frail', 'mobility', 'medication'],
  };

  /// Expand a query with related survival terms.
  ///
  /// Returns the original query with relevant expansion terms appended.
  /// Expansion is capped at 8 terms to avoid diluting the query signal.
  static String expand(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+'));
    final expansions = <String>{};

    for (final word in words) {
      // Direct match
      if (_expansions.containsKey(word)) {
        expansions.addAll(_expansions[word]!);
      }
      // Stem match — try without common suffixes
      final stem = _simpleStem(word);
      if (stem != word && _expansions.containsKey(stem)) {
        expansions.addAll(_expansions[stem]!);
      }
    }

    // Remove words already in the original query
    expansions.removeAll(words);

    if (expansions.isEmpty) return query;

    // Cap at 8 expansion terms to avoid query dilution
    final limited = expansions.take(8).join(' ');
    return '$query $limited';
  }

  /// Very simple stemming — strip common English suffixes.
  ///
  /// This is intentionally basic. Full Porter stemming would over-stem
  /// survival terms (e.g. "compress" → "compr") and break FTS5 matching.
  static String _simpleStem(String word) {
    if (word.endsWith('ing') && word.length > 5) {
      return word.substring(0, word.length - 3);
    }
    if (word.endsWith('ed') && word.length > 4) {
      return word.substring(0, word.length - 2);
    }
    if (word.endsWith('ly') && word.length > 4) {
      return word.substring(0, word.length - 2);
    }
    if (word.endsWith('s') && !word.endsWith('ss') && word.length > 3) {
      return word.substring(0, word.length - 1);
    }
    return word;
  }
}
