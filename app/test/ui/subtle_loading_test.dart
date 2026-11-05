import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/fork/continuity_presentation.dart';
import 'package:herdr_mobile/ui/core/glyphs.dart';
import 'package:herdr_mobile/ui/core/motion.dart';
import 'package:herdr_mobile/ui/core/status_panel.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../support/fake_agent_session.dart';
import 'ui_harness.dart';

void main() {
  group('SubtleLoadingIndicator unit tests', () {
    testWidgets('fast connect (< grace) shows no visual indicator, but announces via semantics', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SubtleLoadingIndicator(title: 'Connecting…')),
        ),
      );

      // Immediately: 0ms (< Dwell.connectGrace)
      expect(find.text('Connecting…'), findsNothing);
      expect(find.byType(StatusStrip), findsNothing);
      // Accessible semantics label is present immediately
      expect(
        find.descendant(of: find.byType(SubtleLoadingIndicator), matching: find.bySemanticsLabel('Connecting…')),
        findsOneWidget,
      );

      // Advance halfway through grace period: 400ms (< 800ms)
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Connecting…'), findsNothing);
    });

    testWidgets('slow connect (>= grace) shows subtle inline indicator in ds.textTertiary with no banner', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SubtleLoadingIndicator(
              title: 'Updating…',
              leading: LinkDot(state: LinkState.connecting, size: 8),
            ),
          ),
        ),
      );

      await tester.pump(Dwell.connectGrace);

      // Now visible
      expect(find.text('Updating…'), findsOneWidget);
      expect(find.byType(StatusStrip), findsNothing); // Never uses large StatusStrip banner

      final BuildContext context = tester.element(find.text('Updating…'));
      final textWidget = tester.widget<Text>(find.text('Updating…'));
      expect(textWidget.style?.color, context.ds.textTertiary);

      // Leading LinkDot is present and uses neutral tertiary color
      final dotFinder = find.descendant(of: find.byType(SubtleLoadingIndicator), matching: find.byType(LinkDot));
      expect(dotFinder, findsOneWidget);
      final dotWidget = tester.widget<LinkDot>(dotFinder);
      expect(dotWidget.colorIn(context.ds), context.ds.textTertiary);
    });
  });

  group('LinkStateColor and amber reservation', () {
    testWidgets('connecting and reconnecting use ds.textTertiary and never ds.working; working agent keeps amber', (
      tester,
    ) async {
      await tester.pumpWidget(MaterialApp(theme: AppTheme.dark(), home: const SizedBox()));
      final ds = tester.element(find.byType(SizedBox)).ds;

      expect(LinkState.connecting.color(ds), ds.textTertiary);
      expect(LinkState.reconnecting.color(ds), ds.textTertiary);
      expect(LinkState.connecting.color(ds), isNot(ds.working));
      expect(LinkState.reconnecting.color(ds), isNot(ds.working));

      // Amber stays strictly reserved for agents that are working
      expect(AgentStatus.working.color(ds), ds.working);
      expect(AgentStatus.working.color(ds), isNot(ds.textTertiary));

      // Failure / attention keeps its blocked/danger prominence
      expect(LinkState.attention.color(ds), ds.blocked);
      expect(LinkState.approval.color(ds), ds.blocked);
    });
  });

  group('AgentSessionScreen subtle loading vs failure prominence', () {
    testWidgets('fast connect (< grace) shows nothing, slow connect shows subtle indicator, cached copy visible', (
      tester,
    ) async {
      final session = FakeAgentSession(
        state: stateWith(items: [userMsg('u1', 'Fix the layout bug'), agentMsg('a1', 'Looking into the issue.')]),
        link: AgentLink.connecting,
      )..cachedAsOfValue = DateTime.now().subtract(const Duration(minutes: 2));

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: AgentSessionScreen(key: ObjectKey(session), session: session),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // Cached content stays fully visible underneath
      expect(find.textContaining('Fix the layout bug', findRichText: true), findsOneWidget);
      expect(find.textContaining('Looking into the issue.', findRichText: true), findsOneWidget);

      // Fast connect (< grace): no visible indicator
      expect(find.descendant(of: find.byType(SubtleLoadingIndicator), matching: find.text('Updating…')), findsNothing);
      expect(find.byType(StatusStrip), findsNothing);

      // Slow connect (>= grace): subtle indicator appears
      await tester.pump(Dwell.connectGrace);
      expect(
        find.descendant(of: find.byType(SubtleLoadingIndicator), matching: find.text('Updating…')),
        findsOneWidget,
      );
      expect(find.byType(StatusStrip), findsNothing);

      // Connecting succeeds fast: indicator goes away, cached content stays
      session.setLink(AgentLink.live);
      await tester.pump();
      await tester.pump(Motion.expand);
      expect(find.byType(SubtleLoadingIndicator), findsNothing);
      expect(find.byType(StatusStrip), findsNothing);
      expect(find.textContaining('Fix the layout bug', findRichText: true), findsOneWidget);
    });

    testWidgets('failed connect shows attention strip with prominence and Retry button immediately', (tester) async {
      final session = FakeAgentSession(link: AgentLink.failed);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: AgentSessionScreen(key: ObjectKey(session), session: session),
        ),
      );
      await tester.pump();

      // Attention strip is immediate (no grace delay) and prominent (StatusStrip)
      expect(find.byType(StatusStrip), findsOneWidget);
      expect(find.text('Couldn’t connect'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('reconnecting without error uses subtle loading and never ds.working', (tester) async {
      final session = FakeAgentSession(link: AgentLink.reconnecting);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: AgentSessionScreen(key: ObjectKey(session), session: session),
        ),
      );
      await tester.pump();

      // Fast reconnect (< grace): no visible text
      expect(
        find.descendant(of: find.byType(SubtleLoadingIndicator), matching: find.text('Reconnecting…')),
        findsNothing,
      );
      expect(find.byType(StatusStrip), findsNothing);

      // After grace delay
      await tester.pump(Dwell.connectGrace);
      expect(
        find.descendant(of: find.byType(SubtleLoadingIndicator), matching: find.text('Reconnecting…')),
        findsOneWidget,
      );
      expect(find.byType(StatusStrip), findsNothing);

      final BuildContext context = tester.element(find.text('Reconnecting…'));
      final textWidget = tester.widget<Text>(find.text('Reconnecting…'));
      expect(textWidget.style?.color, context.ds.textTertiary);
      expect(textWidget.style?.color, isNot(context.ds.working));
    });
  });

  group('continuity presentation transient connect', () {
    test('isTransientReconnect returns true for connecting with retained data and no error', () async {
      final h = await UiHarness.create([
        (
          profile: MachineProfile(id: 'm1', label: 'box1', host: 'h', username: 'u'),
          snapshot: snapshotWith(_agents(2)),
        ),
      ]);
      addTearDown(h.dispose);
      final c = h.fleet.connection('m1')!;

      // Machine connection suspended transiently has retained data
      c.suspend();
      expect(isTransientReconnect(c), isTrue);

      // Subtitle lead formats honest Updating
      expect(machineSubtitleLead(machine: c, profile: c.profile, agents: 2), '2 agents · Updating');
    });
  });
}

List<Pane> _agents(int count) => [
  for (var i = 1; i <= count; i++) (id: 'w1:p$i', ws: 'w1', agent: 'omp', status: 'working'),
];
