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
  });

  final List<int> values;
  final String label;
  final int? readIndex;
  final int? writeIndex;
  final String? emptyHint;
  final Color? baseColor;

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
            child: values.isEmpty && emptyHint != null
                ? Center(child: Text(emptyHint!, style: Theme.of(context).textTheme.bodySmall))
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
    final maxValue = max(1, values.reduce(max));
    final minValue = values.reduce(min);
    final range = max(1, maxValue - minValue + 1);
    final slot = size.width / values.length;
    final width = max(1.0, min(slot * .72, 8.0));

    for (var i = 0; i < values.length; i++) {
      final normalized = (values[i] - minValue + 1) / range;
      final h = max(2.0, normalized * (size.height - 8));
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
