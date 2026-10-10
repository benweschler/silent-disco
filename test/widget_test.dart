import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silent_disco/diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('silent_disco/diagnostics');
  const events = MethodChannel('silent_disco/diagnostics/events');
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> emit(WidgetTester tester, Map<String, dynamic> state) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(state),
      (_) => done.complete(),
    );
    await done.future;
    await tester.pump();
  }

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (call) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  testWidgets('Host starts server and gates tests on UDP readiness', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: DiagnosticsScreen(isHost: true)),
    );
    await tester.tap(find.text('Start server'));
    expect(calls.single.method, 'startHost');
    final start = find.byKey(const Key('start-test'));
    await tester.scrollUntilVisible(
      start,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    await emit(tester, {'status': 'connected', 'ready': true, 'hosting': true});
    await tester.ensureVisible(start);
    await tester.tap(start);
    expect(calls.last.method, 'startTest');
    expect(calls.last.arguments['profile'], 'connectivity');
    expect(calls.last.arguments.containsKey('duration'), isFalse);
    await emit(tester, {
      'status': 'connected',
      'ready': true,
      'active': true,
      'phase': 'running',
      'elapsed': 1,
      'duration': 30,
    });
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Phone discovery sends selected endpoint and shows interruption',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: DiagnosticsScreen(isHost: false)),
      );
      await tester.tap(find.text('Find hubs / retry'));
      expect(calls.last.method, 'browse');
      await emit(tester, {
        'status': 'discovering',
        'services': [
          {'id': 'hub1', 'name': 'Test hub'},
        ],
      });
      await tester.tap(find.text('Connect'));
      expect(calls.last.arguments, {'id': 'hub1'});
      await emit(tester, {
        'status': 'disconnected',
        'phase': 'interrupted',
        'error': 'App backgrounded or phone locked',
      });
      expect(find.text('App backgrounded or phone locked'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('run-status')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Run: interrupted'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Completed report is exportable and does not claim offline proof',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: DiagnosticsScreen(isHost: true)),
      );
      await emit(tester, {
        'phase': 'completed',
        'report': {
          'status': 'completed',
          'networkGate': 'pass',
          'reason': 'completed',
          'offlineSetupUserConfirmed': false,
        },
      });
      await tester.scrollUntilVisible(
        find.text('Export JSON report'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Offline setup user-confirmed: no'), findsOneWidget);
      await tester.tap(find.text('Export JSON report'));
      expect(calls.last.method, 'exportReport');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
