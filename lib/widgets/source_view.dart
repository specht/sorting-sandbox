import 'package:flutter/material.dart';

class SourceView extends StatelessWidget {
  const SourceView({super.key, required this.source, required this.line});

  // Bundle the classroom code font so CanvasKit renders the same on every
  // machine, independent of locally installed fonts.
  static const _monoFamily = '0xProto Nerd Font Mono';

  final String source;
  final int line;

  @override
  Widget build(BuildContext context) {
    final lines = source.split('\n');
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final number = index + 1;
          final selected = number == line;
          return Container(
            decoration: selected
                ? BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    border: Border(
                      left: BorderSide(color: scheme.primary, width: 3),
                    ),
                  )
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 34,
                  child: Text(
                    '$number',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontFamily: _monoFamily,
                      fontSize: 14.5,
                      color: scheme.outline,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    lines[index],
                    style: const TextStyle(
                      fontFamily: _monoFamily,
                      fontSize: 16.5,
                      height: 1.40,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
