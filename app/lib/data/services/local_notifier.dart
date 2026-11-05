import 'dart:async';
import 'dart:isolate' show ReceivePort;
import 'dart:ui' show Color, DartPluginRegistrant, IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../words/plural.dart';
import 'notifier.dart';

/// The drawable in `android/app/src/main/res/drawable`, kept by `raw/keep.xml`.
const _smallIcon = 'ic_stat_megawatt';

/// The large icon in notifications, kept by `raw/keep.xml`.
const _largeIcon = DrawableResourceAndroidBitmap('ic_megawatt_large');

const _needsYouChannel = AndroidNotificationChannel(
  'needs_you',
  'Agents that need you',
  description: 'An agent is blocked on a question and waits for you.',
  importance: Importance.high,
);

const _finishedChannel = AndroidNotificationChannel(
  'finished',
  'Agents that are done',
  description: 'An agent is done with its work.',
  importance: Importance.defaultImportance,
  playSound: false,
  enableVibration: false,
);

const _watchingChannel = AndroidNotificationChannel(
  watchingChannelId,
  'Watching',
  description: 'A quiet notice while agents work or a page from a machine is open, so Android keeps the connection to your machines alive.',
  importance: Importance.min,
  playSound: false,
  enableVibration: false,
  showBadge: false,
);

/// The channel of the "Watching N agents" notice; it is never cancelled with
/// the agent notifications.
@visibleForTesting
const watchingChannelId = 'watching';

/// The id of the foreground notice. Agent ids come from [notificationIdFor]
/// (31 bits of a hash); a collision with this one is a 1 in 2 billion event.
@visibleForTesting
const watchingNotificationId = 1;

/// The name the main isolate registers a port under (`IsolateNameServer`), to
/// hear of the answer buttons pressed on a notification. Android runs a plain
/// action's callback in another isolate of the process; that isolate looks the
/// port up and forwards the press, because only the main isolate has the
/// connections to answer through.
@visibleForTesting
const answerPortName = 'dev.herdrmobile/notification-answers';

/// The text a notification shows when an answer was not sent.
const _notSentBody = 'Nothing was sent. Tap to open the agent and see its question.';

AndroidNotificationDetails _details(
  AndroidNotificationChannel channel, {
  required bool loud,
  Color? accent,
  List<AndroidNotificationAction>? actions,
  StyleInformation? style,
}) => AndroidNotificationDetails(
  channel.id,
  channel.name,
  channelDescription: channel.description,
  importance: channel.importance,
  priority: loud ? Priority.high : Priority.defaultPriority,
  playSound: channel.playSound,
  enableVibration: channel.enableVibration,
  icon: _smallIcon,
  largeIcon: _largeIcon,
  color: accent,
  groupKey: 'agents',
  autoCancel: true,
  onlyAlertOnce: true,
  when: DateTime.now().millisecondsSinceEpoch,
  actions: actions,
  styleInformation: style,
);

/// Says that an answer was not sent, under the notification's own id, with the
/// agent's link as its tap.
Future<void> _postNotSent(AndroidFlutterLocalNotificationsPlugin android, int id, String? link) => android.show(
  id: id,
  title: answerNotSentTitle,
  body: _notSentBody,
  payload: link,
  notificationDetails: _details(_needsYouChannel, loud: true),
);

/// Runs in the plugin's background isolate when an answer button is pressed
/// (the app's main isolate is not the one that hears of it). Forwards the press
/// to the main isolate; if that is not running, nothing can be answered, and the
/// person is told so, with a tap that opens the agent.
@pragma('vm:entry-point')
void notificationActionInBackground(NotificationResponse response) {
  if (NotificationAnswer.tryParse(response.actionId) == null) return;
  final port = IsolateNameServer.lookupPortByName(answerPortName);
  if (port != null) {
    port.send(<Object?>[response.actionId, response.id ?? 0, response.payload]);
    return;
  }
  unawaited(() async {
    try {
      DartPluginRegistrant.ensureInitialized();
      final android = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) await _postNotSent(android, response.id ?? 0, response.payload);
    } on Object catch (error) {
      debugPrint('Unanswered notification not explained: $error');
    }
  }());
}

