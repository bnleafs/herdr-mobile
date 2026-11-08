import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/acp/acp_models.dart';
import '../../data/acp/session_state.dart';
import '../../data/repositories/agent_session.dart';
import '../../ui/core/kit.dart';
import '../../ui/features/agent_session/content_copy.dart';

/// Capabilities of a given message for actions like copy, edit, undo, and retry.
class MessageCapabilities {
  const MessageCapabilities({
    required this.canCopy,
    required this.canCopyMarkdown,
    required this.canEdit,
    required this.canUndo,
    required this.canRetry,
    required this.turnDistance,
  });

  final bool canCopy;
  final bool canCopyMarkdown;
  final bool canEdit;
  final bool canUndo;
  final bool canRetry;

  /// How many user turns back from the end this message is (1 = latest user turn).
  final int turnDistance;
}

/// Controller managing message copy, composer editing, and safe multi-turn
/// `/undo` rewinding and retry for Claude Code and desk-native sessions.
class MessageActionsController {
  const MessageActionsController();

  /// Maximum number of turns we permit rewinding via sequential `/undo`.
  static const int maxRewindTurns = 3;

  /// Evaluates action capabilities for [message] against current [session] state.
  MessageCapabilities capabilitiesOf(TranscriptMessage message, {required AgentSessionView session}) {
    final hasText = message.text.trim().isNotEmpty;
    final isWorking = session.phase == AgentPhase.working;

    if (message.role == MessageRole.agent) {
      final agentMessages = session.state.items
          .whereType<TranscriptMessage>()
          .where((m) => m.role == MessageRole.agent)
          .toList();
      final isLatestAgent = agentMessages.isNotEmpty && agentMessages.last == message;

      return MessageCapabilities(
        canCopy: hasText,
        canCopyMarkdown: hasText,
        canEdit: false,
        canUndo: false,
        canRetry: isLatestAgent && !isWorking,
        turnDistance: 0,
      );
    }

    // User message
    final userMessages = session.state.items
        .whereType<TranscriptMessage>()
        .where((m) => m.role == MessageRole.user)
        .toList();

    final idx = userMessages.indexOf(message);
    final turnDistance = idx >= 0 ? userMessages.length - idx : 0;
    final withinRewindRange = turnDistance > 0 && turnDistance <= maxRewindTurns;

    return MessageCapabilities(
      canCopy: hasText,
      canCopyMarkdown: false,
      canEdit: hasText,
      canUndo: withinRewindRange && !isWorking,
      canRetry: withinRewindRange && !isWorking,
      turnDistance: turnDistance,
    );
  }

  /// Copies message text (or raw markdown) to clipboard and shows feedback toast.
  Future<void> copy(BuildContext context, TranscriptMessage message, {bool markdown = false}) async {
    final text = markdown ? messageMarkdown(message) : messagePlainText(message);
    if (text.isEmpty) return;
    await copyText(context, text, what: markdown ? 'Markdown copied' : 'Message copied');
  }

  /// Populates the composer draft with message text.
  void editInComposer(TranscriptMessage message, {required void Function(String text) onSetDraft}) {
    onSetDraft(message.text);
  }

  /// Dispatches `/undo` sequentially [turnDistance] times to revert turns and file changes.
  Future<void> undo(AgentSessionView session, TranscriptMessage message) async {
    final caps = capabilitiesOf(message, session: session);
    if (!caps.canUndo) return;

    for (var i = 0; i < caps.turnDistance; i++) {
      await session.send('/undo');
      if (i < caps.turnDistance - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  /// Retries a turn: if it already started, runs `/undo` to revert file changes
  /// and rewind, then re-sends the prompt.
  Future<void> retry(AgentSessionView session, TranscriptMessage message, {String? text}) async {
    final caps = capabilitiesOf(message, session: session);
    if (!caps.canRetry) return;

    final promptText = text ?? message.text;

    final items = session.state.items;
    final msgIndex = items.indexOf(message);
    final hasSubsequentAgentReply =
        msgIndex >= 0 &&
        items.skip(msgIndex + 1).any((item) => item is TranscriptMessage && item.role == MessageRole.agent);

    if (hasSubsequentAgentReply && caps.turnDistance > 0) {
      for (var i = 0; i < caps.turnDistance; i++) {
        await session.send('/undo');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    await session.send(promptText);
  }
}
