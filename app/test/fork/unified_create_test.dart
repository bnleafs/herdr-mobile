import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/fork/terminal_creation.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/create/new_agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/create_harness.dart';
import '../support/fake_transport.dart';
import '../support/files_support.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/shot.dart' show loadAppFonts;
import '../ui/ui_harness.dart' show attentionSetProvider;

Future<CreateHarness> _buildMultiMachineHarness() async {
  final snap1 = snapshotJson();
  final snap2 = snapshotJson();
  final h = await CreateHarness.create([
    (profile: profileOf('m1', 'fake machine', enabled: true), snapshot: snap1),
    (profile: profileOf('m2', 'offline machine', enabled: false), snapshot: snap2),
  ], waitOnline: false);

  final m1 = h.connection('m1');
  await m1.refresh();

  final stub1 = h.stubs['m1']!;
  stub1.fs = projectFs();

  var nextWs = 1;
  stub1.on['workspace.create'] = (params) {
    final label = (params['label'] as String?) ?? '';
    final wid = 'w_created_${nextWs++}';
    final pid = '$wid:p1';
    final cwd = params['cwd'] as String?;
    final panes = (stub1.snapshot['panes'] as List).cast<Map<String, dynamic>>();
    panes.add({
      'pane_id': pid,
      'workspace_id': wid,
      'tab_id': '$wid:t1',
      'cwd': cwd,
      'agent': null,
      'agent_status': 'idle',
    });
    return {
      'type': 'workspace_created',
      'workspace': {'workspace_id': wid, 'label': label},
      'tab': {'tab_id': '$wid:t1'},
      'root_pane': {'pane_id': pid, 'cwd': cwd},
    };
  };

  stub1.on['tab.create'] = (params) {
    final label = (params['label'] as String?) ?? '';
    final wid = (params['workspace_id'] as String?) ?? 'w1';
    final pid = '$wid:p_tab';
    final cwd = params['cwd'] as String?;
    final panes = (stub1.snapshot['panes'] as List).cast<Map<String, dynamic>>();
    panes.add({
      'pane_id': pid,
      'workspace_id': wid,
      'tab_id': '$wid:t_new',
      'cwd': cwd,
      'agent': null,
      'agent_status': 'idle',
    });
    return {
      'type': 'tab_created',
      'tab': {'tab_id': '$wid:t_new', 'label': label},
      'root_pane': {'pane_id': pid, 'cwd': cwd},
    };
  };

  stub1.on['file.read_dir'] = (params) => {
    'type': 'dir_entries',
    'entries': [
      {'path': '/home/dev/repo', 'name': 'repo', 'kind': 'dir'},
    ],
  };

  return h;
}

Widget _buildTestApp(CreateHarness h) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: h.machines),
      ChangeNotifierProvider.value(value: h.fleet),
      ListenableProvider<AgentSessions>.value(value: h.agents),
      ChangeNotifierProvider.value(value: h.agentSettings),
      ChangeNotifierProvider.value(value: TerminalSettings(MemoryTerminalSettingsStore())),
      ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
      ChangeNotifierProvider(create: (_) => AgentScreens()),
      Provider<PanePreviews>(
        create: (_) => PanePreviews(changes: h.fleet, connection: h.fleet.connection),
        dispose: (_, previews) => previews.dispose(),
      ),
      Provider<TransportFactory>.value(value: (p, s, a, b) => throw StateError('unused')),
      attentionSetProvider(),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
  );
}

Future<void> _pumpApp(WidgetTester tester, CreateHarness h, {Size size = const Size(360, 800)}) async {
  tester.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  await tester.pumpWidget(_buildTestApp(h));
}

Future<void> _tearDownHarness(WidgetTester tester, CreateHarness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  tester.view.reset();
  h.dispose();
}

Finder _chip(String label) => find.widgetWithText(AppChip, label);

bool _selected(WidgetTester tester, String label) => tester.widget<AppChip>(_chip(label)).selected;

