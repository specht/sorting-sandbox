// A tiny test harness so the tests run with plain `dart run` and need no
// extra packages. Usage: call test(...) in main(); failures set exitCode 1.
import 'dart:async';
import 'dart:io';

final _tests = <(String, FutureOr<void> Function())>[];

/// Thrown by a test that cannot run here (e.g. a toolchain is missing).
class Skipped implements Exception {
  Skipped(this.reason);
  final String reason;
}

void test(String name, FutureOr<void> Function() body) {
  _tests.add((name, body));
  if (_tests.length == 1) scheduleMicrotask(_run);
}

Future<void> _run() async {
  var failed = 0;
  var skipped = 0;
  for (final (name, body) in _tests) {
    try {
      await body();
      stdout.writeln('  ✓ $name');
    } on Skipped catch (skip) {
      skipped++;
      stdout.writeln('  – $name (skipped: ${skip.reason})');
    } catch (error, stack) {
      failed++;
      stdout.writeln('  ✗ $name\n    $error\n${_indent(stack)}');
    }
  }
  final skipNote = skipped == 0 ? '' : ', $skipped skipped';
  stdout.writeln(failed == 0
      ? '${_tests.length - skipped} tests passed$skipNote.'
      : '$failed of ${_tests.length} tests FAILED$skipNote.');
  if (failed > 0) exitCode = 1;
}

String _indent(StackTrace stack) =>
    stack.toString().split('\n').take(8).map((line) => '      $line').join('\n');

const isTrue = true;
const isFalse = false;

void expect(Object? actual, Object? expected, {String? reason}) {
  if (!_equals(actual, expected)) {
    throw StateError('Expected: $expected\n    Actual:   $actual'
        '${reason == null ? '' : '\n    ($reason)'}');
  }
}

void expectContains(String text, String part) {
  if (!text.contains(part)) {
    throw StateError('Expected the text to contain "$part":\n$text');
  }
}

bool _equals(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_equals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Set && b is Set) {
    return a.length == b.length && a.every((x) => b.any((y) => _equals(x, y)));
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_equals(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}
