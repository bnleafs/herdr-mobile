import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/fork/home_creation.dart';
import 'package:herdr_mobile/fork/terminal_creation.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agents/agents_screen.dart';
import 'package:herdr_mobile/ui/features/create/new_agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
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

  stub1.on['file.read_dir'] = (params) => {
    'type': 'dir_entries',
    'entries': [
      {'path': '/home/dev/repo', 'name': 'repo', 'kind': 'dir'},
    ],
  };

  return h;
}

Future<CreateHarness> _buildSingleMachineHarness() async {
  final snap = snapshotJson();
  final h = await CreateHarness.create([
    (profile: profileOf('m1', 'solo machine', enabled: true), snapshot: snap),
  ], waitOnline: false);

  final m1 = h.connection('m1');
  await m1.refresh();

  final stub = h.stubs['m1']!;
  stub.fs = projectFs();

  stub.on['file.read_dir'] = (params) => {
    'type': 'dir_entries',
    'entries': [
      {'path': '/home/dev/project', 'name': 'project', 'kind': 'dir'},
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

Future<void> _tearDownHarness(WidgetTester tester, CreateHarness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  h.dispose();
}

void main() {
  setUpAll(loadAppFonts);

  setUp(() {
    resetHomeCreationLocks();
    resetTerminalCreationLocks();
  });

  group('Branding assertions', () {
    test('app.dart, AndroidManifest.xml, and Info.plist display exact megawatt', () {
      final appDart = File('lib/app.dart').readAsStringSync();
      expect(appDart.contains("title: 'megawatt',"), isTrue, reason: 'app.dart title must be megawatt');

      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest.contains('android:label="megawatt"'), isTrue, reason: 'AndroidManifest label must be megawatt');

      final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(
        infoPlist.contains('<key>CFBundleDisplayName</key>\n\t<string>megawatt</string>'),
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

  group('Home creation journey', () {
    testWidgets('actual + tap shows Terminal and Agent session in creation chooser', (tester) async {
      final h = await _buildMultiMachineHarness();
      await tester.pumpWidget(_buildTestApp(h));
      await tester.pumpAndSettle();

      expect(find.byTooltip('New agent session').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();

      expect(find.text('New'), findsOneWidget);
      expect(find.text('Agent session'), findsOneWidget);
      expect(find.text('Terminal'), findsOneWidget);

      await _tearDownHarness(tester, h);
    });

    testWidgets('choose actual fake machine opens existing folder picker', (tester) async {
      final h = await _buildMultiMachineHarness();
      await tester.pumpWidget(_buildTestApp(h));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();

      expect(find.text('Machine'), findsOneWidget);
      expect(find.text('fake machine'), findsOneWidget);

      await tester.tap(find.text('fake machine'));
      await tester.pumpAndSettle();

      expect(find.byType(FileBrowserScreen), findsOneWidget);
      expect(find.text('Choose this folder'), findsOneWidget);

      await _tearDownHarness(tester, h);
    });

    testWidgets('cancel creates nothing', (tester) async {
      final h = await _buildMultiMachineHarness();
      await tester.pumpWidget(_buildTestApp(h));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('fake machine'));
      await tester.pumpAndSettle();

      expect(find.byType(FileBrowserScreen), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentsScreen), findsOneWidget);
      expect(h.stubs['m1']!.methods.contains('workspace.create'), isFalse);
      expect(h.stubs['m1']!.methods.contains('tab.create'), isFalse);

      await _tearDownHarness(tester, h);
    });

    testWidgets('offline terminal unavailable no mutations', (tester) async {
      final h = await _buildMultiMachineHarness();
      await tester.pumpWidget(_buildTestApp(h));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();

      expect(find.text('offline machine'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);

      await tester.tap(find.text('offline machine'));
      await tester.pumpAndSettle();

      expect(find.byType(FileBrowserScreen), findsNothing);
      expect(h.stubs['m2']!.methods, isEmpty);

      await _tearDownHarness(tester, h);
    });

    testWidgets('agent creation still reaches existing route', (tester) async {
      final h = await _buildMultiMachineHarness();
      await tester.pumpWidget(_buildTestApp(h));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Agent session'));
      await tester.pumpAndSettle();

      expect(find.byType(NewAgentSessionScreen), findsOneWidget);

      await _tearDownHarness(tester, h);
    });

    testWidgets('success returns real PaneScreen matching machine+pane and sends zero commands', (tester) async {
      final h = await _buildMultiMachineHarness();
      await tester.pumpWidget(_buildTestApp(h));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('fake machine'));
      await tester.pumpAndSettle();

      expect(find.text('Choose this folder'), findsOneWidget);
      await tester.tap(find.text('Choose this folder'));
      await tester.pumpAndSettle();

      expect(find.byType(PaneScreen), findsOneWidget);

      final m1Methods = h.stubs['m1']!.methods;
      expect(m1Methods.contains('workspace.create'), isTrue);
      expect(
        m1Methods.any((m) => m.startsWith('send_') || m == 'tab.write' || m == 'pane.write'),
        isFalse,
        reason: 'never send startup commands into plain terminal',
      );

      await _tearDownHarness(tester, h);
    });

    testWidgets('creation failure toast original screen retained', (tester) async {
      final h = await _buildMultiMachineHarness();
      h.stubs['m1']!.on['workspace.create'] = (params) {
        throw const HerdrTransportException('Failed to allocate pane', fatal: false);
      };

      await tester.pumpWidget(_buildTestApp(h));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('fake machine'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Choose this folder'));
      await tester.pumpAndSettle();

      expect(find.byType(PaneScreen), findsNothing);
      expect(find.byType(AgentsScreen), findsOneWidget);

      await _tearDownHarness(tester, h);
    });

    testWidgets('auto-select machine only if existing UX convention (single online machine)', (tester) async {
      final h = await _buildSingleMachineHarness();
      await tester.pumpWidget(_buildTestApp(h));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New agent session'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();

      expect(find.byType(FileBrowserScreen), findsOneWidget);
      expect(find.text('Choose this folder'), findsOneWidget);

      await _tearDownHarness(tester, h);
    });
  });
}
