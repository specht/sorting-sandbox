import 'dart:math';

enum InputShape { random, sorted, reversed, nearlySorted, fewValues }

String inputShapeLabel(InputShape shape) => switch (shape) {
      InputShape.random => 'Random',
      InputShape.sorted => 'Sorted',
      InputShape.reversed => 'Reversed',
      InputShape.nearlySorted => 'Nearly sorted',
      InputShape.fewValues => 'Few distinct values',
    };

List<int> makeInput(int n, InputShape shape, {int seed = 42}) {
  final random = Random(seed);
  switch (shape) {
    case InputShape.random:
      final values = List<int>.generate(n, (i) => i + 1)..shuffle(random);
      return values;
    case InputShape.sorted:
      return List<int>.generate(n, (i) => i + 1);
    case InputShape.reversed:
      return List<int>.generate(n, (i) => n - i);
    case InputShape.nearlySorted:
      final values = List<int>.generate(n, (i) => i + 1);
      final swaps = max(1, n ~/ 20);
      for (var i = 0; i < swaps; i++) {
        final a = random.nextInt(max(1, n));
        final b = random.nextInt(max(1, n));
        if (n > 0) {
          final tmp = values[a];
          values[a] = values[b];
          values[b] = tmp;
        }
      }
      return values;
    case InputShape.fewValues:
      return List<int>.generate(n, (_) => random.nextInt(max(2, min(8, n + 1))));
  }
}
