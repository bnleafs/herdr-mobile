import 'dart:async';

import 'package:flutter/material.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/words/elapsed.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/composer/composer_frame.dart';
import 'package:herdr_mobile/ui/render/markdown/markdown.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'aside_models.dart';
import 'aside_runner.dart';
import 'aside_storage.dart';

/// Opens the Aside bottom sheet for a Claude session or pane.
Future<void> showAsideSheet(
  BuildContext context, {
  AgentSessionView? session,
  String? paneId,
  MachineConnection? machine,
  String? initialQuestion,
  AsideStorage storage = const AsideStorage(),
}) async {
  final targetPaneId = session?.terminalPaneId ?? paneId;
  final targetMachine = session?.machine ?? machine;
  if (targetPaneId == null || targetMachine == null) return;

  final sessionKey = (session?.state.sessionId.isNotEmpty == true) ? session!.state.sessionId : targetPaneId;

  await showAppSheet<void>(
    context,
    builder: (ctx) => AsideSheet(
      sessionKey: sessionKey,
      paneId: targetPaneId,
      machine: targetMachine,
      session: session,
      initialQuestion: initialQuestion,
      storage: storage,
    ),
  );
}

class AsideSheet extends StatefulWidget {
  const AsideSheet({
    super.key,
    required this.sessionKey,
    required this.paneId,
    required this.machine,
    this.session,
    this.initialQuestion,
    this.storage = const AsideStorage(),
  });

  final String sessionKey;
  final String paneId;
  final MachineConnection machine;
  final AgentSessionView? session;
  final String? initialQuestion;
  final AsideStorage storage;

  @override
  State<AsideSheet> createState() => _AsideSheetState();
}

