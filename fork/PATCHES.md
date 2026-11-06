# Fork patches

This fork (`jaya` branch) is upstream's newest release tag plus the short stack of
commits below, rebased onto each new upstream tag by `fork/sync.sh`. Keep the
stack small: every line changed in an upstream file is a line that can conflict.

| Id | Files | Why | Upstream status | Drop when |
|----|-------|-----|-----------------|-----------|
| F1 | `app/lib/data/app_info.dart` | `appRepository` reads `--dart-define=APP_REPOSITORY`, so the updater and release URL checks follow the fork's releases. The default keeps upstream behaviour and tests. | Not offered yet; a candidate PR (a seam with no effect on upstream builds). | Upstream merges the same seam. |
| F2 | `.github/workflows/release.yml` | The APK build passes `APP_REPOSITORY=${{ github.repository }}` and `appIdSuffix=.jaya`, so the fork app installs beside the stock app and updates from this repo. | Fork only. | Never, unless upstream reads both from repository variables. |
| F3 | `app/android/app/src/main/AndroidManifest.xml` | Launcher label `herdr j` (placeholder) tells the two apps apart. | Fork only. | Never. |
| F4 | `fork/` (new files only) | This file, `sync.sh` and `test-sync.sh`. | Fork only. | Never. |
| F5 | `.github/workflows/fork-sync.yml` (new file) | Runs the sync every 2 hours in two steps, so the fork follows upstream's newest release with nobody running anything: `fork/sync.sh --test` with no credential, then `fork/sync.sh --publish` with the deploy key in the repo secret `SYNC_DEPLOY_KEY` (see "Syncing and releases"). A conflict rerere cannot resolve opens (or comments on) the issue "Upstream sync conflict" and fails the run. | Fork only. | Never. |
| F6 | `app/lib/fork/desk_native_sessions.dart` (new), `test/fork/desk_native_sessions_test.dart` (new), `app/lib/ui/features/create/new_agent_session_screen.dart` (4 hook lines) | Starting Claude Code from the phone's new-session form reuses the deepest matching checkout workspace (primary or linked) or an exact-cwd plain non-git workspace (`worktree == null`) with deterministic tie-breaking (by lowest workspace ID), falling back to a folder-named workspace instead of the legacy Phone sessions bucket. It validates returned cwd/observed pane before typing claude using exact normalized path matching (failing closed without auto-closing or mutating the shell on fallback, symlink alias, unknown cwd, or uncertain outcome; legitimate symlink aliases fail closed until authoritative canonicalisation exists). It types `claude` into the confirmed shell and opens the pane's observed chat, so the desk shows a real Claude Code pane instead of the keeper's herdr-tui viewer. Other agents and Resume keep the keeper path (keeper routing is upstream-owned and outside this slice). The decorator implements `AgentSessions`, so a member upstream adds there fails the sync's build loudly. | Fork only for now; an opt-in proposal is drafted (not filed). | Upstream ships a terminal start for Claude Code. |
| F7 | `app/lib/fork/account/` (new), `app/test/fork/account_test.dart` (new), `app/test/fork/account_session_test.dart` (new), `app/test/fork/settings_sync_test.dart` (new), `app/lib/app.dart` (1 hook line), `app/lib/ui/features/settings/settings_screen.dart` (2 hook lines), `app/pubspec.yaml` (`pointycastle`, already locked through `dartssh2`) | Settings → Account: single-account username/password login (`jaya`) over SSH to user `herdrj` on the Oracle box (host key pinned). Server-provisioned 256-bit random account key via literal `key` command decrypts v2 AES-256-GCM ciphertext from `get`. Machines, credentials, and allow-listed user preferences (look: theme, terminal font size/wrap, dark terminal, smooth text; agents: open-as, quick phrases; notifications: enabled/also-done; updates: auto-check/auto-download; with LWW block updatedAt) sync automatically on local mutations with debouncing and serialization. SSH gets login secret derived via PBKDF2-SHA256 (`herdrj-login-v1`), and local host pins and working keys are preserved. Note: server root is a trusted backend with access to the account key, so box root compromise allows decryption of machine credentials. | Fork only. | Never, unless upstream adds machine sync. |
| F8 | `app/lib/fork/terminal_creation.dart` (new), `app/test/fork/terminal_creation_test.dart` (new), `app/test/fork/unified_create_test.dart` (new), `app/lib/ui/features/create/new_agent_session_screen.dart` (unified session form Terminal chip hook & `startTerminalFromForm`), `app/lib/ui/features/machines/machine_screen.dart` (action button hook), `app/lib/ui/features/machines/machines_screen.dart` (menu action hook), `app/lib/ui/features/create/management_sheets.dart` (sheet action hook), `app/lib/fork/desk_native_sessions.dart` (allocation depth) | Create plain terminal from mobile without agent installation via unified "New session" form (`+` on home opens form directly, Terminal chip beside agents) or machine/folder action hooks: reuses matching checkout or exact cwd workspace with new unfocused tab (`focus: false`, label `Terminal · <folder>`), or creates new folder-named workspace and reuses initial root pane once. Disables when offline/stale; validates folder and remote directory; returns typed `PaneAgent` opening `PaneScreen` directly into terminal view. Plain terminal sends zero startup commands, keystrokes or prompts. | Fork only. | Upstream adds mobile terminal creation. |
| F9 | `app/lib/fork/continuity_presentation.dart` (new), `app/test/fork/continuity_test.dart` (new), `app/lib/ui/features/composer/composer_frame.dart` (send-button-only message editing, multiline newline default, removed obsolete onSubmit), `app/lib/ui/features/machines/machines_screen.dart` (1 hook line), `app/lib/ui/features/agents/agents_grouping.dart` (1 hook line), `app/lib/ui/features/pane/pane_screen.dart` (composer edit decoupling, multiline newline editing, input safety guards), `app/lib/ui/features/agent_session/composer.dart` (composer edit decoupling, multiline newline editing), `app/lib/ui/features/agents/reply_sheet.dart` (composer bounded multiline newline editing, send-button-only dispatch, bare Enter prevention), `app/test/ui/reply_sheet_empty_send_test.dart` | Honest retained-state presentation, offline drafting during transient reconnect, and send-button-only message editing across all three text message composers (terminal pane, structured chat, and modal reply sheet): machines list retains known agent counts with honest 'Updating' indicator instead of looking live or dead; transient reconnects without error are omitted from troubled overview; composers permit in-memory multiline draft editing with newline Enter/Shift+Enter while strictly gating message dispatch exclusively behind explicit app Send button and `acceptsInput`/live guards; IME actions/accelerators never dispatch; no offline draft replay or offline draft queues; empty composer keyboard actions never cause bare Enter; raw terminal Enter retains guarded PTY semantics. | Candidate PR for upstream continuity UX. | Upstream adopts honest retained state, offline drafting, and send-button-only message editing. |
| F10 | `app/lib/fork/telemetry/` (new), its tests, `app/lib/boot.dart` and `app/lib/ui/support/error_view.dart` (telemetry hooks), `app/lib/data/repositories/app_update.dart` and `settings_screen.dart` (auto-download), `app/lib/data/app_info.dart` (fork repo default), `app/lib/data/observed/claude_locator.dart`, `observed_session(s).dart`, `agent_navigation.dart`, `agent_session_screen.dart` (readiness wait, Retry, telemetry stages), branding (`AndroidManifest.xml` label, `Info.plist` display name, `app.dart` title, launcher icons), `.github/workflows/release.yml` (`MEGAWATT_*` defines), `app/pubspec.yaml` (`sentry_flutter`, `posthog_flutter`) | Megawatt: app name and icon; persisted automatic verified update download from this fork; a Claude process without its session file waits up to 90 s instead of latching unlinked, and failed observed chats offer Retry; Sentry/PostHog report fixed stage and error enums only, inert without build keys. | Fork only; the readiness wait is an upstream candidate. | Never for branding/telemetry; readiness when upstream fixes it. |
| F11 | `app/lib/ui/features/agent_session/agent_session_screen.dart` (2 lines: the panel and its import) | The chat no longer shows the "Live from terminal" panel (the raw last rows of the pane while the agent works); Jaya finds it noise beside the Working row. `LiveOutput` and the data behind it stay untouched so the change is one line. | Fork only. | Never. |
| F12 | `app/lib/data/observed/claude_locator.dart`, `app/lib/data/observed/session_log_locator.dart`, `app/lib/data/repositories/observed_session.dart`, `app/lib/data/repositories/agent_session.dart`, `app/lib/data/repositories/acp_agent_session.dart`, `app/lib/ui/features/agent_session/session_bar.dart`, `app/lib/fork/telemetry/{envelope,telemetry}.dart` | Claude Code locator accepts 'bg' session kind for forked/background runs; Reload chat action in session sheet re-locates and re-reads log from scratch; transcriptLocate telemetry records locateRoute and sessionMismatch, with chatReload stage for manual reloads. | Locator kind set = upstream candidate; Reload + telemetry = fork only. | Upstream accepts 'bg' session kind; never for fork telemetry. |
| F13 | `app/lib/ui/features/composer/command_model.dart`, `app/lib/ui/features/composer/command_palette.dart`, `app/lib/ui/features/agent_session/agent_session_screen.dart`, `app/lib/ui/features/pane/pane_screen.dart`, `app/test/ui/slash_anywhere_test.dart` (new) | Slash commands and skills palette follows the word at the caret anywhere in draft, not only leading word; replaces only that word and leaves the rest byte for byte. | Upstream candidate. | Upstream merges slash-anywhere. |
| F14 | `app/lib/fork/background_sessions.dart` (new), `app/lib/fork/background_sessions_screen.dart` (new), `app/lib/fork/background_sessions_board.dart` (new), `app/test/fork/background_sessions_test.dart` (new), `app/test/fork/background_sessions_ui_test.dart` (new), `app/lib/data/observed/claude_locator.dart` (1 hook line), `app/lib/ui/features/history/past_sessions_navigation.dart` (2 hook lines), `app/lib/ui/features/agents/agents_screen.dart` (4 hook lines), `app/lib/fork/telemetry/envelope.dart` | Claude background sessions on the phone: list `~/.claude/sessions/*.json` with `kind == 'bg'`, view read-only transcript, and attach in terminal via `claude attach '<sessionId>'` with bounded telemetry stages `backgroundList` and `backgroundAttach`. | Fork only. | Never, unless upstream adds Claude daemon background session management. |
| F15 | `app/android/app/src/main/kotlin/dev/herdrmobile/herdr_mobile/MainActivity.kt`, `app/android/app/src/main/AndroidManifest.xml`, `app/lib/data/services/apk_installer.dart`, `app/lib/data/repositories/app_update.dart`, `app/lib/ui/features/settings/settings_screen.dart`, `app/lib/boot.dart`, `app/lib/app.dart` | Megawatt auto-install: native session install with `USER_ACTION_NOT_REQUIRED` on API 31+, background and cold-start auto-install trigger without opening Settings, 1 h probe with 15 m resume freshness, quiet toast on version change, and `appUpdateInstall` telemetry. | Fork only. | Upstream adopts session install. |
| F16 | `app/lib/data/repositories/slash_catalog.dart`, `app/lib/ui/features/agent_session/agent_session_screen.dart`, `app/lib/data/repositories/observed_session.dart` | Claude /btw side question support: catalog entry and hint for palette and unknown command guard, bypass observed busy gate while agent works without transcript wait or fake cards, and switch to terminal view or toast action to view the answer panel. | Upstream candidate. | Upstream merges Claude /btw side questions. |

