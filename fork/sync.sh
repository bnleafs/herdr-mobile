#!/usr/bin/env bash
# Rebase the fork branch onto upstream's newest vX.Y.Z tag and tag the result
# with the same version. See fork/PATCHES.md.
#
#   fork/sync.sh [--upstream R] [--branch B] [--fork R] [--push] [--test]
#
# Defaults come from UPSTREAM (upstream), BRANCH (jaya) and FORK (jaya).
# --test runs `flutter test` in app/ with the binary at $FLUTTER. The rebase
# checks the fork branch out; it needs a clean tree.
# Exit codes: 0 synced or already up to date, 1 refused or failed (nothing
# changed), 2 a conflict rerere could not resolve (rebase aborted).
set -euo pipefail

UPSTREAM=${UPSTREAM:-upstream}
BRANCH=${BRANCH:-jaya}
FORK=${FORK:-jaya}
PUSH=0
TEST=0
while [ $# -gt 0 ]; do
  case $1 in
    --upstream) UPSTREAM=$2; shift ;;
    --branch) BRANCH=$2; shift ;;
    --fork) FORK=$2; shift ;;
    --push) PUSH=1 ;;
    --test) TEST=1 ;;
    *) echo "usage: fork/sync.sh [--upstream R] [--branch B] [--fork R] [--push] [--test]" >&2; exit 1 ;;
  esac
  shift
done

die() { echo "sync: $*" >&2; exit 1; }

cd "$(git rev-parse --show-toplevel)"
[ "$TEST" = 0 ] || [ -n "${FLUTTER:-}" ] || die "--test needs FLUTTER=/path/to/flutter"
old=$(git rev-parse --verify --quiet "refs/heads/$BRANCH") || die "no branch $BRANCH"

# Upstream tags live in their own namespace so they never collide with the
# fork's own vX.Y.Z tags.
git fetch --quiet --no-tags "$UPSTREAM" '+refs/tags/*:refs/upstream-tags/*'
tags=$(git for-each-ref --sort=-version:refname --format='%(refname:strip=2)' refs/upstream-tags/)
tag=$(grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$tags" | sed -n 1p) || true
[ -n "$tag" ] || die "no vX.Y.Z tag on $UPSTREAM"
base="refs/upstream-tags/$tag"

if git merge-base --is-ancestor "$base" "$old"; then
  echo "up to date at $tag"
  exit 0
fi

in_rebase() { [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; }
in_rebase && die "a rebase is already in progress"
git diff --quiet HEAD -- || die "uncommitted changes; commit or stash them first"
if existing=$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}"); then
  git merge-base --is-ancestor "$existing" "$base" || die "tag $tag already marks a fork commit (${existing:0:7})"
fi

# Persisted, so a conflict resolved by hand in a manual rebase is recorded
# and replayed here next time.
git config rerere.enabled true
git config rerere.autoupdate true

if ! out=$(git rebase "$base" "$BRANCH" 2>&1); then
  in_rebase || die "rebase did not start: $out"
  while in_rebase; do
    conflicts=$(git diff --name-only --diff-filter=U)
    if [ -z "$conflicts" ]; then
      # rerere resolved every file of this pick (or it stopped for another reason)
      stopped=$(git rev-parse --verify --quiet REBASE_HEAD || true)
      GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 && break
      [ "$(git rev-parse --verify --quiet REBASE_HEAD || true)" != "$stopped" ] && continue
      conflicts="(none: the rebase stopped on ${stopped:0:7} without a conflict)"
    fi
    git rebase --abort
    echo "conflict rebasing $BRANCH onto $tag; $BRANCH left at ${old:0:7}. Conflicted files:" >&2
    echo "$conflicts" >&2
    exit 2
  done
fi

if [ "$TEST" = 1 ] && ! (cd app && "$FLUTTER" test); then
  git reset --quiet --hard "$old"
  die "flutter test failed on $tag; $BRANCH reset to ${old:0:7}"
fi

head=$(git rev-parse HEAD)
git tag -f "$tag" "$head" >/dev/null
patches=$(git rev-list --count "$base..$head")
pushed="not pushed"
if [ "$PUSH" = 1 ]; then
  git push --quiet --force-with-lease "$FORK" "$BRANCH"
  git push --quiet "$FORK" "refs/tags/$tag"
  pushed="pushed to $FORK"
fi
echo "synced $BRANCH onto $tag: $patches patches, tag $tag at ${head:0:7}, $pushed"
