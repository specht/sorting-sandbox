import 'dart:async';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../color_utils.dart';
import '../format_utils.dart';
import '../input_factory.dart';
import '../models.dart';
import '../worker_client.dart';
import '../widgets/app_dropdown.dart';

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
  bool _logX = false;
  bool _logY = false;
  bool _running = false;
  int _generation = 0;
  bool _catalogUpdatePending = false;
  AlgorithmCatalog? _resultsCatalog;

  static const _sizes = [32, 64, 128, 256, 512, 1024, 2048];

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
        final message = await worker.request({
          'type': 'analyze',
          'algorithmId': algorithm.id,
          'cases': cases,
        }, timeout: const Duration(seconds: 6));
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
                subtitle: Text(
                  'This analysis finishes on the previous build; run Analyze all again afterwards.',
                ),
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
                      _running
                          ? 'Analyzing…'
                          : 'Run the class-wide correctness, stability and complexity analysis.',
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: AppDropdown<InputShape>(
                    label: 'Input shape',
                    value: _shape,
                    enabled: !_running,
                    items: [
                      for (final shape in InputShape.values)
                        DropdownMenuItem(
                          value: shape,
                          child: Text(inputShapeLabel(shape)),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _shape = value ?? _shape),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Logarithmic x-axis',
                  child: FilterChip(
                    visualDensity: VisualDensity.compact,
                    selected: _logX,
                    label: const Text('Log x'),
                    onSelected: (value) => setState(() => _logX = value),
                  ),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Logarithmic y-axis',
                  child: FilterChip(
                    visualDensity: VisualDensity.compact,
                    selected: _logY,
                    label: const Text('Log y'),
                    onSelected: (value) => setState(() => _logY = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Score = reads + writes + comparisons',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _running ? () => _stop() : _run,
                  icon: Icon(_running ? Icons.stop : Icons.query_stats),
                  label: Text(_running ? 'Stop' : 'Analyze all'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _diagnostics(BuildContext context) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(
        '${widget.catalog.diagnostics.length} skipped file(s) / build diagnostic(s)',
      ),
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
    final scheme = Theme.of(context).colorScheme;
    final resultCatalog = _resultsCatalog ?? widget.catalog;
    final valid =
        resultCatalog.algorithms.where((algorithm) {
          final result = _results[algorithm.id];
          return result != null &&
              result.correct &&
              result.benchmarks.isNotEmpty;
        }).toList()..sort(
          (a, b) => _aggregateScore(
            _results[a.id]!,
          ).compareTo(_aggregateScore(_results[b.id]!)),
        );

    if (valid.isEmpty) {
      return const Card(
        child: Center(child: Text('No correct benchmark result yet.')),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                _chartTitle(),
                key: ValueKey((_logX, _logY)),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LineChart(
                LineChartData(
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => scheme.surfaceContainerLowest,
                      tooltipBorder: BorderSide(color: scheme.outlineVariant),
                      tooltipBorderRadius: BorderRadius.circular(10),
                      tooltipPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      tooltipMargin: 10,
                      maxContentWidth: 88,
                      fitInsideHorizontally: true,
                      fitInsideVertically: true,
                      getTooltipItems: (spots) => [
                        for (final spot in spots)
                          LineTooltipItem(
                            _short(
                              _results[valid[spot.barIndex].id]!
                                  .benchmarks[spot.spotIndex]
                                  .metrics
                                  .score,
                            ),
                            TextStyle(
                              color: Color.lerp(
                                parseHexColor(valid[spot.barIndex].color),
                                scheme.onSurface,
                                0.50,
                              ),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  ),
                  minX: _plotX(_sizes.first),
                  maxX: _plotX(_sizes.last),
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        maxIncluded: false,
                        reservedSize: 52,
                        getTitlesWidget: (value, meta) => Text(
                          _yAxisLabel(value),
                          style: const TextStyle(fontSize: 10.5),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        maxIncluded: false,
                        reservedSize: 28,
                        getTitlesWidget: (value, meta) => Text(
                          _xAxisLabel(value),
                          style: const TextStyle(fontSize: 11),
                        ),
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
                          for (final point
                              in _results[algorithm.id]!.benchmarks)
                            FlSpot(
                              _plotX(point.n),
                              _plotY(point.metrics.score),
                            ),
                        ],
                      ),
                  ],
                ),
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
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
                      Icon(
                        Icons.circle,
                        size: 10,
                        color: parseHexColor(algorithm.color),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${algorithm.name} · ${algorithm.author}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _chartTitle() {
    if (_logX && _logY) return 'Sandbox score · logarithmic x/y';
    if (_logX) return 'Sandbox score · logarithmic x';
    if (_logY) return 'Sandbox score · logarithmic y';
    return 'Sandbox score';
  }

  double _plotX(int n) => _logX ? log(max(1, n)) / ln10 : n.toDouble();

  double _plotY(int score) =>
      _logY ? log(max(1, score)) / ln10 : score.toDouble();

  String _xAxisLabel(double value) {
    final n = _logX ? pow(10, value).round() : value.round();
    return _short(n);
  }

  String _yAxisLabel(double value) {
    final score = _logY ? pow(10, value).round() : value.round();
    return _short(score);
  }

  int _aggregateScore(AnalysisData result) =>
      result.benchmarks.fold(0, (sum, point) => sum + point.metrics.score);

  List<AlgorithmMeta> _orderedAlgorithms() {
    final algorithms = List<AlgorithmMeta>.from(
      (_resultsCatalog ?? widget.catalog).algorithms,
    );
    algorithms.sort((a, b) {
      final ar = _results[a.id];
      final br = _results[b.id];
      final aValid = ar != null && ar.correct && ar.benchmarks.isNotEmpty;
      final bValid = br != null && br.correct && br.benchmarks.isNotEmpty;
      if (aValid != bValid) return aValid ? -1 : 1;
      if (aValid && bValid) {
        return _aggregateScore(ar).compareTo(_aggregateScore(br));
      }
      return '${a.author}/${a.name}'.compareTo('${b.author}/${b.name}');
    });
    return algorithms;
  }

  Widget _table(BuildContext context) {
    final algorithms = _orderedAlgorithms();
    final ranks = <String, int>{};
    var nextRank = 1;
    for (final algorithm in algorithms) {
      final result = _results[algorithm.id];
      if (result != null && result.correct && result.benchmarks.isNotEmpty) {
        ranks[algorithm.id] = nextRank++;
      }
    }

    return Card(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        itemCount: algorithms.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final algorithm = algorithms[index];
          return _resultTile(context, algorithm, rank: ranks[algorithm.id]);
        },
      ),
    );
  }

  Widget _resultTile(
    BuildContext context,
    AlgorithmMeta algorithm, {
    required int? rank,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final algorithmColor = parseHexColor(algorithm.color);
    final result = _results[algorithm.id];
    if (result == null) {
      return ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        leading: SizedBox(
          width: 32,
          child: Icon(
            Icons.circle,
            size: 12,
            color: parseHexColor(algorithm.color),
          ),
        ),
        title: Text('${algorithm.name} · ${algorithm.author}'),
        trailing: _running
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      );
    }

    final latest = result.benchmarks.isEmpty
        ? null
        : result.benchmarks.last.metrics;
    final aggregate = result.benchmarks.isEmpty
        ? null
        : _aggregateScore(result);
    final status = result.timeout
        ? 'TIMEOUT'
        : result.error != null
        ? 'ERROR'
        : !result.correct
        ? 'INCORRECT'
        : result.stable == true
        ? 'correct · stable (tested)'
        : 'correct · unstable';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: rank == null
                ? Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Icon(
                      Icons.circle,
                      size: 12,
                      color: parseHexColor(algorithm.color),
                    ),
                  )
                : Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: algorithmColor.withValues(alpha: 0.22),
                      border: Border.all(
                        color: algorithmColor.withValues(alpha: 0.58),
                      ),
                    ),
                    child: Text(
                      '$rank',
                      style: TextStyle(
                        color: Color.lerp(
                          algorithmColor,
                          scheme.onSurface,
                          0.62,
                        ),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${algorithm.name} · ${algorithm.author}',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (latest != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'At n=${_sizes.last}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 2,
                    children: [
                      Text(
                        '${_short(latest.reads)} reads',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        '${_short(latest.writes)} writes',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        '${_short(latest.comparisons)} comparisons',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ] else if (result.failingCase != null) ...[
                  const SizedBox(height: 4),
                  Text('Failing case: ${result.failingCase}'),
                ],
              ],
            ),
          ),
          if (aggregate != null) ...[
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _short(aggregate),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'aggregate score',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _short(int value) => compactCount(value);
}