## Rules

- Fork code goes in new files (under `fork/` or new Dart files). An upstream file
  gets at most a one-line hook that calls into them; add a row above for it.
- Never patch the keeper (`app/lib/data/services/keeper_script.dart`) or the Rust
  desk client. The keeper installer deletes every other `keeper-*.py` in
  `~/.herdr-mobile` (`keeper_command.dart:95-101`), so a stock app and a fork app
  with different keeper scripts on one host would delete each other's file on
  every connect. Unpatched, both apps install the identical keeper and herdr-tui.
- Generic fixes go upstream as PRs first; a patch leaves this table once
  upstream ships it.

## Syncing and releases

- `fork/sync.sh [--test] [--push]` fetches upstream tags into `refs/upstream-tags/*`
  (never into `refs/tags`), picks the highest plain `vX.Y.Z`, rebases `jaya` onto
  it with rerere on, and tags the result with the same `vX.Y.Z`. `--test` runs
  upstream's own test entry, `HERDR_TEST_ONLY=rest tool/check.sh --tests` (all
  but the `timing` tests); `FLUTTER=/path/to/flutter` picks the SDK, otherwise
  `tool/flutter-bin.sh` does. A failure puts `jaya` back.
- `fork/sync.sh --publish` fetches and rebases nothing; it pushes what an
  earlier run left in this clone: `jaya`, forced with a lease pinned to the
  remote-tracking ref (no ref means the branch must not exist yet), so a push
  made elsewhere since is refused; the plain `vX.Y.Z` tag on its head, if any;
  and new conflict resolutions. With nothing new it changes nothing. `--push`
  is a sync, then a `--publish`. The tag push runs `release.yml` in the fork
  repo, which signs with the fork's own secrets.
