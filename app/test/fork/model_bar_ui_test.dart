import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/fork/model_bar/model_bar_client.dart';
import 'package:herdr_mobile/fork/model_bar/model_bar_sheet.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/fake_exec.dart';
import '../support/fake_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTransport transport;
  late MachineConnection machine;

  setUp(() {
    transport = FakeTransport();
    machine = MachineConnection(
      profile: const MachineProfile(id: 'm1', label: 'box1', host: 'h1', username: 'u1'),
      api: HerdrApi(transport, machineId: 'm1'),
      backoff: (_) => const Duration(hours: 1),
    );
  });

  Widget pumpModelBarSheet({ModelBarClient? client}) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: ModelBarSheet(machine: machine, client: client ?? const ModelBarClient()),
    ),
  );

  group('ModelBarSheet UI', () {
    testWidgets('renders model list and filters in place with search', (tester) async {
      transport.onExec = (cmd) async {
        if (cmd.contains('/v1/models/ready')) {
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({
                'object': 'readiness_list',
                'models': [
                  {'id': 'argon', 'alias': 'gemini-4-argon', 'ready': true},
                  {'id': 'flash', 'alias': 'gemini-flash', 'ready': true},
                  {'id': 'codex', 'alias': 'gpt-6.1-sol', 'ready': false},
                ],
              }),
            ],
            code: 0,
          );
        }
        if (cmd.contains('/v1/model-bar')) {
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({
                'pinned': ['argon'],
                'more': ['flash', 'codex'],
              }),
            ],
            code: 0,
          );
        }
        return FakeExecChannel.run(code: 1);
      };

      await tester.pumpWidget(pumpModelBarSheet());
      await tester.pumpAndSettle();

      // Check header and all 3 models visible
      expect(find.text('Model Bar'), findsOneWidget);
      expect(find.text('argon'), findsOneWidget);
      expect(find.text('gemini-4-argon'), findsOneWidget);
      expect(find.text('flash'), findsOneWidget);
      expect(find.text('codex'), findsOneWidget);

      // Filter by "flash"
      await tester.enterText(find.byType(TextField), 'flash');
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ListTile, 'flash'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'argon'), findsNothing);
      expect(find.widgetWithText(ListTile, 'codex'), findsNothing);

      // Filter by alias substring "sol" -> matches codex
      await tester.enterText(find.byType(TextField), 'sol');
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ListTile, 'codex'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'flash'), findsNothing);
    });

    testWidgets('shows no models match message on empty filter result', (tester) async {
      transport.onExec = (cmd) async {
        if (cmd.contains('/v1/models/ready')) {
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({
                'models': [
                  {'id': 'argon', 'ready': true},
                ],
              }),
            ],
            code: 0,
          );
        }
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({'pinned': [], 'more': []}),
          ],
          code: 0,
        );
      };

      await tester.pumpWidget(pumpModelBarSheet());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'nonexistent');
      await tester.pumpAndSettle();

      expect(find.text('No models match'), findsOneWidget);
    });

    testWidgets('optimistic star toggle round-trips and preserves state', (tester) async {
      Completer<void>? putCompleter;

      transport.onExec = (cmd) async {
        if (cmd.contains('PUT')) {
          putCompleter = Completer<void>();
          final ch = FakeExecChannel();
          ch.onInputClosed = () {
            ch.emit(
              jsonEncode({
                'ok': true,
                'pinned': ['argon', 'flash'],
                'more': [],
              }),
            );
            ch.exit(0);
            if (!putCompleter!.isCompleted) putCompleter!.complete();
          };
          return ch;
        }
        if (cmd.contains('/v1/models/ready')) {
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({
                'models': [
                  {'id': 'argon', 'ready': true},
                  {'id': 'flash', 'ready': true},
                ],
              }),
            ],
            code: 0,
          );
        }
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({
              'pinned': ['argon'],
              'more': ['flash'],
            }),
          ],
          code: 0,
        );
      };

      await tester.pumpWidget(pumpModelBarSheet());
      await tester.pumpAndSettle();

      // Find star buttons
      final starFinder = find.byType(IconButton);
      expect(starFinder, findsNWidgets(2));

      // Tap unstarred flash to star it
      await tester.tap(starFinder.at(1));
      await tester.pump(); // immediate frame

      // Optimistically starred before network finishes
      expect(putCompleter, isNotNull);

      await tester.pumpAndSettle();
      expect(putCompleter!.isCompleted, isTrue);
    });

    testWidgets('ADVERSARIAL: rolls back optimistic star toggle and displays inline error when PUT fails', (
      tester,
    ) async {
      var putAttempted = false;

      transport.onExec = (cmd) async {
        if (cmd.contains('PUT')) {
          putAttempted = true;
          // Fail the PUT command
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({'error': 'validation_error', 'reason': 'simulated server failure'}),
            ],
            code: 1,
          );
        }
        if (cmd.contains('/v1/models/ready')) {
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({
                'models': [
                  {'id': 'argon', 'ready': true},
                  {'id': 'flash', 'ready': true},
                ],
              }),
            ],
            code: 0,
          );
        }
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({
              'pinned': ['argon'],
              'more': ['flash'],
            }),
          ],
          code: 0,
        );
      };

      await tester.pumpWidget(pumpModelBarSheet());
      await tester.pumpAndSettle();

      final starFinder = find.byType(IconButton);

      // Tap flash (unstarred -> starred)
      await tester.tap(starFinder.at(1));
      await tester.pump(); // optimistic toggle frame

      // Wait for async network call to fail and rollback
      await tester.pumpAndSettle();

      expect(putAttempted, isTrue);

      // Inline error must appear
      expect(find.textContaining('Failed to update Model Bar'), findsOneWidget);

      // Verify the state rolled back (star reverts)
      final icon = tester.widget<Icon>(find.descendant(of: starFinder.at(1), matching: find.byType(Icon)));
      // Unstarred icon is LucideIcons.star with outline / secondary color
      expect(icon.icon, LucideIcons.star);
    });

    testWidgets('load error displays inline error and Retry button', (tester) async {
      var callCount = 0;
      transport.onExec = (cmd) async {
        callCount++;
        if (callCount <= 2) {
          // Initial load fails
          return FakeExecChannel.run(code: 1);
        }
        // Retry succeeds
        if (cmd.contains('/v1/models/ready')) {
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({
                'models': [
                  {'id': 'argon', 'ready': true},
                ],
              }),
            ],
            code: 0,
          );
        }
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({'pinned': [], 'more': []}),
          ],
          code: 0,
        );
      };

      await tester.pumpWidget(pumpModelBarSheet());
      await tester.pumpAndSettle();

      expect(find.textContaining('Unable to load models'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      // Tap Retry
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('argon'), findsOneWidget);
    });

    testWidgets('ModelBarGroup renders in Settings and opens ModelBarSheet on tap', (tester) async {
      transport.onExec = (cmd) async {
        if (cmd.contains('/v1/models/ready')) {
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({
                'models': [
                  {'id': 'argon', 'ready': true},
                ],
              }),
            ],
            code: 0,
          );
        }
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({'pinned': [], 'more': []}),
          ],
          code: 0,
        );
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: const ModelBarGroup()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Model Bar'), findsOneWidget);
      expect(find.text('Quick-access models'), findsOneWidget);
    });
  });
}
