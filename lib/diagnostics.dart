import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The native engine owns sockets and clocks. Flutter receives aggregate state.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.isHost});
  final bool isHost;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  static const _methods = MethodChannel('silent_disco/diagnostics');
  static const _events = EventChannel('silent_disco/diagnostics/events');
  StreamSubscription<dynamic>? _subscription;
  Map<String, dynamic> _state = {};
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _notes = TextEditingController();
  String _profile = 'connectivity';
  String _error = '';
  bool _offlineConfirmed = false;

  @override
  void initState() {
    super.initState();
    _subscription = _events.receiveBroadcastStream().listen(
      (dynamic event) {
        if (mounted && event is Map) {
          setState(() => _state = Map<String, dynamic>.from(event));
        }
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = error.toString());
      },
    );
  }

  Future<void> _call(String name, [Map<String, dynamic>? args]) async {
    setState(() => _error = '');
    try {
      final result = await _methods.invokeMethod<dynamic>(name, args);
      if (name == 'exportReport' && result is String && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved report: $result')));
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    } on MissingPluginException {
      if (mounted) {
        setState(
          () => _error = 'Run this screen in the native macOS or iOS app.',
        );
      }
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _host.dispose();
    _port.dispose();
    _notes.dispose();
    super.dispose();
  }

  Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};

  Widget _card(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );

  String _number(dynamic n, [int decimals = 1]) =>
      n is num ? n.toStringAsFixed(decimals) : '—';

  @override
  Widget build(BuildContext context) {
    final active = _state['active'] == true;
    final ready = _state['ready'] == true;
    final hosting = _state['hosting'] == true;
    final status = _state['status'] as String? ?? 'idle';
    final phase = _state['phase'] as String? ?? 'idle';
    final metrics = _map(_state['metrics']);
    final remote = _map(_state['remoteMetrics']);
    final report = _map(_state['report']);
    final error = _error.isNotEmpty
        ? _error
        : (_state['error'] as String? ?? '');
    final elapsed = (_state['elapsed'] as num? ?? 0).toDouble();
    final duration = (_state['duration'] as num? ?? 0).toDouble();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isHost ? 'Silent Disco · Hub' : 'Silent Disco · Listener',
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Offline LAN diagnostics',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              const Text(
                'One phone · synthetic traffic · 10-minute maximum. No audio is played.',
              ),
              const SizedBox(height: 12),
              if (error.isNotEmpty)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(error),
                  ),
                ),
              _card('Connection', [
                Text('Status: $status', key: const Key('connection-status')),
                if ((_state['endpoint'] as String? ?? '').isNotEmpty)
                  SelectableText('Peer: ${_state['endpoint']}'),
                const SizedBox(height: 12),
                if (widget.isHost) ...[
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: hosting ? null : () => _call('startHost'),
                        child: const Text('Start server'),
                      ),
                      OutlinedButton(
                        onPressed: hosting ? () => _call('stopHost') : null,
                        child: const Text('Stop server'),
                      ),
                    ],
                  ),
                  if (hosting) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Bonjour: Silent Disco Diagnostics · _silentdisco._tcp',
                    ),
                    Text(
                      'TCP port: ${_state['tcpPort']} · UDP port: ${_state['udpPort']}',
                    ),
                    SelectableText(
                      ((_state['addresses'] as List?) ?? []).join('\n'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'A listening server does not verify that the offline hotspot is configured. Use the sharing-network address, not loopback.',
                  ),
                ] else ...[
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () => _call('browse'),
                        child: const Text('Find hubs / retry'),
                      ),
                      OutlinedButton(
                        onPressed: () => _call('disconnect'),
                        child: const Text('Disconnect'),
                      ),
                    ],
                  ),
                  for (final dynamic entry
                      in (_state['services'] as List? ?? []))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${entry['name']}'),
                      trailing: TextButton(
                        onPressed: active
                            ? null
                            : () => _call('connect', {'id': entry['id']}),
                        child: const Text('Connect'),
                      ),
                    ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Manual IP and port'),
                    children: [
                      TextField(
                        controller: _host,
                        decoration: const InputDecoration(
                          labelText: 'Mac sharing-network IP address',
                        ),
                      ),
                      TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'TCP port shown on Mac',
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: active
                            ? null
                            : () => _call('connect', {
                                'host': _host.text.trim(),
                                'port': int.tryParse(_port.text) ?? 0,
                              }),
                        child: const Text('Connect manually'),
                      ),
                    ],
                  ),
                  const Text(
                    'Join the Mac’s Wi-Fi in Settings first. Discovery does not join Wi-Fi. If blocked, check Settings → Privacy & Security → Local Network.',
                  ),
                ],
              ]),
              _card('Traffic test', [
                DropdownButtonFormField<String>(
                  initialValue: _profile,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Profile'),
                  items: const [
                    DropdownMenuItem(
                      value: 'connectivity',
                      child: Text('Connectivity · 30 seconds'),
                    ),
                    DropdownMenuItem(
                      value: 'baseline',
                      child: Text('One-channel baseline · 10 minutes'),
                    ),
                    DropdownMenuItem(
                      value: 'threeChannel',
                      child: Text('Three-channel preview · 10 minutes'),
                    ),
                  ],
                  onChanged: active
                      ? null
                      : (value) => setState(() => _profile = value!),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('I confirmed the offline setup'),
                  subtitle: const Text(
                    'Mac hosts Wi-Fi; no upstream internet; phone cellular off and USB unplugged.',
                  ),
                  value: _offlineConfirmed,
                  onChanged: active
                      ? null
                      : (value) =>
                            setState(() => _offlineConfirmed = value ?? false),
                ),
                TextField(
                  controller: _notes,
                  enabled: !active,
                  maxLength: 2000,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText:
                        'Setup notes (IP, subnet, router, device, location)',
                  ),
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      key: const Key('start-test'),
                      onPressed: ready && !active
                          ? () => _call('startTest', {
                              'profile': _profile,
                              'notes': _notes.text,
                              'offlineConfirmed': _offlineConfirmed,
                            })
                          : null,
                      child: const Text('Start test'),
                    ),
                    OutlinedButton(
                      onPressed: active ? () => _call('stopTest') : null,
                      child: const Text('Stop test'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Run: $phase · ${elapsed.toStringAsFixed(0)}${duration > 0 ? ' / ${duration.toStringAsFixed(0)}' : ''} seconds',
                  key: const Key('run-status'),
                ),
                if (active) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: duration > 0
                        ? (elapsed / duration).clamp(0, 1)
                        : null,
                  ),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Keep the phone app visible. Locking or backgrounding interrupts the run. Reconnection never resumes an old run.',
                ),
              ]),
              _card('Live measurements', [
                Text(
                  'Submitted: ${metrics['submitted'] ?? 0} · Unique received: ${metrics['unique'] ?? 0}',
                ),
                Text(
                  'Duplicates: ${metrics['duplicates'] ?? 0} · Reordered: ${metrics['reordered'] ?? 0}',
                ),
                Text(
                  'Send errors: ${metrics['sendErrors'] ?? 0} · Skipped send slots: ${metrics['skippedSendSlots'] ?? 0}',
                ),
                Text(
                  'Transmit: ${_number(metrics['submittedKbps'])} kbps · Receive: ${_number(metrics['payloadKbps'])} kbps',
                ),
                Text('Longest receive gap: ${_number(metrics['maxGapMs'])} ms'),
                Text(
                  'Mean interarrival variation: ${_number(metrics['meanInterarrivalVariationMs'])} ms',
                ),
                if (widget.isHost) ...[
                  Text(
                    'Echo RTT median / p95 / p99 / max: ${_number(metrics['rttMedianMs'])} / ${_number(metrics['rttP95Ms'])} / ${_number(metrics['rttP99Ms'])} / ${_number(metrics['rttMaxMs'])} ms',
                  ),
                  Text(
                    'Phone unique received: ${remote['unique'] ?? 0} · Echoes submitted: ${remote['submitted'] ?? 0}',
                  ),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Final directional loss is calculated after the drain and counter exchange. RTT is not one-way latency or audio synchronization.',
                ),
              ]),
              if (report.isNotEmpty)
                _card('Latest report', [
                  Text(
                    'Status: ${report['status']} · Gate: ${report['networkGate'] ?? 'incomplete'}',
                  ),
                  Text('Reason: ${report['reason']}'),
                  Text(
                    'Missing downstream: ${report['downstreamMissing'] ?? 'unknown'} · upstream: ${report['upstreamMissing'] ?? 'unknown'}',
                  ),
                  Text(
                    'Offline setup user-confirmed: ${report['offlineSetupUserConfirmed'] == true ? 'yes' : 'no'}',
                  ),
                  if (widget.isHost)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: () => _call('exportReport'),
                        child: const Text('Export JSON report'),
                      ),
                    ),
                  ExpansionTile(
                    title: const Text('Report details'),
                    children: [
                      SelectableText(
                        const JsonEncoder.withIndent('  ').convert(report),
                      ),
                    ],
                  ),
                ]),
              _card('Recent events', [
                for (final dynamic event
                    in (_state['events'] as List? ?? []).reversed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('${event['at']}  ${event['message']}'),
                  ),
                if ((_state['events'] as List? ?? []).isEmpty)
                  const Text('No events yet.'),
              ]),
              const Card(
                child: ExpansionTile(
                  title: Text('Manual setup and test limits'),
                  childrenPadding: EdgeInsets.all(16),
                  children: [
                    SelectableText(
                      '1. Follow docs/OFFLINE_LAN_SETUP.md on the Mac to create the experimental loopback service and manually enable Internet Sharing.\n'
                      '2. Install the phone app, unplug USB, enable Airplane Mode, then reenable Wi-Fi and join SilentDisco-Test.\n'
                      '3. Start the Mac server, find the hub on the phone, connect, and run Connectivity.\n'
                      '4. Run the 10-minute baseline once. Multi-phone capacity, Bluetooth, and background audio remain untested.\n'
                      'Troubleshooting: check local-network permission, firewall access, the correct IP/port, and Internet Sharing. Do not disable the firewall globally.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