- `fork-sync.yml` runs in two phases, every 2 hours and on demand. "Sync and
  test" checks out with `persist-credentials: false` and runs
  `fork/sync.sh --fork origin --test`: upstream code (`pub get`, the tests) runs
  with no credential in reach. "Publish" then loads the deploy key into an
  `ssh-agent`, trusts only GitHub's SSH host keys from
  `https://api.github.com/meta`, and runs `fork/sync.sh --fork origin --publish`.
  Its key is the repository secret `SYNC_DEPLOY_KEY`, the private half of a
  write deploy key on this repo, created by
  `/Users/jaya/jaya/my-terminal/.scratch/herdr-interventions/tools/fork-keys.sh`.
  The built-in token only reads and files issues (`contents: read`,
  `issues: write`); a tag it pushed would not start `release.yml`.
- To verify on the first real sync: whether a deploy-key push may carry
  upstream's changes to `.github/workflows/*`. Believed yes, because the
  `workflow` scope limit applies to OAuth tokens and `GITHUB_TOKEN`, not to
  deploy keys. If GitHub refuses it, Publish fails and `jaya` stays where it was.
- Fork tags reuse upstream's plain version numbers: the updater only accepts
  `X.Y.Z` (`app/lib/data/models/release_info.dart:40`), so no `-jaya` suffix.