class _AsideSheetState extends State<AsideSheet> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  List<AsideThread> _threads = [];
  AsideThread? _activeThread;
  bool _showingHistory = false;
  bool _running = false;
  String _streamingAnswer = '';
  AsideRunner? _runner;

  @override
  void initState() {
    super.initState();
    _loadThreadsAndInitial();
  }

  Future<void> _loadThreadsAndInitial() async {
    final threads = await widget.storage.loadThreads(widget.sessionKey);
    if (!mounted) return;
    setState(() {
      _threads = threads;
      if (threads.isNotEmpty) {
        _activeThread = threads.first;
      }
    });

    if (widget.initialQuestion != null && widget.initialQuestion!.trim().isNotEmpty) {
      // Run as fresh thread for initialQuestion
      setState(() {
        _activeThread = null;
      });
      _submitQuestion(widget.initialQuestion!.trim());
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: Motion.standard,
          curve: Motion.easeOut,
        );
      }
    });
  }

  Future<void> _submitQuestion(String question) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty || _running) return;

    _input.clear();
    setState(() {
      _running = true;
      _streamingAnswer = '';
    });

    final previousTurns = _activeThread?.turns ?? const [];
    final runner = AsideRunner(paneId: widget.paneId, api: widget.machine.api, session: widget.session);
    _runner = runner;

    final result = await runner.ask(
      question: trimmed,
      previousTurns: previousTurns,
      onUpdate: (streaming) {
        if (!mounted) return;
        setState(() {
          _streamingAnswer = streaming;
        });
        _scrollToBottom();
      },
    );

    if (!mounted) return;

    if (result.refusalReason case final reason?) {
      setState(() {
        _running = false;
      });
      Toaster.maybeOf(context)?.show(reason, kind: ToastKind.failed);
      return;
    }

    if (result.turn case final turn?) {
      final updatedThread = await widget.storage.recordTurn(
        sessionKey: widget.sessionKey,
        threadId: _activeThread?.id,
        turn: turn,
      );

      final reloadedThreads = await widget.storage.loadThreads(widget.sessionKey);
      if (!mounted) return;

      setState(() {
        _activeThread = updatedThread;
        _threads = reloadedThreads;
        _running = false;
        _streamingAnswer = '';
      });
      _scrollToBottom();
    } else {
      setState(() {
        _running = false;
        _streamingAnswer = '';
      });
    }
  }

  Future<void> _clearCurrentThread() async {
    final active = _activeThread;
    if (active == null) return;
    await widget.storage.clearThread(widget.sessionKey, active.id);
    final threads = await widget.storage.loadThreads(widget.sessionKey);
    if (!mounted) return;
    setState(() {
      _threads = threads;
      _activeThread = threads.isNotEmpty ? threads.first : null;
      _streamingAnswer = '';
    });
  }

  Future<void> _clearAll() async {
    await widget.storage.clearAll(widget.sessionKey);
    if (!mounted) return;
    setState(() {
      _threads = [];
      _activeThread = null;
      _streamingAnswer = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;

    return Container(
      color: ds.bg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(ds),
          const Divider(height: 1, thickness: 1),
          Flexible(child: _showingHistory ? _buildHistoryList(ds) : _buildThreadView(ds)),
          if (!_showingHistory) _buildComposer(ds),
        ],
      ),
    );
  }

  Widget _buildHeader(Ds ds) {
    if (_showingHistory) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        child: Row(
          children: [
            CircleButton(
              icon: LucideIcons.arrowLeft,
              tooltip: 'Back to thread',
              filled: false,
              onPressed: () => setState(() => _showingHistory = false),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text('Aside history', style: Type.bodyStrong.copyWith(color: ds.text)),
            ),
            if (_threads.isNotEmpty)
              TextButton(
                onPressed: _clearAll,
                child: Text('Clear all', style: Type.label.copyWith(color: ds.dangerText)),
              ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Aside',
              style: Type.bodyStrong.copyWith(color: ds.text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          CircleButton(
            icon: LucideIcons.history,
            tooltip: 'History',
            filled: false,
            onPressed: () => setState(() => _showingHistory = true),
          ),
          const SizedBox(width: Gap.xs),
          CircleButton(
            icon: LucideIcons.plus,
            tooltip: 'New aside',
            filled: false,
            onPressed: () => setState(() {
              _activeThread = null;
              _streamingAnswer = '';
            }),
          ),
          if (_activeThread != null) ...[
            const SizedBox(width: Gap.xs),
            CircleButton(icon: LucideIcons.trash2, tooltip: 'Clear', filled: false, onPressed: _clearCurrentThread),
          ],
        ],
      ),
    );
  }

  Widget _buildHistoryList(Ds ds) {
    if (_threads.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Center(
          child: Text('No asides yet', style: Type.body.copyWith(color: ds.textMuted)),
        ),
      );
    }

    final now = DateTime.now();
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _threads.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final thread = _threads[index];
        final turnsCount = thread.turns.length;
        final turnsLabel = '$turnsCount turn${turnsCount == 1 ? '' : 's'}';
        final timeLabel = formatAgo(thread.updatedAt, now);

        return Material(
          color: Colors.transparent,
          child: ListTile(
            title: Text(
              thread.title,
              style: Type.bodyStrong.copyWith(color: ds.text),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('$timeLabel · $turnsLabel', style: Type.caption.copyWith(color: ds.textSecondary)),
            trailing: IconButton(
              icon: Icon(LucideIcons.trash2, size: IconSize.row, color: ds.textMuted),
              tooltip: 'Delete aside',
              onPressed: () async {
                await widget.storage.clearThread(widget.sessionKey, thread.id);
                final reloaded = await widget.storage.loadThreads(widget.sessionKey);
                if (!mounted) return;
                setState(() {
                  _threads = reloaded;
                  if (_activeThread?.id == thread.id) {
                    _activeThread = reloaded.isNotEmpty ? reloaded.first : null;
                  }
                });
              },
            ),
            onTap: () {
              setState(() {
                _activeThread = thread;
                _showingHistory = false;
              });
            },
          ),
        );
      },
    );
  }

  Widget _buildThreadView(Ds ds) {
    final turns = _activeThread?.turns ?? const [];

    if (turns.isEmpty && !_running) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xxl),
        child: Center(
          child: Text(
            'Ask a side question without interrupting Claude Code',
            style: Type.body.copyWith(color: ds.textMuted),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.all(Gap.md),
      children: [
        for (final turn in turns) ...[
          _buildQuestionBubble(turn.question, ds),
          const SizedBox(height: Gap.sm),
          _buildAnswerBubble(turn.answer, turn.incomplete, ds),
          const SizedBox(height: Gap.md),
        ],
        if (_running) ...[
          if (_streamingAnswer.isNotEmpty) ...[
            _buildAnswerBubble(_streamingAnswer, false, ds),
            const SizedBox(height: Gap.sm),
          ],
          _buildRunningIndicator(ds),
        ],
      ],
    );
  }

  Widget _buildQuestionBubble(String question, Ds ds) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: ds.fill,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: ds.border),
      ),
      child: Text(question, style: Type.bodyStrong.copyWith(color: ds.text)),
    ),
  );

  Widget _buildAnswerBubble(String answer, bool incomplete, Ds ds) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: ds.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: ds.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MdDocumentView(document: parseMd(answer)),
          if (incomplete) ...[
            const SizedBox(height: Gap.xs),
            Text(
              'incomplete — see terminal',
              style: Type.caption.copyWith(color: ds.textMuted, fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _buildRunningIndicator(Ds ds) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Gap.sm),
    child: Row(
      children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text('Reading Claude’s answer…', style: Type.caption.copyWith(color: ds.textSecondary)),
        ),
        AppButton(label: 'Stop', icon: LucideIcons.square, onPressed: () => _runner?.stop()),
      ],
    ),
  );

  Widget _buildComposer(Ds ds) {
    final hasTurns = _activeThread != null && _activeThread!.turns.isNotEmpty;
    final hint = hasTurns ? 'Ask a follow-up…' : 'Ask a side question…';

    return Padding(
      padding: EdgeInsets.only(
        left: Gap.md,
        right: Gap.md,
        top: Gap.xs,
        bottom: Gap.sm + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ComposerFrame(
        field: ComposerField(
          controller: _input,
          focusNode: _focusNode,
          enabled: !_running,
          hint: hint,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.send,
        ),
        trailing: ListenableBuilder(
          listenable: _input,
          builder: (context, _) {
            final hasContent = _input.text.trim().isNotEmpty;
            return ComposerRoundButton(
              label: 'Send',
              icon: LucideIcons.arrowUp,
              iconSize: IconSize.bar,
              ready: !_running && hasContent,
              busy: _running,
              onPressed: () => _submitQuestion(_input.text),
            );
          },
        ),
      ),
    );
  }
}
