import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/core/evidence_lock.dart';
import 'package:justice_chain/core/identity_service.dart';
import 'package:justice_chain/presentation/pin_gate.dart';

// Recordings stay behind the vault PIN (judge review finding S5).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    IdentityService.resetCacheForTest();
    EvidenceLock.resetForTest();
  });

  Future<void> registerWithPin() => IdentityService.registerNode(name: 'sara', pin: '2468');

  group('EvidenceLock', () {
    test('the right PIN unlocks for five minutes, then it locks itself', () async {
      await registerWithPin();
      var clock = DateTime(2026, 10, 26, 12);
      EvidenceLock.now = () => clock;

      expect(EvidenceLock.isUnlocked, isFalse);
      expect(await EvidenceLock.unlock('1357'), isFalse);
      expect(await EvidenceLock.unlock('2468'), isTrue);
      expect(EvidenceLock.isUnlocked, isTrue);

      clock = clock.add(const Duration(minutes: 4, seconds: 59));
      expect(EvidenceLock.isUnlocked, isTrue);
      clock = clock.add(const Duration(seconds: 2));
      expect(EvidenceLock.isUnlocked, isFalse);
    });

    test('lock() closes it at once', () async {
      await registerWithPin();
      await EvidenceLock.unlock('2468');
      EvidenceLock.lock();
      expect(EvidenceLock.isUnlocked, isFalse);
    });

    testWidgets('leaving the app locks it, whichever screen was open', (tester) async {
      await tester.runAsync(registerWithPin);
      await tester.runAsync(() => EvidenceLock.unlock('2468'));
      EvidenceLock.lockWhenAppLeaves();
      expect(EvidenceLock.isUnlocked, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(EvidenceLock.isUnlocked, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    test('five wrong PINs block every try, even the right one, for 30 s', () async {
      await registerWithPin();
      var clock = DateTime(2026, 10, 26, 12);
      EvidenceLock.now = () => clock;

      for (var i = 0; i < EvidenceLock.maxTries; i++) {
        expect(await EvidenceLock.unlock('0000'), isFalse);
      }
      expect(EvidenceLock.waitBeforeNextTry, EvidenceLock.lockout);
      expect(await EvidenceLock.unlock('2468'), isFalse);

      clock = clock.add(EvidenceLock.lockout);
      expect(await EvidenceLock.unlock('2468'), isTrue);
    });
  });

  group('PinGate', () {
    Widget app() => const MaterialApp(home: PinGate(child: Text('My evidence')));

    testWidgets('asks for the PIN before showing recordings', (tester) async {
      await tester.runAsync(registerWithPin);
      await tester.pumpWidget(app());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();

      expect(find.text('Enter your PIN'), findsOneWidget);
      expect(find.text('My evidence'), findsNothing);
    });

    testWidgets('an unlocked session opens straight away, and leaving the app locks it', (tester) async {
      await tester.runAsync(registerWithPin);
      await tester.runAsync(() => EvidenceLock.unlock('2468'));
      await tester.pumpWidget(app());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.text('My evidence'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Back to the app: a paused app draws no frames, so check after resuming.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(find.text('My evidence'), findsNothing);
      expect(find.text('Enter your PIN'), findsOneWidget);
      expect(EvidenceLock.isUnlocked, isFalse);
    });

    testWidgets('a phone with no PIN is never locked', (tester) async {
      await tester.pumpWidget(app());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.text('My evidence'), findsOneWidget);
    });
  });
}