- Upstream tags already sitting in `refs/tags` (from a plain `git fetch upstream`)
  are moved to the fork commit by the sync. Set
  `git config remote.upstream.tagOpt --no-tags` to stop new ones arriving.
- Exit 2 means a conflict rerere had no answer for; `jaya` is left untouched.
  In CI the run then files the issue "Upstream sync conflict" (or comments on
  the open one) and ends red. Resolve it once on a scratch branch, then let the
  sync replay it:

  ```sh
  git switch -c scratch jaya
  git rebase refs/upstream-tags/vX.Y.Z   # fix files, git add, git rebase --continue
  git switch jaya && git branch -D scratch
  fork/sync.sh --push                    # replays the resolution, then publishes it
  ```

  Run that last step from the clone that recorded the resolution. The sync
  keeps the recorded resolutions (`.git/rr-cache`) on the orphan branch
  `rr-cache` of the fork remote: it restores them before every rebase, and a
  publish pushes new ones (a plain fast-forward push; a rejected push only
  warns, and the next publish retries). That is how the scheduled workflow
  replays a resolution made on the Mac. Without `--push` or `--publish`
  nothing is written to the remote. GitHub pauses scheduled workflows after 60
  days without repository activity, so re-enable `fork-sync.yml` from the
  Actions tab if the fork has been quiet that long.
- `bash fork/test-sync.sh` checks the sync against throwaway repos.
