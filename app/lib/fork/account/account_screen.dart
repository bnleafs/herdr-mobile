import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/settings/settings_group.dart';

import 'account_session.dart';
import 'account_vault.dart';

class AccountGroup extends StatelessWidget {
  const AccountGroup({super.key});

  @override
  Widget build(BuildContext context) {
    String summary = 'Sign in';
    try {
      final session = Provider.of<AccountSession?>(context, listen: true);
      if (session?.isSignedIn == true) {
        summary = AccountWords.signedIn;
      }
    } catch (_) {}

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Hairline(indent: ListRow.textIndent()),
        SettingsGroup(
          icon: LucideIcons.cloud,
          title: 'Account',
          summary: summary,
          open: false,
          onToggle: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountScreen())),
          divider: false,
          rows: const [],
        ),
      ],
    );
  }
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _usernameController = TextEditingController(text: canonicalUsername);
  final _passwordController = TextEditingController();
  var _busy = false;
  var _obscure = true;
  String? _problem;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (_busy || password.isEmpty) return;

    final toaster = Toaster.of(context);
    AccountSession? session;
    try {
      session = Provider.of<AccountSession?>(context, listen: false);
    } catch (_) {}

    setState(() {
      _busy = true;
      _problem = null;
    });

    try {
      if (session != null) {
        await session.signIn(username, password);
        if (!session.isSignedIn) return;
      } else {
        final vault = AccountVault(
          machines: context.read<MachineRepository>(),
          connect: context.read<TransportFactory>(),
        );
        final result = await vault.signIn(username, password);
        if (mounted) {
          toaster.show(AccountWords.signInDone(result.added, result.updated), kind: ToastKind.success);
        }
      }
      if (!mounted) return;
      _passwordController.clear();
      toaster.show(AccountWords.signedIn, kind: ToastKind.success);
    } on AccountProblem catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } catch (_) {
      if (mounted) setState(() => _problem = AccountWords.unexpected);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    if (_busy) return;
    final toaster = Toaster.of(context);
    AccountSession? session;
    try {
      session = Provider.of<AccountSession?>(context, listen: false);
    } catch (_) {}

    setState(() {
      _busy = true;
      _problem = null;
    });

    try {
      if (session != null) {
        await session.signOut();
      }
      if (mounted && session?.status == AccountSyncStatus.signedOut) {
        toaster.show(AccountWords.signedOut, kind: ToastKind.info);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    AccountSession? session;
    try {
      session = Provider.of<AccountSession?>(context, listen: true);
    } catch (_) {}

    final signedIn = (session?.isSignedIn ?? false) || (session?.signOutPending ?? false);
    final loading = _busy || (session?.isSigningIn ?? false);
    final displayedProblem = _problem ?? session?.lastError;

    return Scaffold(
      backgroundColor: ds.bg,
      body: CustomScrollView(
        slivers: [
          const SliverLargeTitle.back(title: 'Account'),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + Gap.xl),
              child: signedIn
                  ? _buildSignedInView(context, ds, session!)
                  : _buildSignedOutView(context, ds, loading, displayedProblem),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSignedOutView(BuildContext context, Ds ds, bool loading, String? problem) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
          child: Text(AccountWords.intro, style: Type.compact.copyWith(color: ds.textSecondary)),
        ),
        const SizedBox(height: Gap.sm),
        FormPanel(
          children: [
            _UsernameField(controller: _usernameController),
            const SizedBox(height: Gap.md),
            _PhraseField(
              controller: _passwordController,
              obscure: _obscure,
              suffix: CircleButton(
                icon: _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                tooltip: _obscure ? 'Show password' : 'Hide password',
                filled: false,
                size: CircleButton.compact,
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ],
        ),
        if (problem != null) ...[
          const SizedBox(height: Gap.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
            child: StatusPanel(color: ds.danger, icon: LucideIcons.circleAlert, message: problem),
          ),
        ],
        const SizedBox(height: Gap.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
          child: AppButton(label: 'Sign in', expand: true, loading: loading, onPressed: loading ? null : _signIn),
        ),
      ],
    );
  }

  Widget _buildSignedInView(BuildContext context, Ds ds, AccountSession session) {
    final statusMessage = switch (session.status) {
      AccountSyncStatus.synced => AccountWords.syncStatusSynced,
      AccountSyncStatus.pending => AccountWords.syncStatusPending,
      AccountSyncStatus.syncing => AccountWords.syncStatusSyncing,
      AccountSyncStatus.error => session.lastError ?? AccountWords.syncStatusError,
      _ => '',
    };

    final statusColor = switch (session.status) {
      AccountSyncStatus.synced => ds.accent,
      AccountSyncStatus.error => ds.danger,
      _ => ds.textSecondary,
    };

    final statusIcon = switch (session.status) {
      AccountSyncStatus.synced => LucideIcons.check,
      AccountSyncStatus.error => LucideIcons.circleAlert,
      _ => LucideIcons.refreshCw,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
          child: Text(
            session.signOutPending ? 'Sign out needs retry' : AccountWords.signedIn,
            style: Type.title.copyWith(color: ds.text),
          ),
        ),
        const SizedBox(height: Gap.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
          child: StatusPanel(color: statusColor, icon: statusIcon, message: statusMessage),
        ),
        if (session.status == AccountSyncStatus.error) ...[
          const SizedBox(height: Gap.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
            child: AppButton(
              label: 'Retry',
              kind: AppButtonKind.secondary,
              expand: true,
              loading: _busy,
              onPressed: _busy ? null : session.retry,
            ),
          ),
        ],
        const SizedBox(height: Gap.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
          child: Text(
            AccountWords.machinesRemainNotice,
            style: Type.caption.copyWith(color: ds.textMuted),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: Gap.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
          child: AppButton(
            label: 'Sign out',
            kind: AppButtonKind.secondary,
            expand: true,
            loading: _busy,
            onPressed: _busy ? null : _signOut,
          ),
        ),
      ],
    );
  }
}

class _UsernameField extends StatelessWidget {
  const _UsernameField({required this.controller});

  static const label = 'Username';

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ExcludeSemantics(
            child: Text(label, style: Type.label.copyWith(color: ds.textSecondary)),
          ),
        ),
        Semantics(
          label: label,
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.text,
            autocorrect: false,
            enableSuggestions: false,
            style: Type.input.copyWith(color: ds.text),
            cursorColor: ds.accent,
            decoration: InputDecoration(
              helperText: ' ',
              helperMaxLines: 1,
              helperStyle: Type.caption.copyWith(color: ds.textMuted),
            ),
          ),
        ),
      ],
    );
  }
}

class _PhraseField extends StatelessWidget {
  const _PhraseField({required this.controller, required this.obscure, required this.suffix});

  static const label = 'Password';

  final TextEditingController controller;
  final bool obscure;
  final Widget suffix;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ExcludeSemantics(
            child: Text(label, style: Type.label.copyWith(color: ds.textSecondary)),
          ),
        ),
        Semantics(
          label: label,
          child: TextField(
            controller: controller,
            obscureText: obscure,
            keyboardType: TextInputType.visiblePassword,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            style: Type.input.copyWith(color: ds.text),
            cursorColor: ds.accent,
            decoration: InputDecoration(
              suffixIcon: suffix,
              helperText: ' ',
              helperMaxLines: 1,
              helperStyle: Type.caption.copyWith(color: ds.textMuted),
            ),
          ),
        ),
      ],
    );
  }
}
