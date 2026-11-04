#!/usr/bin/env bash
# Rebase the fork branch onto upstream's newest vX.Y.Z tag and tag the result
# with the same version. See fork/PATCHES.md.
#
#   fork/sync.sh [--upstream R] [--branch B] [--fork R] [--push] [--test]
#
# Defaults come from UPSTREAM (upstream), BRANCH (jaya) and FORK (jaya).
# --test runs `flutter test` in app/ with the binary at $FLUTTER. The rebase
# checks the fork branch out; it needs a clean tree. Recorded conflict
# resolutions are restored from the fork's rr-cache branch first and, with
# --push, new ones are published to it.
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

# rerere's recorded resolutions travel on the fork remote's orphan branch
# rr-cache, so CI replays a conflict resolved by hand on any clone. The glob
# matches nothing (exit 0) until the branch exists.
rr=$(git rev-parse --path-format=absolute --git-path rr-cache)
rr_ref=refs/fork/rr-cache
mkdir -p "$rr"
git fetch --quiet "$FORK" '+refs/heads/rr-cache*:refs/fork/rr-cache*' ||
  echo "sync: could not fetch rr-cache from $FORK; going on without shared resolutions" >&2
if git rev-parse --verify --quiet "$rr_ref^{commit}" >/dev/null; then
  git archive "$rr_ref" | tar -xmf - -C "$rr" || die "could not restore $rr_ref into $rr"
fi

# Commits the recorded resolutions (directories with a postimage) the branch
# lacks and pushes them, never forced: a rejected push (another clone published
# first) is retried by the next --push run, after restoring theirs.
publish_rr() {
  local d dirs=() parent tree commit idx="$rr.index"
  for d in "$rr"/*/postimage*; do [ -e "$d" ] && dirs+=("$(basename "$(dirname "$d")")"); done
  [ ${#dirs[@]} -gt 0 ] || return 0
  parent=$(git rev-parse --verify --quiet "$rr_ref^{commit}") || parent=
  rm -f "$idx"
  [ -z "$parent" ] || GIT_INDEX_FILE=$idx git read-tree "$parent"
  GIT_INDEX_FILE=$idx git -C "$rr" --git-dir="$(git rev-parse --absolute-git-dir)" --work-tree=. add -f -- "${dirs[@]}"
  tree=$(GIT_INDEX_FILE=$idx git write-tree)
  rm -f "$idx"
  [ -n "$parent" ] && [ "$tree" = "$(git rev-parse "$parent^{tree}")" ] && return 0
  commit=$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "rr-cache: record conflict resolutions")
  if git push --quiet "$FORK" "$commit:refs/heads/rr-cache"; then
    git update-ref "$rr_ref" "$commit"
    echo "published conflict resolutions to $FORK rr-cache"
  else
    echo "sync: could not push rr-cache to $FORK; the next --push run retries" >&2
  fi
}

if git merge-base --is-ancestor "$base" "$old"; then
  echo "up to date at $tag"
  if [ "$PUSH" = 1 ]; then publish_rr; fi
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
if [ "$PUSH" = 1 ]; then publish_rr; fi
