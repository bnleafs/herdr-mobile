import 'dart:async';
import 'dart:math' as math;

import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/fork/telemetry/envelope.dart';
import 'package:herdr_mobile/fork/telemetry/telemetry.dart';

import 'aside_models.dart';

/// Formats a question and optional earlier thread context into a single-line native /btw command.
String formatAsideCommand(String question, {List<AsideTurn> previousTurns = const []}) {
  final cleanQuestion = question.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  if (previousTurns.isEmpty) {
    var text = cleanQuestion;
    if (text.length > 1500) {
      text = text.substring(0, 1500).trim();
    }
    return '/btw $text';
  }

  // Carry at most the last two turns, each answer truncated to ~500 chars.
  final recent = previousTurns.length > 2 ? previousTurns.sublist(previousTurns.length - 2) : previousTurns;

  final contextParts = <String>[];
  for (final turn in recent) {
    final q = turn.question.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    var a = turn.answer.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (a.length > 500) {
      a = a.substring(0, 500).trim();
    }
    contextParts.add('(Earlier side question: "$q" — your answer: "$a")');
  }

  final context = contextParts.join(' ');
  final body = '$context Follow-up: $cleanQuestion';
  var capped = body;
  if (capped.length > 1500) {
    capped = capped.substring(0, 1500).trim();
  }
  return '/btw $capped';
}

