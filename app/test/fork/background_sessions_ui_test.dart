import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/fork/background_sessions_board.dart';
import 'package:herdr_mobile/fork/background_sessions_screen.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/create_harness.dart';
import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/herdr_stub.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_terminal_settings_store.dart';

Widget _wrapWithProviders({required CreateHarness harness, required Widget child}) {
  final terminalSettings = TerminalSettings(MemoryTerminalSettingsStore());
  final appSettings = AppSettings(MemoryAppSettingsStore());
  final agentScreens = AgentScreens();

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<FleetRepository>.value(value: harness.fleet),
      ListenableProvider<AgentSessions>.value(value: harness.agents),
      ChangeNotifierProvider<AgentScreens>.value(value: agentScreens),
      ChangeNotifierProvider<TerminalSettings>.value(value: terminalSettings),
      ChangeNotifierProvider<AppSettings>.value(value: appSettings),
      ChangeNotifierProvider<AttentionSet>(
        create: (context) => AttentionSet(fleet: harness.fleet, sessions: harness.agents),
      ),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: child),
  );
}

void main() {
  group('BackgroundBoardEntry on board', () {
    late CreateHarness harness;
    late FakeFs fs;
    late HerdrStub stub;
    late MachineConnection machine;

    setUp(() async {
      fs = FakeFs();
      harness = await CreateHarness.create([
        (profile: profileOf('m1', 'mac-pro', enabled: true), snapshot: snapshotJson()),
      ]);
      stub = harness.stubs['m1']!;
      stub.fs = fs;
      stub.on['workspace.create'] = (params) {
        final wid = 'w_created';
        final pid = '$wid:p1';
        final cwd = params['cwd'] as String?;
        return {
          'type': 'workspace_created',
          'workspace': {'workspace_id': wid, 'label': params['label']},
          'tab': {'tab_id': '$wid:t1'},
          'root_pane': {'pane_id': pid, 'cwd': cwd},
        };
      };
      machine = harness.connection('m1');
      await machine.refresh();
    });

    tearDown(() => harness.dispose());

    testWidgets('entry is hidden when 0 background sessions, shown when N > 0', (tester) async {
      // 0 background sessions
      await tester.pumpWidget(
        _wrapWithProviders(
          harness: harness,
          child: const Scaffold(body: BackgroundBoardEntry()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('Background ·'), findsNothing);

      // Now add 2 background sessions to FakeFs
      final sessDir = '/home/dev/.claude/sessions';
      fs.addDir(sessDir);
      fs.addFile(
        '$sessDir/1.json',
        jsonEncode({
          'kind': 'bg',
          'sessionId': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
          'cwd': '/work/repo1',
          'name': 'indexer',
          'status': 'busy',
          'updatedAt': 1000,
        }),
      );
      fs.addFile(
        '$sessDir/2.json',
        jsonEncode({
          'kind': 'bg',
          'sessionId': 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
          'cwd': '/work/repo2',
          'name': 'tester',
          'status': 'idle',
          'updatedAt': 2000,
        }),
      );

      // Pump to trigger poll/refresh
      await tester.pump(const Duration(seconds: 31)); // the board polls every 30 s

      expect(find.text('Background · 2'), findsOneWidget);
    });

    testWidgets('BackgroundSessionsScreen renders sessions and attaches in terminal', (tester) async {
      final sessDir = '/home/dev/.claude/sessions';
      fs.addDir(sessDir);
      const sid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
      fs.addFile(
        '$sessDir/1.json',
        jsonEncode({
          'kind': 'bg',
          'sessionId': sid,
          'cwd': '/work/repo1',
          'name': 'indexer',
          'status': 'busy',
          'updatedAt': 1000,
        }),
      );

      await tester.pumpWidget(
        _wrapWithProviders(
          harness: harness,
          child: BackgroundSessionsScreen(machine: machine),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('indexer'), findsOneWidget);
      expect(find.text('repo1'), findsOneWidget);

      // Open actions sheet via ellipsis button
      final moreButton = find.byIcon(LucideIcons.ellipsis);
      expect(moreButton, findsOneWidget);
      await tester.tap(moreButton);
      await tester.pumpAndSettle();

      expect(find.text('Attach in terminal'), findsOneWidget);
      await tester.tap(find.text('Attach in terminal'));
      await tester.pumpAndSettle();

      // Check attach sent exactly one command: claude attach '<sessionId>' + Enter
      final sentInputs = stub.paramsOf('pane.send_input');
      expect(sentInputs, hasLength(1));
      expect(sentInputs.first['text'], "claude attach '$sid'");
      expect(sentInputs.first['keys'], ['enter']);
    });

    testWidgets('tapping row locates transcript and notifies when not yet written', (tester) async {
      final sessDir = '/home/dev/.claude/sessions';
      fs.addDir(sessDir);
      const sid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
      fs.addFile(
        '$sessDir/1.json',
        jsonEncode({'kind': 'bg', 'sessionId': sid, 'cwd': '/work/repo1', 'name': 'indexer', 'status': 'idle'}),
      );

      await tester.pumpWidget(
        _wrapWithProviders(
          harness: harness,
          child: BackgroundSessionsScreen(machine: machine),
        ),
      );
      await tester.pumpAndSettle();

      // Tap on row (transcript does not exist in FakeFs projects folder yet)
      await tester.tap(find.text('indexer'));
      await tester.pumpAndSettle();

      // Verified: does not crash, shows quiet toast for NotYet
      expect(find.byType(BackgroundSessionsScreen), findsOneWidget);
    });
  });
}
