import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/theme.dart';
import '../../providers/core_providers.dart';

class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  List<Map<String, dynamic>> _checks = [];
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result =
          await ref.read(apiClientProvider).get('/api/diagnostics/system');
      if (!mounted) return;
      setState(() => _checks = (result['checks'] as List? ?? [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList());
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not load system diagnostics.');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('System diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Refresh checks',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Text('Backend service checks', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.xs),
              Text(
                  'Read-only checks for the services needed to upload and process videos.',
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: AppSpacing.md),
              if (_loading && _checks.isEmpty) const LinearProgressIndicator(),
              if (_error != null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.error_outline, color: Colors.red),
                    title: const Text('Diagnostics unavailable'),
                    subtitle: Text(_error!),
                    trailing: TextButton(
                        onPressed: _refresh, child: const Text('Retry')),
                  ),
                ),
              for (final check in _checks) _CheckCard(check: check),
              if (_checks.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  'These checks verify connectivity and installed tools. They do not upload a video or spend AI credits.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckCard extends StatelessWidget {
  const _CheckCard({required this.check});

  final Map<String, dynamic> check;

  @override
  Widget build(BuildContext context) {
    final status = check['status'] as String? ?? 'unknown';
    final color = switch (status) {
      'ok' => Colors.green,
      'warning' => Colors.orange,
      'blocked' => Colors.blueGrey,
      _ => Colors.red,
    };
    final icon = switch (status) {
      'ok' => Icons.check_circle_outline,
      'warning' => Icons.warning_amber_rounded,
      'blocked' => Icons.info_outline,
      _ => Icons.cancel_outlined,
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(check['name'] as String? ?? 'Service'),
        subtitle: Text(check['detail'] as String? ?? 'No details available.'),
        trailing: Text(status.toUpperCase(),
            style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
