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

- `fork/sync.sh [--push] [--test]` fetches upstream tags into `refs/upstream-tags/*`
  (never into `refs/tags`), picks the highest plain `vX.Y.Z`, rebases `jaya` onto
  it with rerere on, and tags the result with the same `vX.Y.Z`. With `--push` it
  force-pushes `jaya` (with lease) and pushes the tag; the tag push runs
  `release.yml` in the fork repo, which signs with the fork's own secrets.
- Fork tags reuse upstream's plain version numbers: the updater only accepts
  `X.Y.Z` (`app/lib/data/models/release_info.dart:40`), so no `-jaya` suffix.
- Upstream tags already sitting in `refs/tags` (from a plain `git fetch upstream`)
  are moved to the fork commit by the sync. Set
  `git config remote.upstream.tagOpt --no-tags` to stop new ones arriving.
- Exit 2 means a conflict rerere had no answer for; `jaya` is left untouched.
  Resolve it once on a scratch branch, then let the sync replay it:

  ```sh
  git switch -c scratch jaya
  git rebase refs/upstream-tags/vX.Y.Z   # fix files, git add, git rebase --continue
  git switch jaya && git branch -D scratch
  fork/sync.sh --push                    # rerere replays the recorded resolution
  ```

  The resolutions live in `.git/rr-cache` of the clone that recorded them.
- `bash fork/test-sync.sh` checks the sync against throwaway repos.