/// Android notifications through `flutter_local_notifications`: one channel
/// per kind, tap payloads that carry the agent's link, and the foreground
/// service that shows the quiet "Watching" notice. Built by [start]; every
/// failure of the platform degrades to "no notification", never to a throw.
class LocalNotifier implements Notifier {
  LocalNotifier._(this._android, this._accent);

  final AndroidFlutterLocalNotificationsPlugin _android;
  final Color? _accent;

  void Function(String link)? _handler;
  AnswerHandler? _answerHandler;
  String? _pendingLink;
  ({int count, int blocked, String? page}) _watching = (count: 0, blocked: 0, page: null);

  /// The notifier for this platform, ready to use: a [LocalNotifier] on
  /// Android, a [NullNotifier] anywhere else or when the plugin cannot start.
  /// [accent] tints the small icon.
  static Future<Notifier> start({Color? accent}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return const NullNotifier();
    try {
      final android = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return const NullNotifier();
      final notifier = LocalNotifier._(android, accent);
      await android.initialize(
        settings: const AndroidInitializationSettings(_smallIcon),
        onDidReceiveNotificationResponse: notifier._tapped,
        onDidReceiveBackgroundNotificationResponse: notificationActionInBackground,
      );
      notifier._listenForAnswers();
      for (final channel in const [_needsYouChannel, _finishedChannel, _watchingChannel]) {
        await android.createNotificationChannel(channel);
      }
      final launch = await android.getNotificationAppLaunchDetails();
      if (launch != null && launch.didNotificationLaunchApp) {
        notifier._deliver(launch.notificationResponse?.payload);
      }
      return notifier;
    } on Object catch (error) {
      debugPrint('Notifications are unavailable: $error');
      return const NullNotifier();
    }
  }

  @override
  Future<NotifyPermission> permission() async {
    try {
      final enabled = await _android.areNotificationsEnabled();
      return enabled == true ? NotifyPermission.granted : NotifyPermission.denied;
    } on Object {
      return NotifyPermission.denied;
    }
  }

  @override
  Future<NotifyPermission> requestPermission() async {
    try {
      // Before Android 13 the request does nothing and answers null; the
      // switch in the system settings is then the whole story.
      if (await _android.requestNotificationsPermission() == true) return NotifyPermission.granted;
    } on Object {
      return NotifyPermission.denied;
    }
    return permission();
  }

  @override
  Future<void> show(AgentNotification notification) async {
    final needsYou = notification.kind == NotifyKind.needsYou;
    final collapsed = notification.collapsed;
    try {
      await _android.show(
        id: notification.id,
        title: notification.title,
        body: collapsed ?? notification.body,
        payload: notification.link,
        notificationDetails: _details(
          needsYou ? _needsYouChannel : _finishedChannel,
          loud: needsYou,
          accent: _accent,
          // The whole question and command when the shade is pulled open.
          style: collapsed == null && !notification.body.contains('\n')
              ? null
              : BigTextStyleInformation(notification.body),
          actions: [
            for (final answer in notification.answers.take(maxNotificationAnswers))
              // Android takes the notification away as the button is pressed;
              // what comes of the answer is posted again by whoever handles it.
              AndroidNotificationAction(answer.actionId, answer.label),
          ],
        ),
      );
    } on Object catch (error) {
      debugPrint('Notification not shown: $error');
    }
  }

  @override
  Future<void> cancel(int id) async {
    if (id == watchingNotificationId) return;
    try {
      await _android.cancel(id: id);
    } on Object catch (error) {
      debugPrint('Notification not cancelled: $error');
    }
  }

  @override
  Future<void> cancelAll() async {
    try {
      // The plugin's `cancelAll` would take the foreground notice with it.
      for (final active in await _android.getActiveNotifications()) {
        final id = active.id;
        if (id == null || id == watchingNotificationId || active.channelId == watchingChannelId) continue;
        await _android.cancel(id: id, tag: active.tag);
      }
    } on Object catch (error) {
      debugPrint('Notifications not cancelled: $error');
    }
  }

