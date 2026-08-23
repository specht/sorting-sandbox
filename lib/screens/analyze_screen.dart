import 'dart:async';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../color_utils.dart';
import '../input_factory.dart';
import '../models.dart';
import '../worker_client.dart';

enum Normalization { raw, n, nLogN, nSquared }

String _normalizationLabel(Normalization value) => switch (value) {
      Normalization.raw => 'operations',
      Normalization.n => 'operations / n',
      Normalization.nLogN => 'operations / (n log n)',
      Normalization.nSquared => 'operations / n²',
    };

class AnalyzeScreen extends StatefulWidget {
  const AnalyzeScreen({super.key, required this.catalog});
  final AlgorithmCatalog catalog;

  @override
  State<AnalyzeScreen> createState() => _AnalyzeScreenState();
}

class _AnalyzeScreenState extends State<AnalyzeScreen> {
  final Map<String, AnalysisData> _results = {};
  final List<AlgorithmWorker> _workers = [];
  InputShape _shape = InputShape.random;
  Normalization _normalization = Normalization.raw;
  bool _running = false;
  int _generation = 0;
  bool _catalogUpdatePending = false;
  AlgorithmCatalog? _resultsCatalog;

  static const _sizes = [32, 64, 128, 256, 512];

  @override
  void didUpdateWidget(covariant AnalyzeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.catalog.buildId == widget.catalog.buildId) return;
    if (_running) {
      _catalogUpdatePending = true;
    } else {
      _results.clear();
      _resultsCatalog = null;
      _catalogUpdatePending = false;
    }
  }

  @override
  void dispose() {
    _stop(updateState: false);
    super.dispose();
  }

  Future<void> _run() async {
    if (_running || widget.catalog.algorithms.isEmpty) return;
    _stop(updateState: false);
    final generation = ++_generation;
    final catalog = widget.catalog;
    final cases = [
      for (final n in _sizes) makeInput(n, _shape, seed: 1000 + n),
    ];
    setState(() {
      _running = true;
      _results.clear();
      _resultsCatalog = catalog;
    });

    for (final algorithm in catalog.algorithms) {
      if (!_running || generation != _generation) break;
      final worker = AlgorithmWorker(workerPath: catalog.workerPath);
      _workers.add(worker);
      try {
        final message = await worker.request(
          {
            'type': 'analyze',
            'algorithmId': algorithm.id,
            'cases': cases,
          },
          timeout: const Duration(seconds: 6),
        );
        if (!mounted || generation != _generation) return;
        setState(() {
          _results[algorithm.id] = AnalysisData.fromJson(message);
        });
      } on WorkerTimeout {
        if (!mounted || generation != _generation) return;
        setState(() {
          _results[algorithm.id] = AnalysisData(
            correct: false,
            stable: null,
            stabilityNote: null,
            failingCase: null,
            benchmarks: const [],
            timeout: true,
          );
        });
      } catch (error) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _results[algorithm.id] = AnalysisData(
            correct: false,
            stable: null,
            stabilityNote: null,
            failingCase: null,
            benchmarks: const [],
            error: error.toString(),
          );
        });
      } finally {
        worker.terminate();
      }
    }

    _workers.clear();
    if (mounted && generation == _generation) {
      setState(() {
        _running = false;
        if (_catalogUpdatePending) {
          _results.clear();
          _resultsCatalog = null;
          _catalogUpdatePending = false;
        }
      });
    }
  }

  void _stop({bool updateState = true}) {
    _generation++;
    for (final worker in _workers) {
      worker.terminate();
    }
    _workers.clear();
    if (updateState && mounted) {
      setState(() {
        _running = false;
        if (_catalogUpdatePending) {
          _results.clear();
          _resultsCatalog = null;
          _catalogUpdatePending = false;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _toolbar(context),
          if (_catalogUpdatePending) ...[
            const SizedBox(height: 8),
            const Card(
              child: ListTile(
                leading: Icon(Icons.sync),
                title: Text('New algorithm versions are ready'),
                subtitle: Text('This analysis finishes on the previous build; run Analyze all again afterwards.'),
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (widget.catalog.diagnostics.isNotEmpty) _diagnostics(context),
          if (widget.catalog.diagnostics.isNotEmpty) const SizedBox(height: 8),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      _running ? 'Analyzing…' : 'Run the class-wide correctness, stability and complexity analysis.',
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth > 950) {
                        return Row(
                          children: [
                            Expanded(flex: 5, child: _chart(context)),
                            const SizedBox(width: 8),
                            Expanded(flex: 4, child: _table(context)),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          Expanded(child: _chart(context)),
                          const SizedBox(height: 8),
                          Expanded(child: _table(context)),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<InputShape>(
                key: ValueKey(_shape),
                initialValue: _shape,
                decoration: const InputDecoration(labelText: 'Input shape', border: OutlineInputBorder(), isDense: true),
                items: [for (final s in InputShape.values) DropdownMenuItem(value: s, child: Text(inputShapeLabel(s)))],
                onChanged: _running ? null : (v) => setState(() => _shape = v ?? _shape),
              ),
            ),
            SizedBox(
              width: 210,
              child: DropdownButtonFormField<Normalization>(
                key: ValueKey(_normalization),
                initialValue: _normalization,
                decoration: const InputDecoration(labelText: 'Graph', border: OutlineInputBorder(), isDense: true),
                items: [for (final n in Normalization.values) DropdownMenuItem(value: n, child: Text(_normalizationLabel(n)))],
                onChanged: (v) => setState(() => _normalization = v ?? _normalization),
              ),
            ),
            FilledButton.icon(
              onPressed: _running ? () => _stop() : _run,
              icon: Icon(_running ? Icons.stop : Icons.query_stats),
              label: Text(_running ? 'Stop' : 'Analyze all'),
            ),
            const Text('Sandbox score = reads + writes + comparisons'),
          ],
        ),
      ),
    );
  }

  Widget _diagnostics(BuildContext context) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text('${widget.catalog.diagnostics.length} skipped file(s) / build diagnostic(s)'),
      children: [
        for (final diagnostic in widget.catalog.diagnostics)
          ListTile(
            dense: true,
            title: Text(diagnostic.path.isEmpty ? 'Build' : diagnostic.path),
            subtitle: Text(diagnostic.message),
          ),
      ],
    );
  }

  Widget _chart(BuildContext context) {
    final resultCatalog = _resultsCatalog ?? widget.catalog;
    final valid = resultCatalog.algorithms.where((a) {
      final result = _results[a.id];
      return result != null && result.correct && result.benchmarks.isNotEmpty;
    }).toList();

    if (valid.isEmpty) {
      return const Card(child: Center(child: Text('No correct benchmark result yet.')));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_normalizationLabel(_normalization), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: LineChart(
                LineChartData(
                  minX: _sizes.first.toDouble(),
                  maxX: _sizes.last.toDouble(),
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 24,
                        getTitlesWidget: (value, meta) => Text('${value.toInt()}', style: const TextStyle(fontSize: 10)),
                      ),
                    ),
                  ),
                  lineBarsData: [
                    for (final algorithm in valid)
                      LineChartBarData(
                        isCurved: false,
                        barWidth: 2,
                        dotData: const FlDotData(show: true),
                        color: parseHexColor(algorithm.color),
                        spots: [
                          for (final point in _results[algorithm.id]!.benchmarks)
                            FlSpot(point.n.toDouble(), _normalized(point).toDouble()),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                for (final algorithm in valid)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, size: 10, color: parseHexColor(algorithm.color)),
                      const SizedBox(width: 4),
                      Text('${algorithm.name} · ${algorithm.author}', style: const TextStyle(fontSize: 11)),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  double _normalized(BenchmarkPoint point) {
    final score = point.metrics.score.toDouble();
    final n = max(1, point.n).toDouble();
    return switch (_normalization) {
      Normalization.raw => score,
      Normalization.n => score / n,
      Normalization.nLogN => score / max(1.0, n * log(n)),
      Normalization.nSquared => score / (n * n),
    };
  }

  Widget _table(BuildContext context) {
    return Card(
      child: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          for (final algorithm in (_resultsCatalog ?? widget.catalog).algorithms)
            _resultTile(context, algorithm),
        ],
      ),
    );
  }

  Widget _resultTile(BuildContext context, AlgorithmMeta algorithm) {
    final result = _results[algorithm.id];
    if (result == null) {
      return ListTile(
        dense: true,
        leading: Icon(Icons.circle, size: 12, color: parseHexColor(algorithm.color)),
        title: Text('${algorithm.name} · ${algorithm.author}'),
        trailing: _running ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : null,
      );
    }

    final latest = result.benchmarks.isEmpty ? null : result.benchmarks.last.metrics;
    final status = result.timeout
        ? 'TIMEOUT'
        : result.error != null
            ? 'ERROR'
            : !result.correct
                ? 'INCORRECT'
                : result.stable == true
                    ? 'correct · stable (tested)'
                    : 'correct · unstable';

    return ListTile(
      dense: true,
      leading: Icon(Icons.circle, size: 12, color: parseHexColor(algorithm.color)),
      title: Text('${algorithm.name} · ${algorithm.author}'),
      subtitle: Text(
        latest == null
            ? '$status${result.failingCase == null ? '' : ' · case ${result.failingCase}'}'
            : '$status · n=${_sizes.last}: R ${latest.reads}, W ${latest.writes}, C ${latest.comparisons}',
      ),
      trailing: latest == null ? null : Text('${latest.score}'),
    );
  }
}
