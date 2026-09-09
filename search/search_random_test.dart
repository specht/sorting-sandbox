import 'dart:io';
import 'dart:math';

import 'search.dart';

const int seed = 20260924;

class Result {
  Result(this.name);

  final String name;
  int tests = 0;
  int failures = 0;
  String? firstFailure;

  void check(bool condition, String message) {
    tests++;
    if (condition) return;

    failures++;
    firstFailure ??= message;
  }

  int get passed => tests - failures;
  bool get ok => failures == 0;
}

String color(String text, String code) {
  if (!stdout.supportsAnsiEscapes) return text;
  return '\x1B[${code}m$text\x1B[0m';
}

String green(String text) => color(text, '32');
String red(String text) => color(text, '31');
String bold(String text) => color(text, '1');

List<int> randomList(Random random, int length) {
  return List.generate(
    length,
    (_) => random.nextInt(length * 6 + 21) - (length * 3 + 10),
  );
}

void checkLinear(Result result, List<int> numbers, int value) {
  final expected = numbers.indexOf(value);
  final actual = linearSearch(numbers, value);

  result.check(
    actual == expected,
    'linearSearch($value): erwartet $expected, erhalten $actual '
    '(Listenlänge ${numbers.length})',
  );
}

void checkBinary(Result result, List<int> numbers, int value) {
  final actual = binarySearch(numbers, value);
  final expectedExists = numbers.contains(value);

  if (!expectedExists) {
    result.check(
      actual == -1,
      'binarySearch($value): erwartet -1, erhalten $actual '
      '(Listenlänge ${numbers.length})',
    );
    return;
  }

  final validIndex =
      actual >= 0 &&
      actual < numbers.length &&
      numbers[actual] == value;

  result.check(
    validIndex,
    'binarySearch($value): Index $actual zeigt nicht auf den gesuchten Wert '
    '(Listenlänge ${numbers.length})',
  );
}

void runLinearTests(Result result) {
  final random = Random(seed);

  for (int length = 0; length <= 20; length++) {
    for (int round = 0; round < 5; round++) {
      final numbers = randomList(random, length);

      for (final value in numbers) {
        checkLinear(result, numbers, value);
      }

      checkLinear(result, numbers, -1000000);
      checkLinear(result, numbers, 1000000);
    }
  }

  for (final length in [100, 1000, 10000]) {
    final numbers = randomList(random, length);

    for (final i in [0, length ~/ 4, length ~/ 2, (3 * length) ~/ 4, length - 1]) {
      checkLinear(result, numbers, numbers[i]);
    }

    checkLinear(result, numbers, -1000000);
    checkLinear(result, numbers, 1000000);
  }
}

void runBinaryTests(Result result) {
  final random = Random(seed);

  for (int length = 0; length <= 20; length++) {
    for (int round = 0; round < 5; round++) {
      final numbers = randomList(random, length)..sort();

      for (final value in numbers) {
        checkBinary(result, numbers, value);
      }

      checkBinary(result, numbers, -1000000);
      checkBinary(result, numbers, 1000000);
    }
  }

  for (final length in [100, 1000, 10000]) {
    final numbers = randomList(random, length)..sort();

    for (final i in [0, length ~/ 4, length ~/ 2, (3 * length) ~/ 4, length - 1]) {
      checkBinary(result, numbers, numbers[i]);
    }

    checkBinary(result, numbers, -1000000);
    checkBinary(result, numbers, 1000000);
  }
}

void printResult(Result result) {
  if (result.ok) {
    print('${green('✓')} ${result.name}: ${green('${result.tests}/${result.tests} bestanden')}');
    return;
  }

  print(
    '${red('✗')} ${result.name}: '
    '${red('${result.failures} fehlgeschlagen')}, '
    '${result.passed}/${result.tests} bestanden',
  );

  if (result.firstFailure != null) {
    print('  Erster Fehler: ${result.firstFailure}');
  }
}

void main() {
  final linear = Result('Lineare Suche');
  final binary = Result('Binäre Suche');

  runLinearTests(linear);
  runBinaryTests(binary);

  print('');
  print(bold('Testergebnis'));
  printResult(linear);
  printResult(binary);

  final totalTests = linear.tests + binary.tests;
  final totalFailures = linear.failures + binary.failures;

  print('');
  if (totalFailures == 0) {
    print(green('Alle $totalTests Tests bestanden.'));
  } else {
    print(red('$totalFailures von $totalTests Tests fehlgeschlagen.'));
    exitCode = 1;
  }
}
