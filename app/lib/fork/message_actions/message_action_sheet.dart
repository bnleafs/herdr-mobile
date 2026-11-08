import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/acp/acp_models.dart';
import '../../data/acp/session_state.dart';
import '../../data/repositories/agent_session.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'message_actions_controller.dart';

/// Opens the actions sheet for [message].
Future<void> showMessageActionSheet(
  BuildContext context, {
  required AgentSessionView session,
  required TranscriptMessage message,
  MessageActionsController controller = const MessageActionsController(),
  void Function(String text)? onSetDraft,
}) async {
  final draftSetter = onSetDraft ?? ComposerDraftScope.of(context);
  await showAppSheet<void>(
    context,
    builder: (ctx) =>
        _MessageActionSheetContent(session: session, message: message, controller: controller, onSetDraft: draftSetter),
  );
}

class _MessageActionSheetContent extends StatelessWidget {
  const _MessageActionSheetContent({
    required this.session,
    required this.message,
    required this.controller,
    this.onSetDraft,
  });

  final AgentSessionView session;
  final TranscriptMessage message;
  final MessageActionsController controller;
  final void Function(String text)? onSetDraft;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final caps = controller.capabilitiesOf(message, session: session);
    final isUser = message.role == MessageRole.user;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
              child: Text(
                isUser ? 'Your Message' : 'Assistant Response',
                style: Type.bodyStrong.copyWith(color: ds.textSecondary, fontSize: 13),
              ),
            ),
            const Divider(height: 1),
            if (caps.canCopy)
              ListTile(
                dense: true,
                leading: Icon(LucideIcons.copy, size: IconSize.inline, color: ds.text),
                title: Text('Copy text', style: Type.body.copyWith(color: ds.text)),
                onTap: () {
                  Navigator.of(context).pop();
                  controller.copy(context, message);
                },
              ),
            if (caps.canCopyMarkdown)
              ListTile(
                dense: true,
                leading: Icon(LucideIcons.fileCode, size: IconSize.inline, color: ds.text),
                title: Text('Copy as Markdown', style: Type.body.copyWith(color: ds.text)),
                onTap: () {
                  Navigator.of(context).pop();
                  controller.copy(context, message, markdown: true);
                },
              ),
            if (caps.canEdit)
              ListTile(
                dense: true,
                leading: Icon(LucideIcons.pencil, size: IconSize.inline, color: ds.text),
                title: Text('Edit in composer', style: Type.body.copyWith(color: ds.text)),
                onTap: () {
                  Navigator.of(context).pop();
                  if (onSetDraft != null) {
                    controller.editInComposer(message, onSetDraft: onSetDraft!);
                  }
                },
              ),
            if (caps.canUndo)
              ListTile(
                dense: true,
                leading: Icon(LucideIcons.undo2, size: IconSize.inline, color: ds.blocked),
                title: Text(
                  caps.turnDistance > 1 ? 'Undo ${caps.turnDistance} turns & file changes' : 'Undo turn & file changes',
                  style: Type.body.copyWith(color: ds.blocked),
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  if (caps.turnDistance > 1) {
                    final confirm = await _confirmMultiTurn(
                      context,
                      title: 'Undo ${caps.turnDistance} turns?',
                      body:
                          'This will issue /undo ${caps.turnDistance} times and revert file changes from all ${caps.turnDistance} turns.',
                      confirmLabel: 'Undo turns',
                    );
                    if (confirm != true) return;
                  }
                  await controller.undo(session, message);
                },
              ),
            if (caps.canRetry)
              ListTile(
                dense: true,
                leading: Icon(LucideIcons.refreshCw, size: IconSize.inline, color: ds.text),
                title: Text(
                  caps.turnDistance > 1 ? 'Rewind ${caps.turnDistance} turns & retry' : 'Retry turn',
                  style: Type.body.copyWith(color: ds.text),
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  if (caps.turnDistance > 1) {
                    final confirm = await _confirmMultiTurn(
                      context,
                      title: 'Rewind ${caps.turnDistance} turns & retry?',
                      body: 'This will revert turns and file changes back to this point, then re-send your prompt.',
                      confirmLabel: 'Rewind & Retry',
                    );
                    if (confirm != true) return;
                  }
                  await controller.retry(session, message);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmMultiTurn(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: Type.bodyStrong),
        content: Text(body, style: Type.body),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(confirmLabel)),
        ],
      ),
    );
  }
}

/// Inherited scope allowing message action sheets to populate the active composer input.
class ComposerDraftScope extends InheritedWidget {
  const ComposerDraftScope({required this.setDraft, required super.child, super.key});

  final void Function(String text) setDraft;

  static void Function(String text)? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ComposerDraftScope>()?.setDraft;

  @override
  bool updateShouldNotify(ComposerDraftScope oldWidget) => setDraft != oldWidget.setDraft;
}

/// Inherited scope providing [AgentSessionView] to transcript rows for message actions.
class TranscriptSessionScope extends InheritedWidget {
  const TranscriptSessionScope({required this.session, required super.child, super.key});

  final AgentSessionView session;

  static AgentSessionView? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TranscriptSessionScope>()?.session;

  @override
  bool updateShouldNotify(TranscriptSessionScope oldWidget) => session != oldWidget.session;
}
