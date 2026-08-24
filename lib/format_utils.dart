String compactCount(int value) {
  final negative = value < 0;
  final absolute = value.abs();
  final prefix = negative ? '-' : '';

  if (absolute < 1000) return '$value';

  String scaled(double divisor, String suffix) {
    final amount = absolute / divisor;
    final decimals = amount < 10 ? 1 : 0;
    final text = amount
        .toStringAsFixed(decimals)
        .replaceFirst(RegExp(r'\.0$'), '');
    return '$prefix$text$suffix';
  }

  if (absolute < 999500) return scaled(1000, 'k');
  if (absolute < 999500000) return scaled(1000000, 'M');
  return scaled(1000000000, 'G');
}
