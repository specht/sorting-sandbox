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
    this.reservePointerGutter = true,
    this.indexVariables = const {},
  });

  final List<int> values;
  final String label;
  final int? readIndex;
  final int? writeIndex;
  final String? emptyHint;
  final Color? baseColor;
  final bool reservePointerGutter;
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
                            variableIndices: indexVariables.values.toSet(),
                          ),
                          child: const SizedBox.expand(),
                        ),
                ),
                if (reservePointerGutter || indexVariables.isNotEmpty)
                  SizedBox(
                    height: 46,
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
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
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
    required this.variableIndices,
  });

  final List<int> values;
  final int? readIndex;
  final int? writeIndex;
  final ColorScheme scheme;
  final Color? baseColor;
  final Set<int> variableIndices;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxValue = values.reduce(max);
    if (maxValue <= 0) return;

    final slot = size.width / values.length;
    final width = max(1.0, min(slot * .72, 8.0));
    final arrayColor = baseColor ?? scheme.primary;

    for (var i = 0; i < values.length; i++) {
      if (values[i] <= 0) continue;
      final normalized = values[i] / maxValue;

      // Presentation-only scaling: a gentle concave curve gives a sorted
      // array the characteristic visual sweep of the original sandbox while
      // preserving the ordering of all values.
      final displayValue = pow(normalized, 0.52).toDouble();
      final h = max(1.0, displayValue * (size.height - 8));
      final x = i * slot + (slot - width) / 2;
      final rect = Rect.fromLTWH(x, size.height - h, width, h);
      final isVariable = variableIndices.contains(i);
      final lightColor = Color.lerp(arrayColor, Colors.white, 0.26)!;
      final darkColor = Color.lerp(arrayColor, Colors.black, 0.16)!;
      final paint = i == writeIndex
          ? (Paint()..color = scheme.error)
          : i == readIndex
          ? (Paint()..color = Colors.orange)
          : (Paint()
              ..shader = LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [darkColor, arrayColor, lightColor],
                stops: const [0, 0.58, 1],
              ).createShader(rect));
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        paint,
      );

      // Keep index-variable emphasis deliberately tiny: a short cap at the
      // top of the bar connects the pointer label to the value without
      // changing the bar's apparent width or its gradient.
      if (isVariable && i != readIndex && i != writeIndex) {
        final capWidth = min(width * 0.65, 4.0);
        canvas.drawLine(
          Offset(rect.center.dx - capWidth / 2, rect.top + 1),
          Offset(rect.center.dx + capWidth / 2, rect.top + 1),
          Paint()
            ..color = scheme.onSurface.withValues(alpha: 0.55)
            ..strokeWidth = 1.25
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ArrayPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.readIndex != readIndex ||
      oldDelegate.writeIndex != writeIndex ||
      oldDelegate.scheme != scheme ||
      oldDelegate.baseColor != baseColor ||
      oldDelegate.variableIndices != variableIndices;
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
    final pointerPaint = Paint()
      ..color = color
      ..strokeWidth = 1.25
      ..style = PaintingStyle.fill;
    final connectorPaint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 1;

    final labels = <_PointerLabel>[];
    for (final entry in byIndex.entries) {
      final names = List<String>.from(entry.value)..sort();
      final textPainter = TextPainter(
        text: TextSpan(
          text: names.join(', '),
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width);
      labels.add(
        _PointerLabel(x: (entry.key + 0.5) * slot, textPainter: textPainter),
      );
    }
    labels.sort((a, b) => a.x.compareTo(b.x));

    // Put nearby labels on separate fixed lanes. This keeps names such as
    // left/middle/right readable even when their indices are close together.
    // The gutter itself has a fixed height, so lane changes never resize the
    // array visualization.
    const laneCount = 3;
    const laneGap = 4.0;
    const laneHeight = 11.0;
    final laneRight = List<double>.filled(laneCount, double.negativeInfinity);

    for (final label in labels) {
      final maxLeft = max(0.0, size.width - label.textPainter.width);
      final preferredLeft = (label.x - label.textPainter.width / 2)
          .clamp(0.0, maxLeft)
          .toDouble();

      var lane = 0;
      var foundLane = false;
      for (var candidate = 0; candidate < laneCount; candidate++) {
        if (preferredLeft >= laneRight[candidate] + laneGap) {
          lane = candidate;
          foundLane = true;
          break;
        }
      }
      if (!foundLane) {
        for (var candidate = 1; candidate < laneCount; candidate++) {
          if (laneRight[candidate] < laneRight[lane]) lane = candidate;
        }
      }

      var left = max(preferredLeft, laneRight[lane] + laneGap);
      left = left.clamp(0.0, maxLeft).toDouble();
      laneRight[lane] = left + label.textPainter.width;

      final arrow = Path()
        ..moveTo(label.x, 0)
        ..lineTo(label.x - 3.5, 5)
        ..lineTo(label.x + 3.5, 5)
        ..close();
      canvas.drawPath(arrow, pointerPaint);

      final textY = 10 + lane * laneHeight;
      final labelCenter = left + label.textPainter.width / 2;
      canvas.drawLine(Offset(label.x, 5), Offset(label.x, 8), connectorPaint);
      if ((labelCenter - label.x).abs() > 1) {
        canvas.drawLine(
          Offset(label.x, 8),
          Offset(labelCenter, textY - 1),
          connectorPaint,
        );
      }
      label.textPainter.paint(canvas, Offset(left, textY));
    }
  }

  @override
  bool shouldRepaint(covariant _VariablePointerPainter oldDelegate) =>
      oldDelegate.length != length ||
      oldDelegate.variables != variables ||
      oldDelegate.color != color;
}

class _PointerLabel {
  const _PointerLabel({required this.x, required this.textPainter});

  final double x;
  final TextPainter textPainter;
}