void main() {
  setUpAll(loadAppFonts);

  setUp(() {
    resetTerminalCreationLocks();
  });

  group('Branding assertions', () {
    test('app.dart, AndroidManifest.xml, and Info.plist display exact megawatt', () {
      final appDart = File('lib/app.dart').readAsStringSync();
      expect(
        RegExp(r"title: '(?:megawatt|MegaWatt)',").hasMatch(appDart),
        isTrue,
        reason: 'app.dart title must be megawatt',
      );

      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(
        RegExp(r'android:label="(?:megawatt|MegaWatt)"').hasMatch(manifest),
        isTrue,
        reason: 'AndroidManifest label must be megawatt',
      );

      final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(
        RegExp(r'<key>CFBundleDisplayName</key>\s*<string>(?:megawatt|MegaWatt)</string>').hasMatch(infoPlist),
        isTrue,
        reason: 'Info.plist CFBundleDisplayName must be megawatt',
      );
    });

    test('image manifest and launcher asset verification', () {
      final iconBytes = File('assets/icon/icon.png').readAsBytesSync();
      final iconHash = sha256.convert(iconBytes).toString();
      expect(
        iconHash,
        '38f6c64f32219072b3454ac91d46cb8198cf519e1a64a10da29cf0ee94c660a5',
        reason: 'app/assets/icon/icon.png must match exact original source hash',
      );

      final fg = File('assets/icon/icon_foreground.png');
      expect(fg.existsSync(), isTrue);
      expect(fg.lengthSync(), greaterThan(1000));

      final icLauncherXml = File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml').readAsStringSync();
      expect(icLauncherXml.contains('<monochrome>'), isFalse, reason: 'monochrome layer disabled for fork in XML');
      expect(icLauncherXml.contains('<foreground>'), isTrue);
      expect(icLauncherXml.contains('<background'), isTrue);

      expect(File('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png').existsSync(), isTrue);
      expect(File('android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png').existsSync(), isTrue);
      expect(File('ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png').existsSync(), isTrue);
    });
  });

  group('Unified new session form', () {
    testWidgets('Terminal chip present and selectable; hides agent-only parts', (tester) async {
      final h = await _buildMultiMachineHarness();
      h.hosts['m1']!.installed = {'claude', 'codex'};
      await _pumpApp(tester, h);
      await tester.pumpAndSettle();

      // Tap + opens the unified form directly
      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();

      expect(find.byType(NewAgentSessionScreen), findsOneWidget);
      expect(find.text('New session'), findsOneWidget);

      // Claude Code is default selection when installed
      expect(_selected(tester, 'Claude Code'), isTrue);
      expect(_selected(tester, 'Terminal'), isFalse);
      expect(find.text('Past sessions'), findsOneWidget);

      // Terminal chip has terminal icon and is enabled without install check
      final terminalChip = tester.widget<AppChip>(_chip('Terminal'));
      expect(terminalChip.enabled, isTrue);
      expect(terminalChip.icon, LucideIcons.terminal);

      // Select Terminal
      await tester.tap(_chip('Terminal'));
      await tester.pump();

      expect(_selected(tester, 'Terminal'), isTrue);
      expect(_selected(tester, 'Claude Code'), isFalse);

      // Agent-only parts are hidden
      expect(find.text('Past sessions'), findsNothing);
      expect(find.textContaining('Not installed on'), findsNothing);
      expect(find.text('Checking what is installed…'), findsNothing);

      // Start labels remain Start and Start and open
      expect(find.widgetWithText(AppButton, 'Start'), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Start and open'), findsOneWidget);

      // Tapping an agent chip re-selects it and reveals Past sessions
      await tester.tap(_chip('Claude Code'));
      await tester.pump();

      expect(_selected(tester, 'Claude Code'), isTrue);
      expect(_selected(tester, 'Terminal'), isFalse);
      expect(find.text('Past sessions'), findsOneWidget);

      await _tearDownHarness(tester, h);
    });

    testWidgets('Start with Terminal allocates exactly one shell pane in chosen folder and sends zero input', (
      tester,
    ) async {
      final h = await _buildMultiMachineHarness();
      h.hosts['m1']!.installed = {'claude'};
      await _pumpApp(tester, h);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();

      await tester.tap(_chip('Terminal'));
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).first, '/home/dev/repo');
      await tester.pump();

      final stub = h.stubs['m1']!;
      expect(stub.methods.contains('workspace.create'), isFalse);

      await tester.tap(find.widgetWithText(AppButton, 'Start'));
      await tester.pumpAndSettle();

      // Form popped, returned to board
      expect(find.byType(NewAgentSessionScreen), findsNothing);

      // Shell pane created with exact cwd
      final wsCalls = stub.paramsOf('workspace.create');
      expect(wsCalls.length, 1);
      expect(wsCalls.first['cwd'], '/home/dev/repo');
      expect(wsCalls.first['focus'], isFalse);

      // ZERO commands sent
      expect(
        stub.methods.any((m) => m.startsWith('send_') || m == 'tab.write' || m == 'pane.write'),
        isFalse,
        reason: 'zero input or commands sent into terminal',
      );

      // House started toast appeared
      expect(find.textContaining('Terminal started in'), findsOneWidget);

      // Tapping Open on toast opens PaneScreen
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(PaneScreen), findsOneWidget);

      await _tearDownHarness(tester, h);
    });

    testWidgets('Start and open lands on PaneScreen for that pane', (tester) async {
      final h = await _buildMultiMachineHarness();
      h.hosts['m1']!.installed = {'claude'};
      await _pumpApp(tester, h);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();

      await tester.tap(_chip('Terminal'));
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).first, '/home/dev/repo');
      await tester.pump();

      await tester.tap(find.widgetWithText(AppButton, 'Start and open'));
      await tester.pumpAndSettle();

      // Replaces form route and lands on PaneScreen
      expect(find.byType(NewAgentSessionScreen), findsNothing);
      expect(find.byType(PaneScreen), findsOneWidget);

      await _tearDownHarness(tester, h);
    });

    testWidgets('offline machine cannot start', (tester) async {
      final h = await _buildMultiMachineHarness();
      h.connection('m1').goOffline();
      await _pumpApp(tester, h);
      await tester.pumpAndSettle();

      // When all machines are offline, + shows no machine online empty state
      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();

      expect(find.text('No machine is online'), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Start'), findsNothing);

      await _tearDownHarness(tester, h);
    });

    testWidgets('Claude Code still default and still starts as before', (tester) async {
      final h = await _buildMultiMachineHarness();
      h.hosts['m1']!.installed = {'claude', 'codex'};
      await _pumpApp(tester, h);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();

      // Claude Code is default selection
      expect(_selected(tester, 'Claude Code'), isTrue);
      expect(_selected(tester, 'Terminal'), isFalse);

      await tester.enterText(find.byType(TextFormField).first, '/home/dev/repo');
      await tester.pump();

      // Start starts an agent session
      await tester.tap(find.widgetWithText(AppButton, 'Start'));
      await tester.pumpAndSettle();

      expect(h.hosts['m1']!.startCalls, 1);

      await _tearDownHarness(tester, h);
    });
  });
}
