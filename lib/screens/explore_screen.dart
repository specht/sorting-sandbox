import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  const ExploreScreen({
    super.key,
    required this.catalog,
    this.active = true,
  });

  final AlgorithmCatalog catalog;
  final bool active;

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
  int _speed = 8;
  InputShape _shape = InputShape.random;
  bool _running = false;
  bool _paused = false;
  String? _requestId;
  bool _atCheckpoint = false;
  String? _error;
  int _seed = 42;
  bool _catalogUpdatePending = false;
  bool _showMemoryAccess = false;
  final List<VisualFrame> _history = [];
  int _historyCursor = -1;
  int _latestCheckpoint = -1;
  int? _scrubTarget;
  bool _replaying = false;
  int? _replayTarget;
  bool _continueAfterReplay = false;

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
  // Twenty-one speed levels preserve the old six anchor speeds exactly,
  // with geometric interpolation for execution budget and linear
  // interpolation for frame delay between them.
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

  int get _currentCheckpoint {
    if (_historyCursor < 0 || _historyCursor >= _history.length) return -1;
    return _history[_historyCursor].checkpoint;
  }

  bool get _viewingHistory =>
      _currentCheckpoint >= 0 && _currentCheckpoint < _latestCheckpoint;

  bool get _canBrowseHistory =>
      _latestCheckpoint >= 0 && (!_running || (_atCheckpoint && !_replaying));

  bool get _canStepBack => _canBrowseHistory && _currentCheckpoint > 0;

  bool get _canStepForward {
    if (_currentCheckpoint < 0) return !_running;
    if (_currentCheckpoint < _latestCheckpoint) return _canBrowseHistory;
    return _running && _paused && _atCheckpoint && !_replaying;
  }

  int get _historyLimit {
    final cells = _numbers.isEmpty ? 1 : _numbers.length * 3;
    final bySize = 300000 ~/ cells;
    if (bySize < 24) return 24;
    if (bySize > 300) return 300;
    return bySize;
  }

  void _clearHistoryState() {
    _history.clear();
    _historyCursor = -1;
    _latestCheckpoint = -1;
    _scrubTarget = null;
    _replaying = false;
    _replayTarget = null;
    _continueAfterReplay = false;
  }

  void _applyFrameState(VisualFrame frame) {
    _numbers = frame.numbers;
    _scratch = frame.scratch;
    _metrics = frame.metrics;
    _read = frame.read;
    _write = frame.write;
    _locals = frame.locals;
    _line = frame.line;
  }

  void _recordFrameState(VisualFrame frame) {
    if (frame.checkpoint > _latestCheckpoint) {
      _latestCheckpoint = frame.checkpoint;
    }

    var index = _history.indexWhere(
      (candidate) => candidate.checkpoint >= frame.checkpoint,
    );
    if (index >= 0 && _history[index].checkpoint == frame.checkpoint) {
      _history[index] = frame;
    } else {
      if (index < 0) index = _history.length;
      _history.insert(index, frame);
    }
    _historyCursor = index;

    // Keep a sparse cache distributed across the whole timeline. Exact
    // checkpoints are still reconstructed by replay, while these samples make
    // dragging the timeline feel immediate even for very large runs.
    while (_history.length > _historyLimit) {
      var removeIndex = -1;
      int? smallestSpan;
      for (var i = 1; i < _history.length - 1; i++) {
        if (i == _historyCursor) continue;
        final span = _history[i + 1].checkpoint - _history[i - 1].checkpoint;
        if (smallestSpan == null || span < smallestSpan) {
          smallestSpan = span;
          removeIndex = i;
        }
      }

      // Normally an interior sample can be thinned. The fallback only matters
      // for very small limits and still protects the frame being displayed.
      if (removeIndex < 0) {
        removeIndex = _historyCursor == 0 ? _history.length - 1 : 0;
      }
      _history.removeAt(removeIndex);
      if (removeIndex < _historyCursor) _historyCursor--;
    }
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
    _clearHistoryState();
  }

  void _restoreInput() => setState(_restoreInputState);

  void _resetInput() {
    _seed++;
    _input = makeInput(_n, _shape, seed: _seed);
    _restoreInput();
  }

  Future<void> _start({
    bool paused = false,
    int? replayCheckpoint,
    bool continueAfterReplay = false,
  }) async {
    final algorithm = _algorithm;
    if (algorithm == null) return;
    _stop();

    if (replayCheckpoint == null) {
      _history.clear();
      _historyCursor = -1;
    }

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
        if (_replaying) {
          _handleReplayFrame(frame, requestId);
          return;
        }
        setState(() {
          _applyFrameState(frame);
          _recordFrameState(frame);
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
      _paused = paused || replayCheckpoint != null;
      _atCheckpoint = false;
      _error = null;
      _replaying = replayCheckpoint != null;
      _replayTarget = replayCheckpoint;
      _continueAfterReplay = continueAfterReplay;
    });

    worker.send({
      'type': 'visualStart',
      'requestId': requestId,
      'algorithmId': algorithm.id,
      'values': replayCheckpoint == null ? _numbers : _input,
    });

    _armWatchdog();
  }

  void _handleReplayFrame(VisualFrame frame, String requestId) {
    final target = _replayTarget;
    if (target == null) return;

    if (frame.checkpoint < target) {
      _sendAdvance(target - frame.checkpoint, requestId: requestId);
      return;
    }
    if (frame.checkpoint > target) {
      _fail(
        'Could not replay checkpoint $target '
        '(worker reached ${frame.checkpoint}).',
      );
      return;
    }

    final continueRunning = _continueAfterReplay && !frame.done;
    setState(() {
      _applyFrameState(frame);
      _recordFrameState(frame);
      _replaying = false;
      _replayTarget = null;
      _continueAfterReplay = false;
      _paused = !continueRunning;
      _atCheckpoint = true;
    });

    if (continueRunning) {
      _scheduleAdvance(requestId);
    } else {
      _watchdog?.cancel();
      _watchdog = null;
    }
  }

  void _armWatchdog() {
    if (!_running || _worker == null || _watchdog != null) return;
    _watchdog = _worker!.watchdog(
      timeout: _replaying
          ? const Duration(seconds: 6)
          : const Duration(seconds: 2),
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
    if (_viewingHistory) {
      unawaited(_resumeFromHistory(continueRunning: true));
      return;
    }
    if (!_running) {
      _start();
      return;
    }
    if (_replaying) return;
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

  void _stepBack() {
    if (!_canStepBack) return;
    _showCheckpoint(_currentCheckpoint - 1);
  }

  void _stepForward() {
    if (_currentCheckpoint < 0) {
      if (!_running) _start(paused: true);
      return;
    }
    if (_currentCheckpoint < _latestCheckpoint) {
      _showCheckpoint(_currentCheckpoint + 1);
      return;
    }
    if (_running && _paused && _atCheckpoint && !_replaying) {
      _sendAdvance(1);
    }
  }

  void _showCheckpoint(int checkpoint) {
    if (!_canBrowseHistory ||
        checkpoint < 0 ||
        checkpoint > _latestCheckpoint) {
      return;
    }
    _scrubTarget = null;
    final cached = _history.indexWhere(
      (frame) => frame.checkpoint == checkpoint,
    );
    if (cached >= 0) {
      _showHistoryAt(cached);
      return;
    }

    // Fast-forward a fresh disposable worker to the exact checkpoint. This
    // keeps high-speed animation sparse while making debug stepping exact.
    unawaited(_start(paused: true, replayCheckpoint: checkpoint));
  }

  int _nearestCachedIndex(int checkpoint) {
    if (_history.isEmpty) return -1;
    var low = 0;
    var high = _history.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final value = _history[middle].checkpoint;
      if (value == checkpoint) return middle;
      if (value < checkpoint) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (low <= 0) return 0;
    if (low >= _history.length) return _history.length - 1;
    final before = _history[low - 1].checkpoint;
    final after = _history[low].checkpoint;
    return checkpoint - before <= after - checkpoint ? low - 1 : low;
  }

  void _previewScrub(int checkpoint) {
    if (!_canBrowseHistory || _history.isEmpty) return;
    final target = checkpoint.clamp(0, _latestCheckpoint).toInt();
    final cached = _nearestCachedIndex(target);
    if (cached < 0) return;
    final frame = _history[cached];
    setState(() {
      _scrubTarget = target;
      if (_running) _paused = true;
      _historyCursor = cached;
      _applyFrameState(frame);
    });
    _watchdog?.cancel();
    _watchdog = null;
  }

  void _showHistoryAt(int index) {
    if (index < 0 || index >= _history.length) return;
    if (_running && (!_atCheckpoint || _replaying)) return;
    final frame = _history[index];
    setState(() {
      if (_running) _paused = true;
      _historyCursor = index;
      _applyFrameState(frame);
    });
    _watchdog?.cancel();
    _watchdog = null;
  }

  Future<void> _resumeFromHistory({required bool continueRunning}) async {
    if (_historyCursor < 0 || _historyCursor >= _history.length) return;
    final target = _history[_historyCursor].checkpoint;
    if (target < 0) return;

    setState(() {
      if (_historyCursor < _history.length - 1) {
        _history.removeRange(_historyCursor + 1, _history.length);
      }
      _historyCursor = _history.length - 1;
      _latestCheckpoint = target;
      _scrubTarget = null;
    });

    await _start(
      paused: true,
      replayCheckpoint: target,
      continueAfterReplay: continueRunning,
    );
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
      _replaying = false;
      _replayTarget = null;
      _continueAfterReplay = false;
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
      _replaying = false;
      _replayTarget = null;
      _continueAfterReplay = false;
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
    _replaying = false;
    _replayTarget = null;
    _continueAfterReplay = false;
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
    if (!_running && !_viewingHistory) return const {};
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
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
          child: Column(
            children: [
              Expanded(child: visual),
              const SizedBox(height: 4),
              SizedBox(height: 84, child: _localsPanel(context)),
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
          _legendDot(
            Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.30),
            '1 variable',
          ),
          _legendDot(
            Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.60),
            '2+ variables',
          ),
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
                          for (final entry
                              in (_locals.entries.toList()
                                ..sort((a, b) => a.key.compareTo(b.key))))
                            SizedBox(
                              width: 116,
                              child: Chip(
                                labelPadding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                label: Text(
                                  '${entry.key} = ${entry.value}',
                                  maxLines: 1,
                                  overflow: TextOverflow.fade,
                                  softWrap: false,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                  ),
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

  Widget _historyScrubber(BuildContext context) {
    final hasCheckpoint = _currentCheckpoint >= 0 && _latestCheckpoint >= 0;
    final current = hasCheckpoint ? _currentCheckpoint : 0;
    final maximum = _latestCheckpoint > 0 ? _latestCheckpoint : 1;
    final target = (_scrubTarget ?? current).clamp(0, maximum).toInt();
    final canScrub = _canBrowseHistory && _latestCheckpoint > 0;

    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Tooltip(
            message: _viewingHistory
                ? 'Viewing an earlier checkpoint. Run resumes from here.'
                : 'Execution history',
            child: Icon(_replaying ? Icons.sync : Icons.history, size: 18),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: ExcludeFocus(
                child: Slider(
                  value: target.toDouble(),
                  min: 0,
                  max: maximum.toDouble(),
                  divisions: _latestCheckpoint > 0 && _latestCheckpoint <= 5000
                      ? _latestCheckpoint
                      : null,
                  label: hasCheckpoint ? 'step $target' : 'start',
                  onChangeStart: canScrub
                      ? (_) => Focus.of(context).requestFocus()
                      : null,
                  onChanged: canScrub
                      ? (value) => _previewScrub(value.round())
                      : null,
                  onChangeEnd: canScrub
                      ? (value) {
                          final checkpoint = value.round();
                          setState(() => _scrubTarget = null);
                          _showCheckpoint(checkpoint);
                        }
                      : null,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 112,
            child: Text(
              hasCheckpoint ? 'step $target / $_latestCheckpoint' : 'start',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(BuildContext context) {
    return Focus(
      key: ValueKey(widget.active),
      autofocus: widget.active,
      canRequestFocus: widget.active,
      onKeyEvent: (_, event) {
        if (!widget.active || event is! KeyDownEvent || _replaying) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft && _canStepBack) {
          _stepBack();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
            _canStepForward) {
          _stepForward();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (controlsContext) => Column(
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
              onPressed: _canStepBack ? _stepBack : null,
              tooltip: 'Previous checkpoint',
              icon: const Icon(Icons.skip_previous),
            ),
            IconButton(
              onPressed: _canStepForward ? _stepForward : null,
              tooltip: 'Next checkpoint',
              icon: const Icon(Icons.skip_next),
            ),
            IconButton(
              onPressed: _replaying ? null : _togglePause,
              tooltip: _viewingHistory
                  ? 'Continue from this checkpoint'
                  : (!_running ? 'Run' : (_paused ? 'Continue' : 'Pause')),
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
        _historyScrubber(controlsContext),
        Row(
          children: [
            const SizedBox(width: 52, child: Text('Speed')),
            Expanded(
              child: Slider(
                value: _speed.toDouble(),
                min: 0,
                max: 20,
                divisions: 20,
                label: '${_speed * 5}%',
                onChanged: (value) => setState(() => _speed = value.round()),
              ),
            ),
            SizedBox(
              width: 52,
              child: Text('${_speed * 5}%', textAlign: TextAlign.end),
            ),
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
        ),
      ),
    );
  }

  String _short(int value) => compactCount(value);
}
