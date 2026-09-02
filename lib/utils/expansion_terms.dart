/// Domain vocabulary used by [QueryExpander] to bridge the gap between how
/// Indian users phrase an emergency and how the survival guides word it.
///
/// Three kinds of entry live here:
///
/// 1. **English synonym bridges** — "bleeding" -> "hemorrhage tourniquet".
/// 2. **Hindi / Hinglish transliterations** — a user in a panic types "khoon
///    nikal raha hai", not "haemorrhage". Romanised Hindi and other common
///    Indian-language forms map onto the English terms the corpus actually
///    uses. This is the highest-value part of the table: without it, retrieval
///    silently returns nothing for a large share of real Indian queries.
/// 3. **India-specific nouns** — LPG, lathi, nala, cloudburst, ORS, ASV.
///
/// Keys must be lowercase and single words; the expander matches word by word.
library;

const Map<String, List<String>> kExpansionTerms = {
  // ── Bleeding and wounds ────────────────────────────────────────────────
  'bleeding': [
    'hemorrhage',
    'wound',
    'blood',
    'tourniquet',
    'pressure',
    'dressing',
  ],
  'blood': ['bleeding', 'hemorrhage', 'wound', 'tourniquet', 'pressure'],
  'khoon': ['blood', 'bleeding', 'wound', 'hemorrhage', 'pressure'],
  'baadh': ['flood', 'flooding', 'water', 'evacuate', 'rising'],
  'chakkar': ['dizzy', 'dizziness', 'faint', 'giddy', 'heat', 'collapse'],
  'bheed': ['crowd', 'crush', 'stampede', 'surge', 'packed'],
  'cut': ['wound', 'laceration', 'bleeding', 'bandage', 'dressing'],
  'wound': ['bleeding', 'infection', 'bandage', 'dressing', 'tetanus'],
  'ghaav': ['wound', 'injury', 'bleeding', 'dressing'],
  'chot': ['injury', 'wound', 'hurt', 'trauma', 'bleeding'],
  'tourniquet': ['bleeding', 'hemorrhage', 'limb', 'arterial', 'pressure'],
  'amputation': ['limb', 'bleeding', 'tourniquet', 'crush'],

  // ── Airway, breathing, cardiac ─────────────────────────────────────────
  'breathe': ['breathing', 'airway', 'respiratory', 'cpr', 'oxygen'],
  'breathing': ['airway', 'respiratory', 'cpr', 'ventilation', 'oxygen'],
  'saans': ['breathing', 'airway', 'respiratory', 'breathe', 'oxygen'],
  'choking': ['airway', 'obstruction', 'thrusts', 'blows', 'breathing'],
  'cpr': ['compressions', 'chest', 'resuscitation', 'cardiac', 'breathing'],
  'unconscious': [
    'recovery',
    'position',
    'airway',
    'unresponsive',
    'breathing',
  ],
  'behosh': ['unconscious', 'faint', 'recovery', 'position', 'airway'],
  'heart': ['cardiac', 'chest', 'attack', 'aspirin', 'compressions'],
  'dil': ['heart', 'cardiac', 'chest', 'attack'],
  'stroke': ['paralysis', 'speech', 'face', 'weakness', 'brain'],
  'seizure': ['convulsion', 'fit', 'epilepsy', 'recovery', 'position'],
  'mirgi': ['seizure', 'fit', 'convulsion', 'epilepsy'],

  // ── Injury and illness ─────────────────────────────────────────────────
  'broken': ['fracture', 'splint', 'immobilise', 'bone', 'sling'],
  'fracture': ['broken', 'splint', 'immobilise', 'bone', 'sling'],
  'haddi': ['bone', 'fracture', 'broken', 'splint'],
  'burn': ['scald', 'blister', 'cool', 'water', 'dressing'],
  'jal': ['burn', 'scald', 'cool', 'blister', 'fire'],
  'shock': ['circulation', 'pale', 'clammy', 'elevate', 'legs'],
  'dehydration': ['ors', 'fluid', 'electrolyte', 'rehydration', 'urine'],
  'fever': ['infection', 'temperature', 'dengue', 'malaria', 'typhoid'],
  'bukhar': ['fever', 'temperature', 'infection', 'dengue', 'malaria'],
  'ulti': ['vomiting', 'nausea', 'diarrhoea', 'ors', 'dehydration'],
  'vomiting': ['nausea', 'diarrhoea', 'ors', 'dehydration', 'fluids'],
  'dast': ['diarrhoea', 'ors', 'cholera', 'dehydration', 'zinc'],
  'diarrhoea': ['ors', 'cholera', 'dehydration', 'zinc', 'rehydration'],
  'diarrhea': ['ors', 'cholera', 'dehydration', 'zinc', 'rehydration'],
  'ors': ['rehydration', 'diarrhoea', 'dehydration', 'salt', 'sugar'],
  'poison': ['toxic', 'pesticide', 'organophosphate', 'ingestion', 'atropine'],
  'pesticide': ['poison', 'organophosphate', 'atropine', 'spray', 'toxic'],
  'diabetes': ['sugar', 'insulin', 'hypoglycaemia', 'glucose'],
  'allergic': ['anaphylaxis', 'swelling', 'adrenaline', 'breathing'],

  // ── Bites and stings ───────────────────────────────────────────────────
  'snake': ['snakebite', 'venom', 'cobra', 'krait', 'viper', 'antivenom'],
  'saanp': ['snake', 'snakebite', 'venom', 'cobra', 'krait', 'antivenom'],
  'snakebite': ['venom', 'antivenom', 'immobilise', 'cobra', 'krait', 'viper'],
  'bite': ['snakebite', 'venom', 'rabies', 'wound', 'infection'],
  'kaata': ['bite', 'snakebite', 'sting', 'wound'],
  'venom': ['antivenom', 'snakebite', 'sting', 'scorpion', 'swelling'],
  'cobra': ['snake', 'venom', 'neurotoxic', 'antivenom', 'naja'],
  'krait': ['snake', 'venom', 'neurotoxic', 'antivenom', 'night'],
  'viper': ['snake', 'venom', 'haemotoxic', 'antivenom', 'bleeding'],
  'scorpion': ['sting', 'venom', 'prazosin', 'pain'],
  'bichhu': ['scorpion', 'sting', 'venom', 'pain'],
  'dog': ['rabies', 'bite', 'vaccine', 'immunoglobulin', 'wash'],
  'kutta': ['dog', 'rabies', 'bite', 'vaccine'],
  'rabies': ['vaccine', 'bite', 'dog', 'immunoglobulin', 'wash'],
  'mosquito': ['dengue', 'malaria', 'net', 'repellent', 'standing'],
  'machhar': ['mosquito', 'dengue', 'malaria', 'net', 'repellent'],
  'dengue': ['mosquito', 'fever', 'platelets', 'bleeding', 'fluids'],
  'leech': ['remove', 'bleeding', 'tropical', 'detach'],

  // ── Fire and gas ───────────────────────────────────────────────────────
  'fire': ['smoke', 'flame', 'evacuate', 'extinguisher', 'crawl'],
  'aag': ['fire', 'smoke', 'flame', 'burn', 'evacuate'],
  'smoke': ['fire', 'inhalation', 'crawl', 'low', 'carbon', 'monoxide'],
  'dhuan': ['smoke', 'fire', 'inhalation', 'crawl'],
  'lpg': ['cylinder', 'gas', 'regulator', 'leak', 'spark'],
  'cylinder': ['lpg', 'gas', 'regulator', 'leak', 'bleve'],
  'gas': ['lpg', 'leak', 'cylinder', 'regulator', 'chemical', 'upwind'],
  'leak': ['gas', 'lpg', 'chemical', 'regulator', 'ventilate'],
  'shortcircuit': ['electrical', 'wiring', 'fire', 'mains', 'mcb'],
  'electric': ['electrocution', 'shock', 'mains', 'isolate', 'wire'],
  'bijli': ['electricity', 'electrical', 'shock', 'wire', 'mains'],
  'extinguisher': ['fire', 'powder', 'pass', 'aim', 'base'],

  // ── Earthquake, collapse, landslide ────────────────────────────────────
  'earthquake': ['quake', 'aftershock', 'collapse', 'rubble', 'drop', 'cover'],
  'bhookamp': ['earthquake', 'quake', 'aftershock', 'collapse', 'rubble'],
  'bhukamp': ['earthquake', 'quake', 'aftershock', 'collapse', 'rubble'],
  'aftershock': ['earthquake', 'collapse', 'structure', 'evacuate'],
  'collapse': ['rubble', 'debris', 'trapped', 'structural', 'crush'],
  'rubble': ['collapse', 'trapped', 'tapping', 'crush', 'debris', 'dust'],
  'trapped': ['rubble', 'collapse', 'tapping', 'signal', 'crush', 'void'],
  'landslide': ['debris', 'slope', 'slide', 'boulder', 'cloudburst'],
  'bhooskhalan': ['landslide', 'slope', 'debris', 'slide'],
  'cloudburst': ['flash', 'flood', 'landslide', 'nala', 'rain'],
  'avalanche': ['snow', 'slab', 'buried', 'probe', 'air'],
  'crack': ['structural', 'column', 'shear', 'damage', 'evacuate'],

  // ── Water: flood, drowning, tsunami, cyclone ───────────────────────────
  'flood': ['flooding', 'water', 'evacuate', 'ground', 'drown', 'current'],
  'baad': ['flood', 'flooding', 'water', 'evacuate', 'drown'],
  'paani': ['water', 'flood', 'drinking', 'boil', 'purify'],
  'drowning': ['rescue', 'reach', 'throw', 'breaths', 'cpr', 'water'],
  'doob': ['drowning', 'water', 'rescue', 'breaths'],
  'tsunami': ['wave', 'inland', 'uphill', 'coast', 'withdraw', 'earthquake'],
  'cyclone': ['storm', 'surge', 'shelter', 'wind', 'eye', 'landfall'],
  'toofan': ['cyclone', 'storm', 'wind', 'shelter', 'surge'],
  'surge': ['cyclone', 'storm', 'coast', 'inland', 'elevation'],
  'dam': ['release', 'reservoir', 'downstream', 'flood', 'gates'],
  'nala': ['stream', 'flash', 'flood', 'channel', 'gully'],
  'purify': ['boil', 'chlorine', 'filter', 'bleach', 'sodis', 'water'],
  'boil': ['water', 'purify', 'rolling', 'minute', 'safe'],

  // ── Heat and cold ──────────────────────────────────────────────────────
  'heat': ['heatstroke', 'exhaustion', 'shade', 'cooling', 'ors', 'water'],
  'garmi': ['heat', 'heatstroke', 'shade', 'water', 'cooling'],
  'lu': ['heatwave', 'heatstroke', 'heat', 'shade', 'water'],
  'heatstroke': ['cooling', 'confusion', 'immersion', 'ice', 'shade'],
  'heatwave': ['heatstroke', 'shade', 'water', 'ors', 'cooling'],
  'cold': ['hypothermia', 'insulation', 'shivering', 'dry', 'warm'],
  'thand': ['cold', 'hypothermia', 'warm', 'insulation', 'shivering'],
  'hypothermia': ['shivering', 'insulation', 'warm', 'dry', 'core'],
  'frostbite': ['rewarm', 'numb', 'cold', 'altitude', 'water'],
  'altitude': ['ams', 'hace', 'hape', 'descend', 'headache', 'oxygen'],

  // ── Crowd, unrest, conflict ────────────────────────────────────────────
  'stampede': ['crowd', 'crush', 'density', 'asphyxia', 'sideways'],
  'bhagdad': ['stampede', 'crowd', 'crush', 'density'],
  'crowd': ['crush', 'stampede', 'density', 'asphyxia', 'exit', 'edge'],
  'crush': ['crowd', 'stampede', 'asphyxia', 'chest', 'boxer'],
  'riot': ['unrest', 'mob', 'violence', 'curfew', 'shelter', 'shutter'],
  'danga': ['riot', 'unrest', 'mob', 'violence', 'curfew'],
  'mob': ['riot', 'violence', 'shelter', 'terrace', 'escape'],
  'curfew': ['section', 'prohibitory', 'pass', 'relaxation', 'identification'],
  'protest': ['crowd', 'police', 'teargas', 'lathi', 'disperse'],
  'teargas': ['gas', 'eyes', 'water', 'upwind', 'flush', 'mask'],
  'lathi': ['charge', 'police', 'baton', 'head', 'sideways'],
  'shutdown': ['internet', 'blackout', 'sms', 'network', 'radio', 'voice'],
  'internet': ['shutdown', 'network', 'data', 'sms', 'offline', 'radio'],
  'network': ['signal', 'tower', 'sms', 'shutdown', 'offline', 'call'],
  'signal': ['network', 'whistle', 'mirror', 'tapping', 'rescue', 'sos'],

  // ── Blast, war ─────────────────────────────────────────────────────────
  'bomb': ['blast', 'explosion', 'device', 'secondary', 'cover'],
  'blast': ['explosion', 'bomb', 'fragment', 'secondary', 'lung'],
  'dhamaka': ['blast', 'explosion', 'bomb', 'cover'],
  'explosion': ['blast', 'bomb', 'fragment', 'cover', 'secondary'],
  'shooting': ['shooter', 'gunfire', 'run', 'hide', 'cover', 'barricade'],
  'gunfire': ['shooter', 'shooting', 'cover', 'concealment', 'hide'],
  'terrorist': ['attack', 'blast', 'shooter', 'hostage', 'evacuate'],
  'hostage': ['captor', 'comply', 'rescue', 'floor', 'still'],
  'shelling': ['artillery', 'salvo', 'cover', 'basement', 'flat'],
  'airstrike': ['siren', 'shelter', 'basement', 'cover', 'raid'],
  'siren': ['alert', 'raid', 'shelter', 'warning', 'clear'],
  'drone': ['overhead', 'cover', 'disperse', 'light', 'observation'],
  'mine': ['landmine', 'ordnance', 'unexploded', 'footsteps', 'path'],
  'radiation': ['fallout', 'shelter', 'iodine', 'decontaminate', 'inside'],

  // ── Chemical and industrial ────────────────────────────────────────────
  'chemical': ['gas', 'upwind', 'uphill', 'decontaminate', 'cloud', 'mask'],
  'chlorine': ['gas', 'upwind', 'uphill', 'heavier', 'lungs'],
  'ammonia': ['gas', 'upwind', 'water', 'cloth', 'irritant'],
  'acid': ['flush', 'water', 'burn', 'clothing', 'neutralise'],
  'tezaab': ['acid', 'burn', 'flush', 'water'],
  'manhole': ['confined', 'sewer', 'septic', 'sulphide', 'rescue', 'rope'],
  'septic': ['manhole', 'confined', 'sulphide', 'oxygen', 'rescue'],
  'upwind': ['wind', 'uphill', 'gas', 'cloud', 'escape'],

  // ── Shelter, navigation, rescue ────────────────────────────────────────
  'shelter': ['shade', 'tarpaulin', 'insulation', 'ground', 'lean'],
  'shade': ['shelter', 'heat', 'sun', 'tarpaulin', 'cool'],
  'lost': ['navigation', 'stop', 'direction', 'sun', 'polaris', 'water'],
  'rescue': ['signal', 'whistle', 'mirror', 'ndrf', 'sos', 'three'],
  'whistle': ['signal', 'three', 'blasts', 'rescue', 'distress'],
  'stranded': ['vehicle', 'stay', 'signal', 'water', 'shade'],

  // ── People ─────────────────────────────────────────────────────────────
  'baby': ['infant', 'newborn', 'breastfeeding', 'nappies', 'ors'],
  'bachcha': ['child', 'infant', 'baby', 'children'],
  'child': ['children', 'infant', 'ors', 'dehydration', 'separated'],
  'pregnant': ['pregnancy', 'labour', 'delivery', 'bleeding', 'eclampsia'],
  'garbhvati': ['pregnant', 'pregnancy', 'labour', 'delivery'],
  'delivery': ['labour', 'birth', 'newborn', 'cord', 'placenta'],
  'elderly': ['older', 'medication', 'dehydration', 'isolated', 'dialysis'],
  'buzurg': ['elderly', 'older', 'medication', 'frail'],
  'disabled': [
    'disability',
    'wheelchair',
    'accessible',
    'assistive',
    'evacuate',
  ],
  'panic': ['calm', 'breathing', 'stop', 'think', 'focus'],
  'ghabrahat': ['panic', 'anxiety', 'calm', 'breathing'],
  'suicide': ['helpline', 'telemanas', 'pesticide', 'listen', 'alone'],
  'depression': ['mental', 'helpline', 'telemanas', 'sleep', 'support'],

  // ── Generic ────────────────────────────────────────────────────────────
  'help': ['rescue', 'emergency', 'signal', 'sos', 'helpline'],
  'madad': ['help', 'rescue', 'emergency', 'signal'],
  'emergency': ['urgent', 'critical', 'immediate', 'helpline', 'danger'],
  'danger': ['hazard', 'threat', 'risk', 'evacuate', 'safety'],
  'khatra': ['danger', 'hazard', 'threat', 'risk'],
  'evacuate': ['evacuation', 'leave', 'route', 'shelter', 'rally'],
  'safe': ['safety', 'shelter', 'secure', 'protect'],
  'bachao': ['rescue', 'save', 'help', 'emergency'],
};
