import 'dart:async';

import 'package:flutter/material.dart';

import 'catalog.dart';
import 'models.dart';
import 'screens/analyze_screen.dart';
import 'screens/explore_screen.dart';
import 'screens/race_screen.dart';

void main() {
  runApp(const SortingSandboxApp());
}

class SortingSandboxApp extends StatelessWidget {
  const SortingSandboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    const focusColor = Color(0xFF7DD3FC);
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: focusColor,
          brightness: Brightness.dark,
        ).copyWith(
          surface: const Color(0xFF171A20),
          surfaceContainerLowest: const Color(0xFF12151A),
          surfaceContainerLow: const Color(0xFF1C2027),
          surfaceContainer: const Color(0xFF21262E),
          surfaceContainerHigh: const Color(0xFF292F38),
          surfaceContainerHighest: const Color(0xFF323945),
          onSurface: const Color(0xFFE9EAF0),
          onSurfaceVariant: const Color(0xFFB8BBC4),
          outline: const Color(0xFF7C808A),
          outlineVariant: const Color(0xFF3B3E46),
        );
    final baseTheme = ThemeData(useMaterial3: true, colorScheme: colorScheme);
    return MaterialApp(
      title: 'Sorting Sandbox',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: baseTheme.copyWith(
        textTheme: baseTheme.textTheme.apply(fontSizeFactor: 1.08),
        scaffoldBackgroundColor: colorScheme.surface,
        appBarTheme: AppBarTheme(
          backgroundColor: colorScheme.surface,
          foregroundColor: colorScheme.onSurface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.transparent,
          indicatorColor: focusColor.withValues(alpha: 0.18),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              color: selected
                  ? colorScheme.onSurface
                  : colorScheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            );
          }),
        ),
        sliderTheme: const SliderThemeData(
          trackHeight: 4,
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 10),
          overlayShape: RoundSliderOverlayShape(overlayRadius: 18),
        ),
      ),
      home: const _CatalogLoader(),
    );
  }
}

class _CatalogLoader extends StatefulWidget {
  const _CatalogLoader();

  @override
  State<_CatalogLoader> createState() => _CatalogLoaderState();
}

class _CatalogLoaderState extends State<_CatalogLoader> {
  AlgorithmCatalog? _catalog;
  Object? _initialError;
  Timer? _pollTimer;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh(force: true));
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool force = false}) async {
    if (_loading) return;
    _loading = true;
    try {
      final next = await loadCatalog();
      if (!mounted) return;
      if (force || _catalog == null || next.buildId != _catalog!.buildId) {
        setState(() {
          _catalog = next;
          _initialError = null;
        });
      }
    } catch (error) {
      if (!mounted) return;
      // A transient read during a rebuild must never throw away a working
      // catalog. Only surface an error when the app has never loaded one.
      if (_catalog == null) {
        setState(() => _initialError = error);
      }
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    if (catalog == null) {
      if (_initialError != null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Sorting Sandbox')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Could not load the algorithm catalog.\n$_initialError'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => unawaited(_refresh(force: true)),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return _Home(
      catalog: catalog,
      onReload: () => unawaited(_refresh(force: true)),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home({required this.catalog, required this.onReload});

  final AlgorithmCatalog catalog;
  final VoidCallback onReload;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  int _page = 0;

  void _showDiagnostics() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Skipped algorithm files'),
        content: SizedBox(
          width: 680,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: widget.catalog.diagnostics.length,
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (context, index) {
              final diagnostic = widget.catalog.diagnostics[index];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  diagnostic.path.isEmpty ? 'Build' : diagnostic.path,
                ),
                subtitle: SelectableText(diagnostic.message),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final pages = [
      ExploreScreen(catalog: widget.catalog, active: _page == 0),
      RaceScreen(catalog: widget.catalog),
      AnalyzeScreen(catalog: widget.catalog),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sorting Sandbox'),
        actions: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Tooltip(
              message: 'Algorithm repository is watched automatically',
              child: Icon(Icons.sync, size: 19),
            ),
          ),
          if (widget.catalog.diagnostics.isNotEmpty)
            IconButton(
              onPressed: _showDiagnostics,
              tooltip:
                  '${widget.catalog.diagnostics.length} skipped algorithm file(s)',
              icon: Badge(
                label: Text('${widget.catalog.diagnostics.length}'),
                child: const Icon(Icons.warning_amber_rounded),
              ),
            ),
          IconButton(
            onPressed: widget.onReload,
            tooltip: 'Reload algorithm catalog now',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: IndexedStack(index: _page, children: pages),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Align(
          alignment: Alignment.center,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: SizedBox(
              width: double.infinity,
              child: Material(
                color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.97),
                surfaceTintColor: Colors.transparent,
                elevation: 8,
                shadowColor: Colors.black.withValues(alpha: 0.38),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.72),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: NavigationBar(
                  height: 64,
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  selectedIndex: _page,
                  onDestinationSelected: (value) =>
                      setState(() => _page = value),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.sort),
                      label: 'Explore',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.sports_score),
                      label: 'Race',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.query_stats),
                      label: 'Analyze',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
