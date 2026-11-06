// Fork F11: the chat never shows the raw "Live from terminal" rows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../support/fake_agent_session.dart';

void main() {
  testWidgets('a quietly working terminal agent shows no "Live from terminal" panel (fork F11)', (tester) async {
    final session = FakeAgentSession(title: 'Quiet work', state: stateWith(turnActive: true))
      ..observed = true
      ..paneId = 'w1:p1'
      ..live = ['npm test'];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: AgentSessionScreen(key: ObjectKey(session), session: session),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Live from terminal'), findsNothing);
    expect(find.text('npm test'), findsNothing);
  });
}
