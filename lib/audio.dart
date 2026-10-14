import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'diagnostics.dart';

class AudioScreen extends StatefulWidget {
  const AudioScreen({super.key, required this.isHost});
  final bool isHost;
  @override
  State<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends State<AudioScreen> {
  static const _methods = MethodChannel('silent_disco/audio');
  static const _events = EventChannel('silent_disco/audio/events');
  final _notes = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  StreamSubscription<dynamic>? _subscription;
  Map<String, dynamic> _state = {};
  String? _error;
  String? _failedMethod;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_markWithKeyboard);
    _subscription = _events.receiveBroadcastStream().listen(
      (event) {
        if (mounted && event is Map) {
          setState(() {
            _state = Map<String, dynamic>.from(event);
            if (_failedMethod == null) _error = null;
          });
        }
      },
      onError: (Object error) {
        if (mounted) {
          setState(() {
            _error = error.toString();
            _failedMethod = null;
          });
        }
      },
    );
    _call('snapshot');
  }

  Future<void> _call(String method, [Map<String, dynamic>? args]) async {
    try {
      await _methods.invokeMethod<dynamic>(method, args);
      if (mounted && _failedMethod == method) {
        setState(() {
          _error = null;
          _failedMethod = null;
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message ?? e.code;
          _failedMethod = method;
        });
      }
    }
  }

  KeyEventResult _markWithKeyboard(KeyEvent event) {
    if (!mounted ||
        !widget.isHost ||
        _state['active'] != true ||
        ModalRoute.of(context)?.isCurrent != true ||
        event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext?.widget is EditableText ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _call('markAudibleInterruption');
    return KeyEventResult.handled;
  }

  Future<void> _diagnostics() async {
    await _call('selectMode', {'audio': false});
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DiagnosticsScreen(isHost: widget.isHost),
      ),
    );
    await _call('selectMode', {'audio': true});
    await _call('snapshot');
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_markWithKeyboard);
    _subscription?.cancel();
    _notes.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Widget _row(String title, Object? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Text('$title: ${value ?? '—'}'),
  );

  @override
  Widget build(BuildContext context) {
    final active = _state['active'] == true;
    final busy = active || _state['draining'] == true;
    final hosting = _state['hosting'] == true;
    final listening = _state['listening'] == true;
    final stats = Map<String, dynamic>.from(_state['stats'] as Map? ?? {});
    final report = Map<String, dynamic>.from(_state['report'] as Map? ?? {});
    final services = _state['services'] as List? ?? [];
    final listeners = _state['listeners'] as List? ?? [];
    final error = _error ?? _state['error'] as String? ?? '';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Silent Disco Audio'),
        actions: [
          TextButton(
            onPressed: _diagnostics,
            child: const Text('LAN diagnostics'),
          ),
        ],
      ),
      bottomNavigationBar: active
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _call('markAudibleInterruption'),
                      icon: const Icon(Icons.flag_outlined),
                      label: Text(
                        widget.isHost
                            ? 'Mark audible interruption (Space)'
                            : 'Mark audible interruption',
                      ),
                    ),
                    if (widget.isHost)
                      for (final marker in const {
                        'background': 'Background app',
                        'foreground': 'Return to app',
                        'lock': 'Lock phone',
                        'wakeLocked': 'Wake screen while locked',
                        'unlock': 'Unlock phone',
                      }.entries)
                        OutlinedButton(
                          onPressed: () => _call('markTestTransition', {
                            'marker': marker.key,
                          }),
                          child: Text(marker.value),
                        ),
                  ],
                ),
              ),
            )
          : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                widget.isHost ? 'Single-channel host' : 'Listen together',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              _row('Connection', _state['status'] ?? 'idle'),
              if (error.isNotEmpty)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (widget.isHost) ...[
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(
                      onPressed: hosting ? null : () => _call('startHost'),
                      child: const Text('Start audio host'),
                    ),
                    OutlinedButton(
                      onPressed: hosting ? () => _call('stopHost') : null,
                      child: const Text('Stop host'),
                    ),
                  ],
                ),
                _row('TCP port (manual connection)', _state['port']),
                const SizedBox(height: 16),
                const Text('Audio source'),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Click track'),
                      selected: _state['sourceKind'] == 'clicks',
                      onSelected: busy
                          ? null
                          : (_) => _call('setSource', {'source': 'clicks'}),
                    ),
                    ChoiceChip(
                      label: const Text('Test tone'),
                      selected: _state['sourceKind'] == 'tone',
                      onSelected: busy
                          ? null
                          : (_) => _call('setSource', {'source': 'tone'}),
                    ),
                    OutlinedButton(
                      onPressed: busy ? null : () => _call('pickFile'),
                      child: const Text('Choose music file'),
                    ),
                  ],
                ),
                _row('Selected', _state['source']),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  key: ValueKey(_state['bufferMs'] ?? 1250),
                  initialValue: (_state['bufferMs'] as num? ?? 1250).toInt(),
                  decoration: const InputDecoration(
                    labelText: 'Shared presentation lead',
                  ),
                  items: [500, 750, 1000, 1250]
                      .map(
                        (ms) =>
                            DropdownMenuItem(value: ms, child: Text('$ms ms')),
                      )
                      .toList(),
                  onChanged: busy
                      ? null
                      : (ms) => _call('setBuffer', {'milliseconds': ms}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notes,
                  maxLength: 2000,
                  minLines: 2,
                  maxLines: 4,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Test notes',
                    hintText:
                        'Headphones, hotspot channel, Bluetooth settings, audible interruptions…',
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Offline setup confirmed: Mac upstream disconnected, phone USB/cellular off',
                  ),
                  value: _offline,
                  onChanged: busy
                      ? null
                      : (v) => setState(() => _offline = v ?? false),
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(
                      key: const Key('start-audio'),
                      onPressed: hosting && !busy
                          ? () => _call('startStream', {
                              'notes': _notes.text,
                              'offlineConfirmed': _offline,
                            })
                          : null,
                      child: const Text('Start audio · up to 10 min'),
                    ),
                    OutlinedButton(
                      onPressed: active ? () => _call('stopStream') : null,
                      child: const Text('Stop audio'),
                    ),
                  ],
                ),
                _row(
                  'Elapsed',
                  '${(_state['elapsed'] as num? ?? 0).toStringAsFixed(0)} / 600 s',
                ),
                _row('Skipped sender slots', _state['skippedSendSlots'] ?? 0),
                if (_state['draining'] == true)
                  const Text('Finishing playback and collecting reports…'),
                const Divider(),
                Text(
                  'Listeners (${listeners.length}/10)',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final raw in listeners)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${raw['name']}'),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${raw['listening'] == true ? 'Listening' : 'Connected'} · UDP ${raw['ready'] == true ? 'ready' : 'pending'}\nPackets sent ${raw['submitted']} · queue drops ${raw['queueDrops']}',
                        ),
                        if ((raw['compatibilityError'] as String? ?? '')
                            .isNotEmpty)
                          Text(
                            raw['compatibilityError'] as String,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 180,
                          child: Scrollbar(
                            child: SingleChildScrollView(
                              primary: false,
                              child: SelectableText('${raw['stats'] ?? {}}'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ] else ...[
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: () => _call('browse'),
                      child: const Text('Find audio hubs / retry'),
                    ),
                    OutlinedButton(
                      onPressed: () => _call('disconnect'),
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
                for (final raw in services)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${raw['name']}'),
                    trailing: TextButton(
                      onPressed: () => _call('connect', {'id': raw['id']}),
                      child: const Text('Connect'),
                    ),
                  ),
                ExpansionTile(
                  title: const Text('Manual connection'),
                  children: [
                    TextField(
                      controller: _host,
                      decoration: const InputDecoration(
                        labelText: 'Mac LAN IP address',
                      ),
                    ),
                    TextField(
                      controller: _port,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Audio TCP port',
                      ),
                    ),
                    TextButton(
                      onPressed: () => _call('connect', {
                        'host': _host.text.trim(),
                        'port': int.tryParse(_port.text),
                      }),
                      child: const Text('Connect manually'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _row('Source', _state['source']),
                _row('Output', _state['route']),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(
                      key: const Key('listen'),
                      onPressed: !listening && _state['ready'] == true
                          ? () => _call('listen')
                          : null,
                      child: const Text('Listen'),
                    ),
                    OutlinedButton(
                      onPressed: listening
                          ? () => _call('stopListening')
                          : null,
                      child: const Text('Stop listening'),
                    ),
                  ],
                ),
                _row(
                  'Playback',
                  stats['state'] ??
                      (listening ? 'Waiting for host / clock' : 'Stopped'),
                ),
                if (listening && !active)
                  const Text(
                    'Waiting for the host. Keep this app open until audio starts; reopen it to reconnect if it was backgrounded.',
                  ),
                _row('Buffered audio', '${stats['bufferMs'] ?? 0} ms'),
                _row(
                  'Clock',
                  stats['clockReady'] == true
                      ? 'Ready · RTT ${stats['clockRttMs']} ms'
                      : 'Measuring',
                ),
                _row('Late packets', stats['latePackets'] ?? 0),
                _row('Concealed frames', stats['concealedFrames'] ?? 0),
                _row(
                  'Underruns / rebuffer events',
                  '${stats['underruns'] ?? 0} / ${stats['rebufferEvents'] ?? 0}',
                ),
                const Text(
                  'Playback continues when locked. After headphones disconnect, reconnect them and tap Listen.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'After a prolonged background network outage, reopen the app to reconnect.',
                ),
              ],
              const Divider(),
              const Text(
                'Acoustic synchronization: unverified. Shared timing does not establish what different headphones emit.',
              ),
              if (report.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Latest audio report',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                _row('Run', report['status']),
                _row('Assessment', report['assessment']),
                _row('Reason', report['reason']),
                if (widget.isHost)
                  OutlinedButton(
                    onPressed: () => _call('exportReport'),
                    child: const Text('Export audio report'),
                  ),
              ],
              ExpansionTile(
                title: const Text('Recent events'),
                children: [
                  SizedBox(
                    height: 240,
                    child: ListView(
                      primary: false,
                      children: [
                        for (final raw
                            in (_state['events'] as List? ?? []).reversed.take(
                              20,
                            ))
                          ListTile(
                            title: Text('${raw['message']}'),
                            subtitle: Text('${raw['at']}'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
