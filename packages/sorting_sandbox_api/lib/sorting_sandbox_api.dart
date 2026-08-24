/// The deliberately tiny API students program against.
library;


/// Small Flutter-free convenience palette for student metadata.
///
/// Students can use these names just like the old project, or return any
/// `#RRGGBB` string for a fully custom color.
abstract final class Colors {
  static const red = '#F44336';
  static const pink = '#E91E63';
  static const purple = '#9C27B0';
  static const deepPurple = '#673AB7';
  static const indigo = '#3F51B5';
  static const blue = '#2196F3';
  static const lightBlue = '#03A9F4';
  static const cyan = '#00BCD4';
  static const teal = '#009688';
  static const green = '#4CAF50';
  static const lightGreen = '#8BC34A';
  static const lime = '#CDDC39';
  static const yellow = '#FFEB3B';
  static const amber = '#FFC107';
  static const orange = '#FF9800';
  static const deepOrange = '#FF5722';
  static const brown = '#795548';
  static const blueGrey = '#607D8B';
}

/// Marker base class for one sorting algorithm.
///
/// Student implementations provide [name], [color] and a synchronous `sort`
/// method. [author] is optional; when omitted, the sandbox uses the student
/// directory name. `sort` is intentionally not declared here: the build tool
/// creates a second, asynchronous visual version without changing the file.
abstract class SortingAlgorithm {
  String get name;
  String get color;
  String? get author => null;
}

/// One sortable item.
///
/// The key and original position are intentionally private. Students move and
/// compare elements; the sandbox can therefore count comparisons and test
/// stability without adding any student-facing bookkeeping.
class Element {
  Element._(this._key, this._origin, this._probe);

  final int _key;
  final int _origin;
  final OperationProbe _probe;

  bool operator <(Element other) {
    _probe.onComparison();
    return _key < other._key;
  }

  bool operator <=(Element other) {
    _probe.onComparison();
    return _key <= other._key;
  }

  bool operator >(Element other) {
    _probe.onComparison();
    return _key > other._key;
  }

  bool operator >=(Element other) {
    _probe.onComparison();
    return _key >= other._key;
  }

  @override
  bool operator ==(Object other) {
    if (other is! Element) return false;
    _probe.onComparison();
    return _key == other._key;
  }

  @override
  int get hashCode => _key.hashCode;

  /// Only for visualization/debug output. Sorting code should compare Elements.
  @override
  String toString() => _key.toString();

  ElementState _state() => ElementState(_key, _origin);
}

/// Instrumented list used by student algorithms.
class Elements {
  Elements.runtime({
    required OperationProbe probe,
    required String label,
    required List<int> values,
    List<int>? origins,
  })  : _probe = probe,
        _label = label,
        _elements = <Element>[] {
    final actualOrigins = origins ?? List<int>.generate(values.length, (i) => i);
    if (actualOrigins.length != values.length) {
      throw ArgumentError('origins and values must have equal length');
    }
    for (var i = 0; i < values.length; i++) {
      _elements.add(Element._(values[i], actualOrigins[i], probe));
    }
    _probe.onInit(_label, _elements.map((e) => e._state()).toList());
  }

  final OperationProbe _probe;
  final String _label;
  final List<Element> _elements;

  int get length => _elements.length;

  Element operator [](int index) {
    final value = _elements[index];
    _probe.onRead(_label, index, value._state());
    return value;
  }

  void operator []=(int index, Element value) {
    _elements[index] = value;
    _probe.onWrite(_label, index, value._state());
  }

  /// Convenience only: exactly the same two reads and two writes as a
  /// hand-written swap with a temporary variable.
  void swap(int a, int b) {
    final temp = this[b];
    this[b] = this[a];
    this[a] = temp;
  }
}

/// Internal runtime snapshot of an Element.
///
/// Students never need this type; it is public only because the API and worker
/// runtime are separate Dart packages/libraries.
class ElementState {
  const ElementState(this.key, this.origin);

  final int key;
  final int origin;

  Map<String, int> toJson() => {'key': key, 'origin': origin};
}

/// Callback surface implemented by the sandbox runtime.
abstract interface class OperationProbe {
  void onInit(String label, List<ElementState> values);
  void onRead(String label, int index, ElementState value);
  void onWrite(String label, int index, ElementState value);
  void onComparison();
}
