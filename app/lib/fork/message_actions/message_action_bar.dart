import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/acp/session_state.dart';
import '../../data/repositories/agent_session.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

import 'message_actions_controller.dart';
import 'message_action_sheet.dart';

/// Subtle inline action bar placed underneath agent responses.
class MessageActionBar extends StatelessWidget {
  const MessageActionBar({
    super.key,
    required this.session,
    required this.message,
    this.controller = const MessageActionsController(),
  });

  final AgentSessionView session;
  final TranscriptMessage message;
  final MessageActionsController controller;

  @override
  Widget build(BuildContext context) {
    final caps = controller.capabilitiesOf(message, session: session);

    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionButton(
            icon: LucideIcons.copy,
            tooltip: 'Copy message',
            onTap: () => controller.copy(context, message),
          ),
          if (caps.canRetry) ...[
            const SizedBox(width: Gap.xs),
            _ActionButton(
              icon: LucideIcons.refreshCw,
              tooltip: 'Retry response',
              onTap: () => controller.retry(session, message),
            ),
          ],
          const SizedBox(width: Gap.xs),
          _ActionButton(
            icon: LucideIcons.moreHorizontal,
            tooltip: 'More actions',
            onTap: () => showMessageActionSheet(context, session: session, message: message, controller: controller),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;

    return Semantics(
      button: true,
      label: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Padding(
          padding: const EdgeInsets.all(Gap.xs),
          child: Icon(icon, size: 14, color: ds.textSecondary),
        ),
      ),
    );
  }
}