  @override
  Future<bool> setWatching(int count, {int blocked = 0, String? page}) async {
    try {
      if (count <= 0 && page == null) {
        _watching = (count: 0, blocked: 0, page: null);
        await _android.stopForegroundService();
        return false;
      }
      final n = count < 0 ? 0 : count;
      final glance = (count: n, blocked: blocked.clamp(0, n), page: page);
      if (glance == _watching) return true;
      await _android.startForegroundService(
        id: watchingNotificationId,
        title: watchingTitle(n, page: page),
        body: watchingSummary(n, blocked, page: page),
        notificationDetails: AndroidNotificationDetails(
          _watchingChannel.id,
          _watchingChannel.name,
          channelDescription: _watchingChannel.description,
          importance: Importance.min,
          priority: Priority.min,
          playSound: false,
          enableVibration: false,
          channelShowBadge: false,
          showWhen: false,
          ongoing: true,
          silent: true,
          autoCancel: false,
          onlyAlertOnce: true,
          icon: _smallIcon,
          largeIcon: _largeIcon,
          color: _accent,
        ),
        // A killed process must not leave a notice behind that nothing backs.
        startType: AndroidServiceStartType.startNotSticky,
        foregroundServiceTypes: const {AndroidServiceForegroundType.foregroundServiceTypeSpecialUse},
      );
      _watching = glance;
      return true;
    } on Object catch (error) {
      // Android refuses to start a foreground service from the background in
      // some states; the connections then simply suspend as before.
      debugPrint('Watching notice not started: $error');
      _watching = (count: 0, blocked: 0, page: null);
      return false;
    }
  }

  @override
  void onOpen(void Function(String link) handler) {
    _handler = handler;
    final pending = _pendingLink;
    _pendingLink = null;
    if (pending != null) handler(pending);
  }

  void _tapped(NotificationResponse response) {
    if (response.notificationResponseType != NotificationResponseType.selectedNotification) return;
    _deliver(response.payload);
  }

  /// A tap before [onOpen] was called waits for the handler, once.
  void _deliver(String? link) {
    if (link == null || link.isEmpty) return;
    final handler = _handler;
    if (handler == null) {
      _pendingLink = link;
    } else {
      handler(link);
    }
  }

  @override
  void onAnswer(AnswerHandler handler) => _answerHandler = handler;

  /// The press of an answer button, as the background isolate forwards it.
  void _listenForAnswers() {
    final port = ReceivePort();
    // A restart of the main isolate (hot restart) leaves the old name behind.
    IsolateNameServer.removePortNameMapping(answerPortName);
    IsolateNameServer.registerPortWithName(port.sendPort, answerPortName);
    port.listen(_pressed);
  }

  void _pressed(Object? message) {
    if (message is! List || message.length < 3) return;
    final answer = NotificationAnswer.tryParse(message[0] as String?);
    final id = message[1] as int? ?? 0;
    final link = message[2] as String?;
    final handler = _answerHandler;
    if (answer == null) return;
    if (handler == null) {
      // Nobody to check the question: nothing may be sent.
      unawaited(_notSent(id, link));
      return;
    }
    unawaited(handler(answer, id).catchError((Object _) => _notSent(id, link)));
  }

  Future<void> _notSent(int id, String? link) async {
    try {
      await _postNotSent(_android, id, link);
    } on Object catch (error) {
      debugPrint('Unanswered notification not explained: $error');
    }
  }
}

/// "Watching 1 agent", "Watching 3 agents"; with none, the page from a
/// machine the notice is up for, named so the person knows what to close:
/// "Keeping localhost:8790 on devbox open", "Keeping 2 pages open".
@visibleForTesting
String watchingTitle(int count, {String? page}) =>
    count > 0 || page == null ? 'Watching ${countOf(count, 'agent')}' : 'Keeping $page open';

/// "2 need you · 3 working": [blocked] agents wait for the person, the rest
/// of [count] work. Parts that are zero are left out. With [page], pages from
/// a machine are open too: "1 working · localhost:8790 on devbox open", or,
/// with no agent, how the notice ends.
@visibleForTesting
String watchingSummary(int count, int blocked, {String? page}) {
  if (count <= 0) return page != null ? 'Close it in herdr to let the connection go' : '';
  final waiting = blocked.clamp(0, count);
  final working = count - waiting;
  return [
    if (waiting > 0) needYou(waiting),
    if (working > 0) '$working working',
    if (page != null) '$page open',
  ].join(' · ');
}
