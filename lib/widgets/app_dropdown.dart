import 'package:flutter/material.dart';

/// Compact Material 3 selector used throughout the app.
class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final borderRadius = BorderRadius.circular(14);
    DropdownMenuItem<T>? selected;
    for (final item in items) {
      if (item.value == value) {
        selected = item;
        break;
      }
    }

    return PopupMenuButton<T>(
      enabled: enabled && items.isNotEmpty,
      initialValue: value,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: 0.45),
      elevation: 12,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 420),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8)),
      ),
      itemBuilder: (context) => [
        for (final item in items)
          PopupMenuItem<T>(
            value: item.value,
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: item.value == value
                    ? scheme.primary.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(child: item.child),
                  if (item.value == value) ...[
                    const SizedBox(width: 10),
                    Icon(Icons.check_rounded, size: 18, color: scheme.primary),
                  ],
                ],
              ),
            ),
          ),
      ],
      child: InputDecorator(
        isEmpty: value == null,
        decoration: InputDecoration(
          labelText: label,
          enabled: enabled,
          filled: true,
          fillColor: scheme.surfaceContainerHighest,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: borderRadius,
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: borderRadius,
            borderSide: BorderSide.none,
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: borderRadius,
            borderSide: BorderSide.none,
          ),
        ),
        child: Row(
          children: [
            Expanded(child: selected?.child ?? const SizedBox.shrink()),
            const SizedBox(width: 10),
            Icon(
              Icons.expand_more_rounded,
              color: enabled
                  ? scheme.onSurfaceVariant
                  : scheme.onSurface.withValues(alpha: 0.38),
            ),
          ],
        ),
      ),
    );
  }
}
