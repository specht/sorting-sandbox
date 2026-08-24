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
    final colorScheme = ColorScheme.fromSeed(seedColor: Colors.green);
    return MaterialApp(
      title: 'Sorting Sandbox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: colorScheme.surface,
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.green.shade800,
          foregroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 2,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: colorScheme.surfaceContainer,
          indicatorColor: colorScheme.secondaryContainer,
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
    final pages = [
      ExploreScreen(catalog: widget.catalog),
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
      bottomNavigationBar: NavigationBar(
        selectedIndex: _page,
        onDestinationSelected: (value) => setState(() => _page = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.sort), label: 'Explore'),
          NavigationDestination(icon: Icon(Icons.sports_score), label: 'Race'),
          NavigationDestination(
            icon: Icon(Icons.query_stats),
            label: 'Analyze',
          ),
        ],
      ),
    );
  }
}
