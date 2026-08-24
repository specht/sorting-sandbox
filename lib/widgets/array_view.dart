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

    for (var i = 0; i < values.length; i++) {
      if (values[i] <= 0) continue;
      final normalized = values[i] / maxValue;
      final h = max(1.0, normalized * (size.height - 8));
      final x = i * slot + (slot - width) / 2;
      final rect = Rect.fromLTWH(x, size.height - h, width, h);
      final color = i == writeIndex
          ? scheme.error
          : i == readIndex
              ? Colors.orange
              : baseColor == null
                  ? Color.lerp(scheme.primary, scheme.tertiary, normalized)!
                  : Color.lerp(
                      baseColor!.withValues(alpha: 0.48),
                      baseColor!,
                      normalized,
                    )!;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()..color = color,
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
