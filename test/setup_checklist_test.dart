import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:justice_chain/presentation/guide_screens.dart';

void main() {
  HealthItem item(bool ok) => HealthItem(title: 't', ok: ok, detail: 'd', icon: Icons.check);

  test('counts what is done; complete only when nothing is left', () {
    expect(SafetySetup.progress([item(true), item(false), item(true)]), (done: 2, total: 3));
    final all = SafetySetup.progress([item(true), item(true)]);
    expect(all.done == all.total, isTrue);
  });

  test('guardians: done at two, with a hint for none and for one', () {
    expect(SafetySetup.guardiansItem(0).ok, isFalse);
    expect(SafetySetup.guardiansItem(0).detail, 'Add 2 people you trust');
    expect(SafetySetup.guardiansItem(1).ok, isFalse);
    expect(SafetySetup.guardiansItem(1).detail, '1 paired; add 1 more so a clip can be opened');
    expect(SafetySetup.guardiansItem(2).ok, isTrue);
    expect(SafetySetup.guardiansItem(3).detail, '3 paired');
  });

  test('recovery code: done once written down, and both have a screen to fix them', () {
    expect(SafetySetup.recoveryCodeItem(saved: true).ok, isTrue);
    expect(SafetySetup.recoveryCodeItem(saved: false).ok, isFalse);
    expect(SafetySetup.recoveryCodeItem(saved: false).fix, isNotNull);
    expect(SafetySetup.guardiansItem(0).fix, isNotNull);
  });
}
