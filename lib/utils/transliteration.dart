/// Which expansion keys are romanised Hindi.
///
/// The router needs this because embedding models are trained on Devanagari
/// and score romanised Hindi barely above out-of-corpus noise, so a Hinglish
/// emergency needs a signal the embedding cannot provide.
///
/// Marked explicitly rather than inferred. Inferring the subset as "an
/// expansion key the corpus never uses" looked elegant and was wrong: the
/// guides mention `aag` once, so a query of "aag" — fire — was not recognised
/// as Hinglish and came within 0.003 of being declined outright. An explicit
/// list cannot be silently invalidated by a guide edit.
///
/// Mirrors `python/survive_rag/retrieval/transliteration.py`.
const Set<String> kTransliteratedTerms = {
  'aag', 'baad', 'baadh', 'bachao', 'bachcha', 'behosh', 'bhagdad',
  'bheed', 'bhookamp', 'bhooskhalan', 'bhukamp', 'bichhu', 'bijli',
  'bukhar', 'chakkar', 'chot', 'danga', 'dast', 'dhamaka', 'dhuan', 'dil',
  'doob', 'garbhvati', 'garmi', 'ghaav', 'ghabrahat', 'haddi', 'jal',
  'kaata', 'khatra', 'khoon', 'kutta', 'lathi', 'lu', 'machhar', 'madad',
  'mirgi', 'nala', 'paani', 'saanp', 'saans', 'tezaab', 'thand', 'toofan',
  'ulti',
};
