import 'dart:async';

import 'package:flutter/material.dart';

import '../color_utils.dart';
import '../format_utils.dart';
import '../input_factory.dart';
import '../models.dart';
import '../worker_client.dart';
import '../widgets/algorithm_picker.dart';
import '../widgets/app_dropdown.dart';
import '../widgets/array_view.dart';
import '../widgets/source_view.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key, required this.catalog});

  final AlgorithmCatalog catalog;

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  AlgorithmMeta? _algorithm;
  AlgorithmWorker? _worker;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _watchdog;
  List<int> _input = const [];
  List<int> _numbers = const [];
  List<int> _scratch = const [];
  MetricsData _metrics = const MetricsData();
  MarkerData _read = const MarkerData();
  MarkerData _write = const MarkerData();
  Map<String, dynamic> _locals = const {};
  int _line = 0;
  int _n = 48;
  int _speed = 2;
  InputShape _shape = InputShape.random;
  bool _running = false;
  bool _paused = false;
  String? _requestId;
  bool _atCheckpoint = false;
  String? _error;
  int _seed = 42;
  bool _catalogUpdatePending = false;
  bool _showMemoryAccess = false;

  // Geometric-ish steps keep small teaching examples easy to select while
  // still allowing genuinely large inputs for fast algorithms.
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
    1536,
    2048,
    3072,
    4096,
  ];
  static const _budgets = [1, 2, 5, 20, 100, 1000];
  static const _delays = [220, 150, 90, 50, 20, 0];

  @override
  void initState() {
    super.initState();
    _algorithm = widget.catalog.algorithms.isEmpty
        ? null
        : widget.catalog.algorithms.first;
    _resetInput();
  }

  @override
  void didUpdateWidget(covariant ExploreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.catalog.buildId == widget.catalog.buildId) return;
    if (_running) {
      _catalogUpdatePending = true;
    } else {
      _algorithm = _mappedAlgorithm();
      _catalogUpdatePending = false;
    }
  }

  @override
  void dispose() {
    _stop(updateState: false);
    super.dispose();
  }

  AlgorithmMeta? _mappedAlgorithm() {
    final algorithms = widget.catalog.algorithms;
    if (algorithms.isEmpty) return null;
    final currentId = _algorithm?.id;
    if (currentId != null) {
      for (final algorithm in algorithms) {
        if (algorithm.id == currentId) return algorithm;
      }
    }
    return algorithms.first;
  }

  void _restoreInputState() {
    _numbers = List<int>.from(_input);
    _scratch = List<int>.filled(_input.length, 0);
    _metrics = const MetricsData();
    _read = const MarkerData();
    _write = const MarkerData();
    _locals = const {};
    _line = 0;
    _error = null;
  }

  void _restoreInput() => setState(_restoreInputState);

  void _resetInput() {
    _seed++;
    _input = makeInput(_n, _shape, seed: _seed);
    _restoreInput();
  }

  Future<void> _start({bool paused = false}) async {
    final algorithm = _algorithm;
    if (algorithm == null || _running) return;
    _stop();

    final worker = AlgorithmWorker(workerPath: widget.catalog.workerPath);
    _worker = worker;
    final requestId = 'visual-${DateTime.now().microsecondsSinceEpoch}';
    _requestId = requestId;
    _subscription = worker.messages.listen((message) {
      final type = message['type'];
      final eventRequestId = message['requestId']?.toString();
      if (eventRequestId != null && eventRequestId != requestId) return;
      if (eventRequestId == null && type != 'error') return;
      if (type == 'frame') {
        final frame = VisualFrame.fromJson(message);
        if (!mounted) return;
        setState(() {
          _numbers = frame.numbers;
          _scratch = frame.scratch;
          _metrics = frame.metrics;
          _read = frame.read;
          _write = frame.write;
          _locals = frame.locals;
          _line = frame.line;
          _atCheckpoint = true;
        });
        if (frame.done) {
          _finish();
        } else if (_paused) {
          _watchdog?.cancel();
          _watchdog = null;
        } else {
          _scheduleAdvance(requestId);
        }
      } else if (type == 'complete') {
        _finish();
      } else if (type == 'error') {
        _fail(message['message']?.toString() ?? 'Algorithm worker error');
      }
    });

    setState(() {
      _running = true;
      _paused = paused;
      _atCheckpoint = false;
      _error = null;
    });

    worker.send({
      'type': 'visualStart',
      'requestId': requestId,
      'algorithmId': algorithm.id,
      'values': _numbers,
    });

    _armWatchdog();
  }

  void _armWatchdog() {
    if (!_running || _worker == null || _watchdog != null) return;
    _watchdog = _worker!.watchdog(
      timeout: const Duration(seconds: 2),
      onTimeout: () =>
          _fail('No checkpoint reached. The algorithm was stopped.'),
    );
  }

  void _scheduleAdvance(String requestId) {
    final delay = Duration(milliseconds: _delays[_speed]);
    Future<void>.delayed(delay, () {
      if (!_running || _paused || _worker == null) return;
      _sendAdvance(_budgets[_speed], requestId: requestId);
    });
  }

  void _sendAdvance(int budget, {String? requestId}) {
    final worker = _worker;
    final id = requestId ?? _requestId;
    if (!_running || worker == null || id == null) return;
    _atCheckpoint = false;
    _armWatchdog();
    worker.send({'type': 'advance', 'requestId': id, 'budget': budget});
  }

  void _togglePause() {
    if (!_running) {
      _start();
      return;
    }
    setState(() => _paused = !_paused);
    if (_paused) {
      if (_atCheckpoint) {
        _watchdog?.cancel();
        _watchdog = null;
      }
    } else {
      _sendAdvance(_budgets[_speed]);
    }
  }

  void _step() {
    if (!_running) {
      _start(paused: true);
      return;
    }
    if (!_paused || !_atCheckpoint) return;
    _sendAdvance(1);
  }

  void _finish() {
    if (!mounted) return;
    setState(() {
      _running = false;
      _paused = false;
      _requestId = null;
      _atCheckpoint = false;
      _read = const MarkerData();
      _write = const MarkerData();
      if (_catalogUpdatePending) {
        _algorithm = _mappedAlgorithm();
        _catalogUpdatePending = false;
      }
    });
    _watchdog?.cancel();
    _worker?.terminate();
    _worker = null;
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _running = false;
      _paused = false;
      _requestId = null;
      _atCheckpoint = false;
      _error = message;
      _read = const MarkerData();
      _write = const MarkerData();
      if (_catalogUpdatePending) {
        _algorithm = _mappedAlgorithm();
        _catalogUpdatePending = false;
      }
    });
    _watchdog?.cancel();
    _worker?.terminate();
    _worker = null;
  }

  void _stop({bool updateState = true}) {
    _watchdog?.cancel();
    _watchdog = null;
    _subscription?.cancel();
    _subscription = null;
    _worker?.terminate();
    _worker = null;
    _requestId = null;
    _atCheckpoint = false;
    if (updateState && mounted) {
      setState(() {
        _running = false;
        _paused = false;
        _read = const MarkerData();
        _write = const MarkerData();
        if (_catalogUpdatePending) {
          _algorithm = _mappedAlgorithm();
          _catalogUpdatePending = false;
        }
      });
    }
  }

  int? _markerIndex(MarkerData marker, String list) =>
      marker.list == list ? marker.index : null;

  Map<String, int> _indexVariables() {
    if (!_running) return const {};
    final result = <String, int>{};
    for (final entry in _locals.entries) {
      final value = entry.value;
      if (value is int && value >= 0 && value < _numbers.length) {
        result[entry.key] = value;
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.catalog.algorithms.isEmpty && !_running) {
      return const Center(
        child: Text('No valid algorithms have been prepared yet.'),
      );
    }

    final controls = _controls(context);
    final visual = Column(
      children: [
        Expanded(
          child: ArrayView(
            values: _numbers,
            label: 'List to be sorted',
            readIndex: _showMemoryAccess ? _markerIndex(_read, 'list') : null,
            writeIndex: _showMemoryAccess ? _markerIndex(_write, 'list') : null,
            baseColor: _algorithm == null
                ? null
                : parseHexColor(_algorithm!.color),
            indexVariables: _indexVariables(),
          ),
        ),
        const SizedBox(height: 8),
        _stats(context),
        const SizedBox(height: 8),
        Expanded(
          child: ArrayView(
            values: _scratch,
            label: 'Temporary list',
            readIndex: _showMemoryAccess
                ? _markerIndex(_read, 'scratch')
                : null,
            writeIndex: _showMemoryAccess
                ? _markerIndex(_write, 'scratch')
                : null,
            baseColor: Colors.grey,
          ),
        ),
        const SizedBox(height: 10),
        controls,
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1050) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(flex: 3, child: visual),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      _localsPanel(context),
                      const SizedBox(height: 8),
                      Expanded(
                        child: SourceView(
                          source: _algorithm!.source,
                          line: _line,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Expanded(child: visual),
              const SizedBox(height: 8),
              SizedBox(height: 130, child: _localsPanel(context)),
            ],
          ),
        );
      },
    );
  }

  Widget _stats(BuildContext context) => Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Text('Reads: ${_short(_metrics.reads)}'),
          Text('Writes: ${_short(_metrics.writes)}'),
          Text('Comparisons: ${_short(_metrics.comparisons)}'),
        ],
      ),
      const SizedBox(height: 4),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _legendDot(Theme.of(context).colorScheme.primary, 'index variable'),
          FilterChip(
            selected: _showMemoryAccess,
            avatar: const Icon(Icons.memory, size: 16),
            label: const Text('Highlight reads/writes'),
            onSelected: (value) => setState(() => _showMemoryAccess = value),
          ),
          if (_showMemoryAccess) ...[
            _legendDot(Colors.orange, 'read'),
            _legendDot(Theme.of(context).colorScheme.error, 'write'),
          ],
        ],
      ),
    ],
  );

  Widget _legendDot(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.circle, color: color, size: 9),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 11)),
    ],
  );

  Widget _localsPanel(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Variables', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Expanded(
              child: _locals.isEmpty
                  ? Text(
                      _running
                          ? 'Waiting for first checkpoint…'
                          : 'Run the algorithm to track local variables automatically.',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  : SingleChildScrollView(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final entry in (_locals.entries.toList()
                            ..sort((a, b) => a.key.compareTo(b.key))))
                            SizedBox(
                              width: 116,
                              child: Chip(
                                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                                label: Text(
                                  '${entry.key} = ${entry.value}',
                                  maxLines: 1,
                                  overflow: TextOverflow.fade,
                                  softWrap: false,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontFamily: 'monospace'),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    return Column(
      children: [
        AlgorithmPicker(
          algorithms: widget.catalog.algorithms,
          value: _algorithm,
          enabled: !_running,
          onChanged: (value) {
            if (value == null) return;
            // Selecting another implementation should show the untouched
            // input immediately. Keep the exact same permutation so students
            // can compare algorithms rather than accidentally comparing data.
            setState(() {
              _algorithm = value;
              _restoreInputState();
            });
          },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
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
                  _shape = value;
                  _resetInput();
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _running ? null : _resetInput,
              tooltip: 'New input',
              icon: const Icon(Icons.shuffle),
            ),
            IconButton(
              onPressed: (!_running || (_paused && _atCheckpoint))
                  ? _step
                  : null,
              tooltip: 'Single step',
              icon: const Icon(Icons.skip_next),
            ),
            IconButton(
              onPressed: _togglePause,
              tooltip: !_running ? 'Run' : (_paused ? 'Continue' : 'Pause'),
              icon: Icon(
                !_running
                    ? Icons.play_arrow
                    : (_paused ? Icons.play_arrow : Icons.pause),
              ),
            ),
            IconButton(
              onPressed: _running ? _stop : null,
              tooltip: 'Stop',
              icon: const Icon(Icons.stop),
            ),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 52, child: Text('Speed')),
            Expanded(
              child: Slider(
                value: _speed.toDouble(),
                min: 0,
                max: 5,
                divisions: 5,
                onChanged: (value) => setState(() => _speed = value.round()),
              ),
            ),
            const SizedBox(width: 52, child: Icon(Icons.speed)),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 52, child: Text('Size')),
            Expanded(
              child: Slider(
                value: _sizes.indexOf(_n).toDouble(),
                min: 0,
                max: (_sizes.length - 1).toDouble(),
                divisions: _sizes.length - 1,
                onChanged: _running
                    ? null
                    : (value) {
                        _n = _sizes[value.round()];
                        _resetInput();
                      },
              ),
            ),
            SizedBox(width: 64, child: Text('n=$_n')),
          ],
        ),
      ],
    );
  }

  String _short(int value) => compactCount(value);
}
