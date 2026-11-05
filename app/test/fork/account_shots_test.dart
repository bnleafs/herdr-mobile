// ACCOUNT_SHOTS=1 flutter test --experimental-faster-testing test/fork/
// Writes the account recovery states to /tmp/slice6-account-shots.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/fork/account/account_screen.dart';
import 'package:herdr_mobile/fork/account/account_session.dart';
import 'package:herdr_mobile/fork/account/account_vault.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_exec.dart';
import '../support/fake_transport.dart';
import '../support/shot.dart' show loadAppFonts, shoot;
import 'account_regression_test.dart' show repository, savedSession, FailingStore;
import 'account_session_test.dart' show MemoryAccountSessionStore;

void main() {
  if (Platform.environment['ACCOUNT_SHOTS'] == null) {
    test('account shots are off', () {}, skip: 'set ACCOUNT_SHOTS=1');
    return;
  }
  const out = '/tmp/slice6-account-shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });
  for (final state in ['signed-out', 'synced', 'pull-failed', 'sign-out-failed']) {
    for (final brightness in Brightness.values) {
      for (final size in [const Size(412, 892), const Size(320, 640), const Size(892, 412)]) {
        for (final scale in [1.0, 1.6]) {
          testWidgets('$state ${brightness.name} ${size.width} x$scale', (tester) async {
            SharedPreferences.setMockInitialValues(state == 'pull-failed' ? {} : {localInitializedKey: true});
            final repo = await repository();
            final store = state == 'sign-out-failed' ? FailingStore() : MemoryAccountSessionStore();
            if (state != 'signed-out') {
              store.values.addAll((await savedSession(computeSnapshotDigest(const VaultContents()))).values);
            }
            final box = FakeTransport()..onExec = (_) async => FakeExecChannel.run(code: 1);
            final session = AccountSession(machines: repo, sessionStore: store, connect: (p, s, pin, n) => box);
            addTearDown(session.dispose);
            await tester.runAsync(session.init);
            if (state == 'sign-out-failed') await tester.runAsync(session.signOut);
            await shoot(
              tester,
              Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                  child: const AccountScreen(),
                ),
              ),
              '$out/$state-${brightness.name}-${size.width.toInt()}-x$scale.png',
              brightness: brightness,
              size: size,
              imageScale: 1,
              wrap: (app) => ChangeNotifierProvider.value(value: session, child: app),
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          });
        }
      }
    }
  }
}
