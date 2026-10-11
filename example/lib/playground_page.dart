import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';

import 'demo_catalog.dart';
import 'metrics_dialog.dart';

enum _SourceKind { asset, network, file }

/// Interactive harness for the direct engine API: pick a source, turn every
/// ThumbnailSpec knob, and inspect the raw [Thumbnail] result (path, size,
/// wasCached, latency). Also drives prefetch, evict and clearCache.
class PlaygroundPage extends StatefulWidget {
  const PlaygroundPage({super.key});

  @override
  State<PlaygroundPage> createState() => _PlaygroundPageState();
}

class _PlaygroundPageState extends State<PlaygroundPage> {
  _SourceKind _kind = _SourceKind.network;
  String _asset = landscapeAsset;
  final _urlController = TextEditingController(text: bbbMp4Url);
  final _fileController = TextEditingController();

  double _maxSize = 480;
  double _positionSeconds = 10;
  bool _exact = false;
  ThumbnailFormat _format = ThumbnailFormat.jpeg;
  double _quality = 80;
  ThumbnailPriority _priority = ThumbnailPriority.visible;

  bool _busy = false;
  Thumbnail? _result;
  Uint8List? _resultBytes;
  Duration? _elapsed;
  Object? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _fileController.dispose();
    super.dispose();
  }

  VideoSource _buildSource() {
    switch (_kind) {
      case _SourceKind.asset:
        return VideoSource.asset(_asset);
      case _SourceKind.network:
        return VideoSource.network(Uri.parse(_urlController.text.trim()));
      case _SourceKind.file:
        return VideoSource.file(_fileController.text.trim());
    }
  }

  ThumbnailSpec _buildSpec() {
    final size = _maxSize.round();
    return ThumbnailSpec(
      maxWidth: size,
      maxHeight: size,
      position: Duration(milliseconds: (_positionSeconds * 1000).round()),
      exact: _exact,
      format: _format,
      quality: _format == ThumbnailFormat.png ? 100 : _quality.round(),
    );
  }

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final stopwatch = Stopwatch()..start();
    try {
      final thumbnail = await ThumbnailEngine.instance.getThumbnail(
        _buildSource(),
        spec: _buildSpec(),
        priority: _priority,
        timeout: const Duration(seconds: 90),
      );
      stopwatch.stop();
      final bytes = await File(thumbnail.filePath).readAsBytes();
      if (!mounted) return;
      setState(() {
        _result = thumbnail;
        _resultBytes = bytes;
        _elapsed = stopwatch.elapsed;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _result = null;
        _resultBytes = null;
        _elapsed = stopwatch.elapsed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prefetch() async {
    try {
      ThumbnailEngine.instance.prefetch(_buildSource(), spec: _buildSpec());
      _toast('Prefetch queued (lowest priority band).');
    } catch (e) {
      _toast('Invalid source: $e');
    }
  }

  Future<void> _evict() async {
    try {
      await ThumbnailEngine.instance.evict(_buildSource());
      _toast('Evicted every cached thumbnail of this source.');
    } catch (e) {
      _toast('Invalid source: $e');
    }
  }

  Future<void> _clearCache() async {
    await ThumbnailEngine.instance.clearCache();
    _toast('Disk cache cleared.');
  }

  /// Fills the file field with a real on-disk copy of the bundled fixture.
  Future<void> _useCopiedFixture() async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/playground_landscape.mp4');
    if (!file.existsSync()) {
      final data = await rootBundle.load(landscapeAsset);
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    if (!mounted) return;
    _fileController.text = file.path;
    _toast('Fixture copied to ${file.path}');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sourceCard(),
        const SizedBox(height: 12),
        _specCard(),
        const SizedBox(height: 12),
        _actionsRow(),
        const SizedBox(height: 12),
        _resultCard(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _sourceCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Source', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<_SourceKind>(
              segments: const [
                ButtonSegment(value: _SourceKind.asset, label: Text('Asset')),
                ButtonSegment(value: _SourceKind.network, label: Text('URL')),
                ButtonSegment(value: _SourceKind.file, label: Text('File')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 12),
            switch (_kind) {
              _SourceKind.asset => DropdownButtonFormField<String>(
                initialValue: _asset,
                decoration: const InputDecoration(
                  labelText: 'Bundled asset',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: landscapeAsset,
                    child: Text('landscape.mp4'),
                  ),
                  DropdownMenuItem(
                    value: portraitAsset,
                    child: Text('portrait_rot90.mp4'),
                  ),
                ],
                onChanged: (v) => setState(() => _asset = v!),
              ),
              _SourceKind.network => TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Video URL (mp4 / m4v / mov / m3u8)',
                  border: OutlineInputBorder(),
                ),
              ),
              _SourceKind.file => Column(
                children: [
                  TextField(
                    controller: _fileController,
                    decoration: const InputDecoration(
                      labelText: 'Absolute file path',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.file_copy, size: 18),
                      label: const Text('Use a copied bundled fixture'),
                      onPressed: _useCopiedFixture,
                    ),
                  ),
                ],
              ),
            },
          ],
        ),
      ),
    );
  }

  Widget _specCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Spec', style: Theme.of(context).textTheme.titleSmall),
            _slider(
              label: 'Max size (0 = native)',
              value: _maxSize,
              max: 1024,
              divisions: 32,
              display: _maxSize.round() == 0
                  ? 'native'
                  : '${_maxSize.round()}px',
              onChanged: (v) => setState(() => _maxSize = v),
            ),
            _slider(
              label: 'Position',
              value: _positionSeconds,
              max: 300,
              divisions: 60,
              display: '${_positionSeconds.round()}s',
              onChanged: (v) => setState(() => _positionSeconds = v),
            ),
            _slider(
              label: 'JPEG quality',
              value: _quality,
              min: 1,
              max: 100,
              divisions: 99,
              display: _format == ThumbnailFormat.png
                  ? 'n/a for PNG'
                  : '${_quality.round()}',
              onChanged: _format == ThumbnailFormat.png
                  ? null
                  : (v) => setState(() => _quality = v),
            ),
            Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Exact frame'),
                    value: _exact,
                    onChanged: (v) => setState(() => _exact = v),
                  ),
                ),
                SegmentedButton<ThumbnailFormat>(
                  segments: const [
                    ButtonSegment(
                      value: ThumbnailFormat.jpeg,
                      label: Text('JPEG'),
                    ),
                    ButtonSegment(
                      value: ThumbnailFormat.png,
                      label: Text('PNG'),
                    ),
                  ],
                  selected: {_format},
                  onSelectionChanged: (s) => setState(() => _format = s.first),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text('Priority  '),
                Expanded(
                  child: SegmentedButton<ThumbnailPriority>(
                    segments: const [
                      ButtonSegment(
                        value: ThumbnailPriority.prefetch,
                        label: Text('prefetch'),
                      ),
                      ButtonSegment(
                        value: ThumbnailPriority.normal,
                        label: Text('normal'),
                      ),
                      ButtonSegment(
                        value: ThumbnailPriority.visible,
                        label: Text('visible'),
                      ),
                    ],
                    selected: {_priority},
                    onSelectionChanged: (s) =>
                        setState(() => _priority = s.first),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double>? onChanged,
    double min = 0,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 70, child: Text(display, textAlign: TextAlign.end)),
      ],
    );
  }

  Widget _actionsRow() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.image, size: 18),
          label: const Text('Generate'),
          onPressed: _busy ? null : _generate,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.download_for_offline, size: 18),
          label: const Text('Prefetch'),
          onPressed: _prefetch,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.remove_circle_outline, size: 18),
          label: const Text('Evict source'),
          onPressed: _evict,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.delete_sweep, size: 18),
          label: const Text('Clear cache'),
          onPressed: _clearCache,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.query_stats, size: 18),
          label: const Text('Metrics'),
          onPressed: () => showMetricsDialog(context),
        ),
      ],
    );
  }

  Widget _resultCard() {
    if (_error != null) {
      return Card(
        color: Colors.red.shade50,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Failed after ${_elapsed?.inMilliseconds}ms',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text('$_error', style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
    }
    final result = _result;
    final bytes = _resultBytes;
    if (result == null || bytes == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No result yet. Tap Generate.'),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
            const SizedBox(height: 8),
            Text(
              '${result.width}x${result.height} '
              '| ${(bytes.length / 1024).toStringAsFixed(1)} KiB '
              '| ${result.wasCached ? 'cache hit' : 'extracted'} '
              '| ${_elapsed?.inMilliseconds}ms\n'
              '${result.filePath}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
