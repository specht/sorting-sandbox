import 'dart:async';

import 'package:flutter/material.dart';

import '../color_utils.dart';
import '../format_utils.dart';
import '../input_factory.dart';
import '../models.dart';
import '../worker_client.dart';
import '../widgets/app_dropdown.dart';
import '../widgets/array_view.dart';

class RaceScreen extends StatefulWidget {
  const RaceScreen({super.key, required this.catalog});
  final AlgorithmCatalog catalog;

  @override
  State<RaceScreen> createState() => _RaceScreenState();
}

class _RaceLane {
  _RaceLane(this.algorithm, List<int> initial)
    : numbers = List<int>.from(initial),
      scratch = List<int>.filled(initial.length, 0),
      expected = (List<int>.from(initial)..sort());

  final AlgorithmMeta algorithm;
  final List<int> expected;
  List<int> numbers;
  List<int> scratch;
  MetricsData metrics = const MetricsData();
  AlgorithmWorker? worker;
  StreamSubscription<Map<String, dynamic>>? subscription;
  Timer? watchdog;
  bool done = false;
  bool completed = false;
  bool? correct;
  String? error;

  bool matchesExpected(List<int> values) {
    if (values.length != expected.length) return false;
    for (var i = 0; i < values.length; i++) {
      if (values[i] != expected[i]) return false;
    }
    return true;
  }
}

class _RaceScreenState extends State<RaceScreen> {
  final Set<String> _selected = {};
  final List<_RaceLane> _lanes = [];
  bool _running = false;
  bool _controlsCollapsed = false;
  int _n = 48;
  int _speed = 12;
  InputShape _shape = InputShape.random;
  int _seed = 100;
  List<int> _previewInput = const [];
  bool _catalogUpdatePending = false;

  static const _sizes = [
    8,
    12,
    16,
    24,
    32,
    48,
    64,
    96,
    128,
    192,
    256,
    384,
    512,
    768,
    1024,
  ];
  static const _budgets = [
    1,
    1,
    1,
    2,
    2,
    3,
    3,
    4,
    5,
    7,
    10,
    14,
    20,
    30,
    45,
    67,
    100,
    178,
    316,
    562,
    1000,
  ];
  static const _delays = [
    220,
    202,
    185,
    168,
    150,
    135,
    120,
    105,
    90,
    80,
    70,
    60,
    50,
    42,
    35,
    28,
    20,
    15,
    10,
    5,
    0,
  ];

  @override
  void initState() {
    super.initState();
    for (final algorithm in widget.catalog.algorithms.take(2)) {
      _selected.add(algorithm.id);
    }
    _refreshPreview(newInput: true);
  }

