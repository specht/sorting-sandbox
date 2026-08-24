import 'dart:math';

import 'package:flutter/material.dart';

class ArrayView extends StatelessWidget {
  const ArrayView({
    super.key,
    required this.values,
    required this.label,
    this.readIndex,
    this.writeIndex,
    this.emptyHint,
    this.baseColor,
    this.indexVariables = const {},
  });

  final List<int> values;
  final String label;
  final int? readIndex;
  final int? writeIndex;
  final String? emptyHint;
  final Color? baseColor;
  final Map<String, int> indexVariables;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Expanded(
                  child: values.isEmpty && emptyHint != null
                      ? Center(
                          child: Text(
                            emptyHint!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        )
                      : CustomPaint(
                          painter: _ArrayPainter(
                            values: values,
                            readIndex: readIndex,
                            writeIndex: writeIndex,
                            scheme: Theme.of(context).colorScheme,
                            baseColor: baseColor,
                          ),
                          child: const SizedBox.expand(),
                        ),
                ),
                if (indexVariables.isNotEmpty)
                  SizedBox(
                    height: 28,
                    child: CustomPaint(
                      painter: _VariablePointerPainter(
                        length: values.length,
                        variables: indexVariables,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _ArrayPainter extends CustomPainter {
  _ArrayPainter({
    required this.values,
    required this.readIndex,
    required this.writeIndex,
    required this.scheme,
    required this.baseColor,
  });

  final List<int> values;
  final int? readIndex;
  final int? writeIndex;
  final ColorScheme scheme;
  final Color? baseColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxValue = values.reduce(max);
    if (maxValue <= 0) return;

    final slot = size.width / values.length;
    final width = max(1.0, min(slot * .72, 8.0));
    final arrayColor = baseColor ?? scheme.primary;
    final lightColor = Color.lerp(arrayColor, Colors.white, 0.20)!;
    final darkColor = Color.lerp(arrayColor, Colors.black, 0.10)!;
    final arrayPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [darkColor, arrayColor, lightColor],
        stops: const [0, 0.58, 1],
      ).createShader(Offset.zero & size);

    for (var i = 0; i < values.length; i++) {
      if (values[i] <= 0) continue;
      final normalized = values[i] / maxValue;

      // Presentation-only scaling: a gentle concave curve gives a sorted
      // array the characteristic visual sweep of the original sandbox while
      // preserving the ordering of all values.
      final displayValue = pow(normalized, 0.68).toDouble();
      final h = max(1.0, displayValue * (size.height - 8));
      final x = i * slot + (slot - width) / 2;
      final rect = Rect.fromLTWH(x, size.height - h, width, h);
      final paint = i == writeIndex
          ? (Paint()..color = scheme.error)
          : i == readIndex
              ? (Paint()..color = Colors.orange)
              : arrayPaint;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ArrayPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.readIndex != readIndex ||
      oldDelegate.writeIndex != writeIndex ||
      oldDelegate.scheme != scheme ||
      oldDelegate.baseColor != baseColor;
}

class _VariablePointerPainter extends CustomPainter {
  _VariablePointerPainter({
    required this.length,
    required this.variables,
    required this.color,
  });

  final int length;
  final Map<String, int> variables;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (length <= 0 || variables.isEmpty) return;

    final byIndex = <int, List<String>>{};
    for (final entry in variables.entries) {
      if (entry.value < 0 || entry.value >= length) continue;
      byIndex.putIfAbsent(entry.value, () => []).add(entry.key);
    }

    final slot = size.width / length;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.fill;

    for (final entry in byIndex.entries) {
      final x = (entry.key + 0.5) * slot;
      final arrow = Path()
        ..moveTo(x, 0)
        ..lineTo(x - 4, 6)
        ..lineTo(x + 4, 6)
        ..close();
      canvas.drawPath(arrow, paint);
      canvas.drawLine(Offset(x, 5), Offset(x, 10), paint);

      final label = entry.value.join(', ');
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width);

      final left = (x - textPainter.width / 2).clamp(
        0.0,
        max(0.0, size.width - textPainter.width),
      ).toDouble();
      textPainter.paint(canvas, Offset(left, 11));
    }
  }

  @override
  bool shouldRepaint(covariant _VariablePointerPainter oldDelegate) =>
      oldDelegate.length != length ||
      oldDelegate.variables != variables ||
      oldDelegate.color != color;
}