/// Normalizes whitespace by replacing runs of whitespace characters with a single space.
String normalizeWs(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Strips the common indentation (leading spaces) from the given lines.
String stripCommonIndent(List<String> rawLines) {
  if (rawLines.isEmpty) return '';

  int minIndent = -1;
  for (final line in rawLines) {
    if (line.trim().isEmpty) continue;
    int spaces = 0;
    while (spaces < line.length && line[spaces] == ' ') {
      spaces++;
    }
    if (minIndent == -1 || spaces < minIndent) {
      minIndent = spaces;
    }
  }
  if (minIndent == -1) minIndent = 0;

  final stripped = rawLines.map((line) {
    if (line.trim().isEmpty) return '';
    if (line.length <= minIndent) return line.trimLeft();
    return line.substring(minIndent);
  }).toList();

  while (stripped.isNotEmpty && stripped.first.trim().isEmpty) {
    stripped.removeAt(0);
  }
  while (stripped.isNotEmpty && stripped.last.trim().isEmpty) {
    stripped.removeLast();
  }
  return stripped.join('\n');
}

/// Result of parsing an aside from the visible terminal pane screen.
class AsideScreenExtraction {
  const AsideScreenExtraction({
    required this.headerFound,
    required this.footerFound,
    required this.answerLines,
    required this.answerText,
    this.headerLineIndex = -1,
    this.lastHeaderLineIndex = -1,
    this.footerLineIndex = -1,
    this.looksCut = false,
    this.canScroll = false,
  });

  final bool headerFound;
  final bool footerFound;
  final List<String> answerLines;
  final String answerText;
  final int headerLineIndex;
  final int lastHeaderLineIndex;
  final int footerLineIndex;
  final bool looksCut;
  final bool canScroll;
}

/// Returns true when [lines] has no non-empty lines, or every non-empty trimmed
/// line matches the Claude /btw thinking spinner placeholder.
bool isAsideThinkingPlaceholder(List<String> lines) {
  final nonEmpty = lines.map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
  if (nonEmpty.isEmpty) return true;
  final re = RegExp(r'^[^\w\s]?\s*Answering(?:…|\.\.\.)$');
  return nonEmpty.every(re.hasMatch);
}

/// Parses the visible pane screen lines looking for the matching /btw header, answer and footer.
AsideScreenExtraction extractAsideFromScreen(List<String> screenLines, String sentCommand) {
  if (screenLines.isEmpty) {
    return const AsideScreenExtraction(
      headerFound: false,
      footerFound: false,
      answerLines: [],
      answerText: '',
      headerLineIndex: -1,
      lastHeaderLineIndex: -1,
      footerLineIndex: -1,
      looksCut: false,
      canScroll: false,
    );
  }

  final sentNormalized = normalizeWs(sentCommand);
  final prefix = sentNormalized.length > 40 ? sentNormalized.substring(0, 40) : sentNormalized;

  int headerStart = -1;
  int headerEnd = -1;

  // Scan backwards for the last /btw header matching sentCommand.
  for (int i = screenLines.length - 1; i >= 0; i--) {
    final line = screenLines[i];
    final trimmed = line.trim();
    if (!trimmed.startsWith('/btw')) continue;

    final headerIndent = line.indexOf(trimmed);
    int lastH = i;
    final combinedHeaderParts = <String>[trimmed];

    // Check for wrapped header lines immediately following.
    for (int j = i + 1; j < screenLines.length; j++) {
      final nextLine = screenLines[j];
      final nextTrim = nextLine.trim();
      if (nextTrim.contains('Esc to close')) break;
      if (nextTrim.isEmpty) break;

      final nextIndent = nextLine.indexOf(nextTrim);
      // Answer lines are indented deeper than header lines
      if (nextIndent > headerIndent) break;

      final potentialCombined = normalizeWs('${combinedHeaderParts.join(' ')} $nextTrim');
      if (sentNormalized.startsWith(potentialCombined)) {
        combinedHeaderParts.add(nextTrim);
        lastH = j;
      } else {
        break;
      }
    }

    final combinedHeader = normalizeWs(combinedHeaderParts.join(' '));
    final candidatePrefix = combinedHeader.length > 40 ? combinedHeader.substring(0, 40) : combinedHeader;
    final matchLen = math.min(candidatePrefix.length, prefix.length);
    if (matchLen > 0 && candidatePrefix.substring(0, matchLen) == prefix.substring(0, matchLen)) {
      headerStart = i;
      headerEnd = lastH;
      break;
    }
  }

  if (headerStart == -1) {
    return const AsideScreenExtraction(
      headerFound: false,
      footerFound: false,
      answerLines: [],
      answerText: '',
      headerLineIndex: -1,
      lastHeaderLineIndex: -1,
      footerLineIndex: -1,
      looksCut: false,
      canScroll: false,
    );
  }

  int footerIndex = -1;
  for (int i = headerEnd + 1; i < screenLines.length; i++) {
    if (screenLines[i].contains('Esc to close')) {
      footerIndex = i;
      break;
    }
  }

  final bool footerFound = footerIndex != -1;
  final rawAnswerLines = footerFound
      ? screenLines.sublist(headerEnd + 1, footerIndex)
      : screenLines.sublist(headerEnd + 1);

  if (isAsideThinkingPlaceholder(rawAnswerLines)) {
    return AsideScreenExtraction(
      headerFound: true,
      footerFound: false,
      answerLines: const [],
      answerText: '',
      headerLineIndex: headerStart,
      lastHeaderLineIndex: headerEnd,
      footerLineIndex: -1,
      looksCut: false,
      canScroll: false,
    );
  }

  final answerText = stripCommonIndent(rawAnswerLines);
  final footerLine = footerFound ? screenLines[footerIndex] : '';
  final bool canScroll = footerFound && footerLine.contains('to scroll');

  final bool looksCut = footerFound && canScroll && rawAnswerLines.length >= 6;

  return AsideScreenExtraction(
    headerFound: true,
    footerFound: footerFound,
    answerLines: rawAnswerLines,
    answerText: answerText,
    headerLineIndex: headerStart,
    lastHeaderLineIndex: headerEnd,
    footerLineIndex: footerIndex,
    looksCut: looksCut,
    canScroll: canScroll,
  );
}

/// Identifies new lines that appeared in [screenLines] that extend [collected].
List<String>? findNewPagedLines(List<String> collected, List<String> screenLines) {
  if (screenLines.isEmpty) return null;
  if (collected.isEmpty) return screenLines;

  final maxOverlap = math.min(collected.length, screenLines.length);
  for (int overlap = maxOverlap; overlap >= 1; overlap--) {
    bool match = true;
    for (int i = 0; i < overlap; i++) {
      if (collected[collected.length - overlap + i] != screenLines[i]) {
        match = false;
        break;
      }
    }
    if (match) {
      final newLines = screenLines.sublist(overlap);
      return newLines.isNotEmpty ? newLines : null;
    }
  }
  return null;
}

/// The outcome of running an aside.
class AsideRunResult {
  const AsideRunResult({this.turn, required this.outcome, this.refusalReason, this.incomplete = false});

  factory AsideRunResult.refused(String reason) =>
      AsideRunResult(outcome: StageOutcome.cancelled, refusalReason: reason);

  final AsideTurn? turn;
  final StageOutcome outcome;
  final String? refusalReason;
  final bool incomplete;
}

/// Controls execution of an Aside turn against an observed Claude pane.
class AsideRunner {
  AsideRunner({required this.paneId, required this.api, this.session, this.delay = _defaultDelay});

  final String paneId;
  final HerdrApi api;
  final AgentSessionView? session;
  final Future<void> Function(Duration) delay;

  static const _defaultDelay = Future<void>.delayed;
  static final _activePanes = <String>{};

  bool _stopped = false;

  /// Requests stopping the currently active wait and panel.
  void stop() {
    _stopped = true;
  }

  /// Whether an aside is actively running on [paneId].
  static bool isRunning(String paneId) => _activePanes.contains(paneId);

  /// Runs one aside question turn against the pane.
  Future<AsideRunResult> ask({
    required String question,
    List<AsideTurn> previousTurns = const [],
    void Function(String streamingAnswer)? onUpdate,
    Duration pollInterval = const Duration(milliseconds: 700),
    Duration timeout = const Duration(seconds: 120),
  }) async {
    // (a) Refuse while the pane shows a permission/approval prompt with a short reason.
    if (session != null) {
      final blocked = session!.sendBlocked;
      final hasApproval =
          session!.state.pending.any((p) => p is PendingPermission) || session!.phase == AgentPhase.blockedOnPermission;
      if (blocked != null || hasApproval) {
        final reason = blocked ?? 'Answer the approval prompt first';
        return AsideRunResult.refused(reason);
      }
    }

    if (_activePanes.contains(paneId)) {
      return AsideRunResult.refused('An aside is already running for this pane');
    }

    _activePanes.add(paneId);
    _stopped = false;

    final isFollowUp = previousTurns.isNotEmpty;
    final sentCommand = formatAsideCommand(question, previousTurns: previousTurns);
    final stopwatch = Stopwatch()..start();
    final opId = 'aside-${DateTime.now().millisecondsSinceEpoch}';

    String capturedAnswer = '';
    bool incomplete = false;
    StageOutcome outcome = StageOutcome.success;
    int polls = 0;

    void recordAskTelemetry({required StageOutcome outcome, required bool incomplete}) {
      ForkTelemetry.instance.recordStage(
        opId: opId,
        stage: TelemetryStage.asideAsk,
        durationMs: stopwatch.elapsedMilliseconds,
        outcome: outcome,
        followUp: isFollowUp,
        incomplete: incomplete,
        answerChars: capturedAnswer.length,
        pollCount: polls,
      );
    }

    try {
      // (b) Type exactly one line /btw <text> through the send path plus Enter.
      if (session != null) {
        await session!.send(sentCommand);
      } else {
        await api.sendLine(paneId, sentCommand);
      }

      // (c) Poll readPane every ~700 ms.
      String? previousText;
      bool previousHadFooter = false;

      while (stopwatch.elapsed < timeout) {
        if (_stopped) {
          outcome = StageOutcome.cancelled;
          incomplete = true;
          break;
        }

        polls++;
        final read = await api.readPane(paneId, source: ReadSource.visible);
        final extraction = extractAsideFromScreen(read.text.split('\n'), sentCommand);

        if (extraction.headerFound) {
          if (extraction.answerText.isNotEmpty) {
            capturedAnswer = extraction.answerText;
            onUpdate?.call(capturedAnswer);
          }

          if (extraction.footerFound) {
            // "footer present and text unchanged across two reads ~700 ms apart" as done.
            if (previousHadFooter && previousText == extraction.answerText) {
              // Done detection triggered!
              // (d) if the answer looks cut, press ↓ page by page appending new lines until nothing new arrives.
              final looksCut = extraction.canScroll && extraction.answerLines.length >= 6;
              if (looksCut && !_stopped) {
                var collected = List<String>.of(extraction.answerLines);
                int presses = 0;
                while (presses < 30 && !_stopped) {
                  await api.sendKeys(paneId, const ['down']);
                  presses++;
                  await delay(const Duration(milliseconds: 300));
                  final pagedRead = await api.readPane(paneId, source: ReadSource.visible);
                  final pagedExt = extractAsideFromScreen(pagedRead.text.split('\n'), sentCommand);
                  final newLines = findNewPagedLines(collected, pagedExt.answerLines);
                  if (newLines == null || newLines.isEmpty) {
                    break;
                  }
                  collected.addAll(newLines);
                  capturedAnswer = stripCommonIndent(collected);
                  onUpdate?.call(capturedAnswer);
                }
              }
              break;
            }
            previousText = extraction.answerText;
            previousHadFooter = true;
          } else {
            previousHadFooter = false;
            previousText = extraction.answerText;
          }
        }

        await delay(pollInterval);
      }

      if (stopwatch.elapsed >= timeout) {
        incomplete = true;
        outcome = StageOutcome.failure;
      }

      // (e) Send Esc once to close the panel.
      await api.sendKeys(paneId, const ['esc']);

      final finalTurn = AsideTurn(
        id: 'turn-${DateTime.now().millisecondsSinceEpoch}',
        question: question.replaceAll(RegExp(r'[\r\n]+'), ' ').trim(),
        answer: capturedAnswer.isNotEmpty ? capturedAnswer : (incomplete ? 'incomplete — see terminal' : ''),
        timestamp: DateTime.now(),
        incomplete: incomplete,
      );

      recordAskTelemetry(outcome: outcome, incomplete: incomplete);

      return AsideRunResult(turn: finalTurn, outcome: outcome, incomplete: incomplete);
    } catch (e) {
      // Ensure Esc is sent if possible to not leave panel open on failure.
      try {
        await api.sendKeys(paneId, const ['esc']);
      } catch (_) {}

      recordAskTelemetry(outcome: StageOutcome.failure, incomplete: true);

      return AsideRunResult(
        turn: AsideTurn(
          id: 'turn-${DateTime.now().millisecondsSinceEpoch}',
          question: question.replaceAll(RegExp(r'[\r\n]+'), ' ').trim(),
          answer: capturedAnswer.isNotEmpty ? capturedAnswer : 'incomplete — see terminal',
          timestamp: DateTime.now(),
          incomplete: true,
        ),
        outcome: StageOutcome.failure,
        incomplete: true,
      );
    } finally {
      _activePanes.remove(paneId);
    }
  }
}