  @override
  void didUpdateWidget(covariant RaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.catalog.buildId == widget.catalog.buildId) return;
    if (_running) {
      _catalogUpdatePending = true;
    } else {
      _syncSelection();
      _refreshPreview();
      _catalogUpdatePending = false;
    }
  }

  @override
  void dispose() {
    _stop(updateState: false);
    super.dispose();
  }

  void _syncSelection() {
    final available = widget.catalog.algorithms.map((a) => a.id).toSet();
    _selected.removeWhere((id) => !available.contains(id));
    if (_selected.length < 2) {
      for (final algorithm in widget.catalog.algorithms) {
        if (_selected.length >= 2) break;
        _selected.add(algorithm.id);
      }
    }
  }

  void _refreshPreview({bool newInput = false}) {
    if (newInput || _previewInput.length != _n) {
      _previewInput = makeInput(_n, _shape, seed: ++_seed);
    }
    final algorithms = widget.catalog.algorithms
        .where((algorithm) => _selected.contains(algorithm.id))
        .toList();
    _lanes
      ..clear()
      ..addAll(
        algorithms.map((algorithm) => _RaceLane(algorithm, _previewInput)),
      );
  }

  void _toggle(AlgorithmMeta algorithm, bool value) {
    if (_running) return;
    setState(() {
      if (value) {
        if (_selected.length < 4) _selected.add(algorithm.id);
      } else {
        _selected.remove(algorithm.id);
      }
      _refreshPreview();
    });
  }

  Future<void> _start() async {
    if (_running || _selected.length < 2) return;
    _stop(updateState: false);
    if (_previewInput.length != _n) _refreshPreview(newInput: true);
    final input = List<int>.from(_previewInput);
    final algorithms = widget.catalog.algorithms
        .where((a) => _selected.contains(a.id))
        .toList();
    _lanes
      ..clear()
      ..addAll(algorithms.map((a) => _RaceLane(a, input)));
    setState(() {
      _running = true;
      _controlsCollapsed = true;
    });

    for (final lane in _lanes) {
      _startLane(lane, input);
    }
  }

  void _startLane(_RaceLane lane, List<int> input) {
    final worker = AlgorithmWorker(workerPath: widget.catalog.workerPath);
    lane.worker = worker;
    final requestId =
        'race-${lane.algorithm.id}-${DateTime.now().microsecondsSinceEpoch}';
    lane.subscription = worker.messages.listen((message) {
      final type = message['type'];
      final eventRequestId = message['requestId']?.toString();
      if (eventRequestId != null && eventRequestId != requestId) return;
      if (eventRequestId == null && type != 'error') return;
      if (type == 'frame') {
        final frame = VisualFrame.fromJson(message);
        if (!mounted) return;
        setState(() {
          lane.numbers = frame.numbers;
          lane.scratch = frame.scratch;
          lane.metrics = frame.metrics;
          lane.done = frame.done;
          if (frame.done) {
            lane.completed = true;
            lane.correct = lane.matchesExpected(frame.numbers);
          }
        });
        if (frame.done) {
          _finishLane(lane);
        } else {
          Future<void>.delayed(Duration(milliseconds: _delays[_speed]), () {
            if (!_running || lane.done || lane.worker == null) return;
            lane.worker!.send({
              'type': 'advance',
              'requestId': requestId,
              'budget': _budgets[_speed],
            });
          });
        }
      } else if (type == 'error') {
        lane.error = message['message']?.toString() ?? 'Worker error';
        _finishLane(lane);
      }
    });
    lane.watchdog = worker.watchdog(
      timeout: const Duration(seconds: 2),
      onTimeout: () {
        lane.error = 'timeout';
        _finishLane(lane);
      },
    );
    worker.send({
      'type': 'visualStart',
      'requestId': requestId,
      'algorithmId': lane.algorithm.id,
      'values': input,
    });
  }

  void _finishLane(_RaceLane lane) {
    lane.done = true;
    lane.watchdog?.cancel();
    lane.worker?.terminate();
    lane.worker = null;
    if (mounted) {
      setState(() {
        if (_lanes.every((l) => l.done)) {
          _running = false;
          if (_catalogUpdatePending) {
            _syncSelection();
            _catalogUpdatePending = false;
          }
        }
      });
    }
  }

  void _stop({bool updateState = true}) {
    for (final lane in _lanes) {
      lane.watchdog?.cancel();
      lane.subscription?.cancel();
      lane.worker?.terminate();
      lane.worker = null;
      lane.done = true;
    }
    if (updateState && mounted) {
      setState(() {
        _running = false;
        if (_catalogUpdatePending) {
          _syncSelection();
          _catalogUpdatePending = false;
        }
      });
    }
  }

  Widget _compactRaceControls(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: Text(
            '${inputShapeLabel(_shape)} · n=$_n',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        const SizedBox(width: 6),
        const Icon(Icons.speed, size: 18),
        Expanded(
          flex: 3,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: _speed.toDouble(),
              min: 0,
              max: 20,
              divisions: 20,
              label: '${_speed * 5}%',
              onChanged: (value) => setState(() => _speed = value.round()),
            ),
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            '${_speed * 5}%',
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filled(
          onPressed: _running
              ? () => _stop()
              : () => setState(() => _controlsCollapsed = false),
          tooltip: _running ? 'Stop race' : 'Race setup',
          icon: Icon(_running ? Icons.stop : Icons.tune),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.catalog.algorithms.length < 2) {
      return const Center(
        child: Text('Race needs at least two valid algorithms.'),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Card(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: _controlsCollapsed
                    ? _compactRaceControls(context)
                    : Column(
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Choose 2–4 algorithms',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(height: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 124),
                            child: SingleChildScrollView(
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final algorithm
                                      in widget.catalog.algorithms)
                                    FilterChip(
                                      label: Text(
                                        '${algorithm.name} · ${algorithm.author}',
                                      ),
                                      selected: _selected.contains(
                                        algorithm.id,
                                      ),
                                      onSelected: _running
                                          ? null
                                          : (value) =>
                                                _toggle(algorithm, value),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [const Text('Size'), Text('n=$_n')],
                          ),
                          Slider(
                            value: _sizes.indexOf(_n).toDouble(),
                            min: 0,
                            max: (_sizes.length - 1).toDouble(),
                            divisions: _sizes.length - 1,
                            label: 'n=$_n',
                            onChanged: _running
                                ? null
                                : (v) => setState(() {
                                    _n = _sizes[v.round()];
                                    _refreshPreview(newInput: true);
                                  }),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Speed'),
                              Text('${_speed * 5}%'),
                            ],
                          ),
                          Slider(
                            value: _speed.toDouble(),
                            min: 0,
                            max: 20,
                            divisions: 20,
                            label: '${_speed * 5}%',
                            onChanged: (v) =>
                                setState(() => _speed = v.round()),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: AppDropdown<InputShape>(
                                  label: 'Input',
                                  value: _shape,
                                  enabled: !_running,
                                  items: [
                                    for (final shape in InputShape.values)
                                      DropdownMenuItem(
                                        value: shape,
                                        child: Text(inputShapeLabel(shape)),
                                      ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null) return;
                                    setState(() {
                                      _shape = value;
                                      _refreshPreview(newInput: true);
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 2,
                                child: FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size.fromHeight(52),
                                  ),
                                  onPressed: _selected.length >= 2 ? _start : null,
                                  icon: const Icon(Icons.sports_score),
                                  label: const Text('Race'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _lanes.isEmpty
                ? const Center(
                    child: Text('Every lane receives exactly the same input.'),
                  )
                : GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _lanes.length <= 2 ? 2 : 2,
                      childAspectRatio: 1.1,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: _lanes.length,
                    itemBuilder: (context, index) {
                      final lane = _lanes[index];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Flexible(
                                    child: Text(
                                      '${lane.algorithm.name} · ${lane.algorithm.author}',
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  if (lane.completed &&
                                      lane.correct != null) ...[
                                    const SizedBox(width: 5),
                                    Tooltip(
                                      message: lane.correct!
                                          ? 'Sorted correctly'
                                          : 'Finished, but result is incorrect',
                                      child: Icon(
                                        lane.correct!
                                            ? Icons.check_circle_rounded
                                            : Icons.error_rounded,
                                        size: 17,
                                        color: lane.correct!
                                            ? const Color(0xFF6EE7B7)
                                            : Theme.of(
                                                context,
                                              ).colorScheme.error,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              if (lane.error != null)
                                Text(
                                  lane.error!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              const SizedBox(height: 4),
                              Expanded(
                                child: ArrayView(
                                  values: lane.numbers,
                                  label: 'List',
                                  reservePointerGutter: false,
                                  baseColor: parseHexColor(
                                    lane.algorithm.color,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Expanded(
                                child: ArrayView(
                                  values: lane.scratch,
                                  label: 'Scratch',
                                  reservePointerGutter: false,
                                  baseColor: Colors.grey,
                                ),
                              ),
                              Text(
                                'R ${compactCount(lane.metrics.reads)}  '
                                'W ${compactCount(lane.metrics.writes)}  '
                                'C ${compactCount(lane.metrics.comparisons)}',
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
