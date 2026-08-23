import 'package:flutter/material.dart';

import '../color_utils.dart';
import '../models.dart';

class AlgorithmPicker extends StatelessWidget {
  const AlgorithmPicker({
    super.key,
    required this.algorithms,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final List<AlgorithmMeta> algorithms;
  final AlgorithmMeta? value;
  final ValueChanged<AlgorithmMeta?> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final selectedId = value != null && algorithms.any((a) => a.id == value!.id)
        ? value!.id
        : null;
    return DropdownButtonFormField<String>(
      key: ValueKey(selectedId),
      initialValue: selectedId,
      decoration: const InputDecoration(
        labelText: 'Algorithm',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final algorithm in algorithms)
          DropdownMenuItem(
            value: algorithm.id,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 14, color: parseHexColor(algorithm.color)),
                const SizedBox(width: 8),
                Flexible(child: Text('${algorithm.name} (${algorithm.author})')),
              ],
            ),
          ),
      ],
      onChanged: enabled
          ? (id) => onChanged(
                id == null ? null : algorithms.firstWhere((a) => a.id == id),
              )
          : null,
    );
  }
}
