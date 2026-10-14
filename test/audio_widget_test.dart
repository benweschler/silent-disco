import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silent_disco/audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('silent_disco/audio');
  const events = MethodChannel('silent_disco/audio/events');
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });
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

  testWidgets(
    'Host start requires hosting and source controls lock while streaming',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: AudioScreen(isHost: true)),
      );
      final start = find.byKey(const Key('start-audio'));
      await tester.scrollUntilVisible(
        start,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      await emit(tester, {'hosting': true, 'active': false, 'bufferMs': 500});
      await tester.tap(start);
      expect(calls.last.method, 'startStream');
      expect(calls.last.arguments.containsKey('duration'), false);
      await emit(tester, {'hosting': true, 'active': true, 'bufferMs': 500});
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      await tester.scrollUntilVisible(
        find.text('Choose music file'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Choose music file'),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Host offers 1250 ms and explains incompatible listeners', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AudioScreen(isHost: true)));
    await emit(tester, {
      'hosting': true,
      'bufferMs': 1250,
      'listeners': [
        {
          'name': 'Older phone',
          'ready': true,
          'listening': true,
          'compatibilityError':
              'Update this listener or lower the shared lead.',
          'stats': {},
        },
      ],
    });
    await tester.scrollUntilVisible(
      find.text('1250 ms'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('1250 ms'), findsOneWidget);
    await tester.tap(find.text('1250 ms'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1000 ms').last);
    await tester.pumpAndSettle();
    expect(calls.last.method, 'setBuffer');
    expect(calls.last.arguments, {'milliseconds': 1000});
    await tester.scrollUntilVisible(
      find.text('Update this listener or lower the shared lead.'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('Update this listener or lower the shared lead.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Phone gates listening on ready and exposes stop and route', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: AudioScreen(isHost: false)),
    );
    final listen = find.byKey(const Key('listen'));
    expect(tester.widget<FilledButton>(listen).onPressed, isNull);
    await emit(tester, {'ready': true, 'route': 'Test headphones'});
    await tester.tap(listen);
    expect(calls.last.method, 'listen');
    await emit(tester, {
      'ready': true,
      'listening': true,
      'route': 'Test headphones',
      'stats': {'state': 'playing'},
    });
    expect(find.text('Output: Test headphones'), findsOneWidget);
    await tester.tap(find.text('Stop listening'));
    expect(calls.last.method, 'stopListening');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Reports distinguish completion from synchronization evidence', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AudioScreen(isHost: true)));
    await emit(tester, {
      'report': {
        'status': 'completed',
        'assessment': 'needs review',
        'reason': 'stopped by user',
      },
    });
    await tester.scrollUntilVisible(
      find.text('Export audio report'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Assessment: needs review'), findsOneWidget);
    expect(
      find.textContaining('Acoustic synchronization: unverified'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Export audio report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export audio report'));
    expect(calls.last.method, 'exportReport');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Space marks once and does not activate the focused transition button',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: AudioScreen(isHost: true)),
      );
      await emit(tester, {'hosting': true, 'active': true});
      final lock = find.widgetWithText(OutlinedButton, 'Lock phone');
      await tester.tap(lock);
      expect(calls.last.method, 'markTestTransition');
      expect(calls.last.arguments, {'marker': 'lock'});
      Focus.of(tester.element(find.text('Lock phone'))).requestFocus();
      await tester.pump();
      final before = calls.length;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(calls.skip(before).map((c) => c.method).toList(), [
        'markAudibleInterruption',
      ]);
      await emit(tester, {'hosting': true, 'active': false});
      final stopped = calls.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(calls.length, stopped);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Space remains available to modal text entry', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AudioScreen(isHost: true)));
    await emit(tester, {'active': true});
    final screen = tester.element(find.byType(AudioScreen));
    unawaited(
      showDialog<void>(
        context: screen,
        builder: (_) => const AlertDialog(content: TextField(autofocus: true)),
      ),
    );
    await tester.pumpAndSettle();
    final before = calls.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(calls.length, before);
    Navigator.of(screen).pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
