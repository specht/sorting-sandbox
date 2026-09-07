import 'models.dart';

/// Returns a new list in the order used by the algorithm-picking UI.
///
/// The order is deliberately independent of student directory/file order:
///
///   family -> variant -> author -> name -> id
///
/// Known teaching families come first; unfamiliar/experimental algorithms are
/// kept afterwards in ordinary alphabetical order. Matching is intentionally
/// forgiving so names such as `insertion Sort`, `SelectSort` and
/// `Quick Sort - lomuto` still land in the expected family.
List<AlgorithmMeta> algorithmsInDisplayOrder(
  Iterable<AlgorithmMeta> algorithms,
) {
  final ordered = List<AlgorithmMeta>.of(algorithms);
  ordered.sort(compareAlgorithmsForDisplay);
  return ordered;
}

int compareAlgorithmsForDisplay(AlgorithmMeta a, AlgorithmMeta b) {
  final aName = _normalize(a.name);
  final bName = _normalize(b.name);
  final aFamily = _familyFor(aName);
  final bFamily = _familyFor(bName);

  final aRank = aFamily?.rank ?? _familyPrefixes.length;
  final bRank = bFamily?.rank ?? _familyPrefixes.length;
  var comparison = aRank.compareTo(bRank);
  if (comparison != 0) return comparison;

  if (aFamily == null && bFamily == null) {
    comparison = aName.compareTo(bName);
  } else {
    final aVariant = _variantKey(aName, aFamily!, a.author);
    final bVariant = _variantKey(bName, bFamily!, b.author);
    comparison = aVariant.compareTo(bVariant);
  }
  if (comparison != 0) return comparison;

  comparison = _normalize(a.author).compareTo(_normalize(b.author));
  if (comparison != 0) return comparison;

  comparison = aName.compareTo(bName);
  if (comparison != 0) return comparison;
  return a.id.compareTo(b.id);
}

const _familyPrefixes = <List<String>>[
  ['bubble sort', 'bubblesort'],
  ['insertion sort', 'insert sort', 'insertionsort', 'insertsort'],
  ['selection sort', 'select sort', 'selectionsort', 'selectsort'],
  ['merge sort', 'mergesort'],
  ['quick sort', 'quicksort'],
];

({int rank, String prefix})? _familyFor(String normalizedName) {
  for (var rank = 0; rank < _familyPrefixes.length; rank++) {
    for (final prefix in _familyPrefixes[rank]) {
      if (normalizedName == prefix || normalizedName.startsWith('$prefix ')) {
        return (rank: rank, prefix: prefix);
      }
    }
  }
  return null;
}

String _variantKey(
  String normalizedName,
  ({int rank, String prefix}) family,
  String author,
) {
  var rest = normalizedName.substring(family.prefix.length).trim();
  final normalizedAuthor = _normalize(author);

  // "Quick Sort by Ovilli" is still a plain Quick Sort implementation, not a
  // separate algorithmic variant. Keep that harmless naming flourish from
  // pushing it behind Hoare/Lomuto variants.
  if (normalizedAuthor.isNotEmpty && rest == 'by $normalizedAuthor') {
    rest = '';
  }
  return rest;
}

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');
