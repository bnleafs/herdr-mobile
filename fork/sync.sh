#!/usr/bin/env bash
# Rebase the fork branch onto upstream's newest vX.Y.Z tag and tag the result
# with the same version. See fork/PATCHES.md.
#
#   fork/sync.sh [--upstream R] [--branch B] [--fork R] [--test] [--push]
#   fork/sync.sh [--branch B] [--fork R] --publish
#
# Defaults come from UPSTREAM (upstream), BRANCH (jaya) and FORK (jaya).
# --test runs upstream's own test entry on the rebased branch,
# `HERDR_TEST_ONLY=rest tool/check.sh --tests` (everything but the tests tagged
# timing); FLUTTER=/path/to/flutter picks the SDK, else tool/flutter-bin.sh
# does. The rebase checks the fork branch out; it needs a clean tree. Recorded
# conflict resolutions are restored from the fork's rr-cache branch first.
# --publish fetches and rebases nothing: it pushes what an earlier run left in
# this clone, that is the branch (leased to the remote-tracking ref), the plain
# vX.Y.Z tag at its head, and new conflict resolutions. --push is a sync, then
# a --publish.
# Exit codes: 0 synced, up to date or published, 1 refused or failed, 2 a
# conflict rerere could not resolve (rebase aborted, branch untouched).
set -euo pipefail

UPSTREAM=${UPSTREAM:-upstream}
BRANCH=${BRANCH:-jaya}
FORK=${FORK:-jaya}
PUSH=0
TEST=0
PUBLISH=0
usage="usage: fork/sync.sh [--upstream R] [--branch B] [--fork R] [--test] [--push | --publish]"
while [ $# -gt 0 ]; do
  case $1 in
    --upstream) UPSTREAM=$2; shift ;;
    --branch) BRANCH=$2; shift ;;
    --fork) FORK=$2; shift ;;
    --push) PUSH=1 ;;
    --test) TEST=1 ;;
    --publish) PUBLISH=1 ;;
    *) echo "$usage" >&2; exit 1 ;;
  esac
  shift
done

die() { echo "sync: $*" >&2; exit 1; }

[ "$PUBLISH" = 0 ] || [ "$PUSH$TEST" = 00 ] || die "--publish only publishes; it takes no --push or --test"
cd "$(git rev-parse --show-toplevel)"
old=$(git rev-parse --verify --quiet "refs/heads/$BRANCH") || die "no branch $BRANCH"
if [ "$TEST" = 1 ] && [ -n "${FLUTTER:-}" ]; then
  # tool/flutter-bin.sh takes an SDK's bin directory, never a binary.
  f=$(command -v "$FLUTTER") || die "FLUTTER=$FLUTTER is not a command"
  HERDR_FLUTTER_BIN=$(dirname "$(readlink -f "$f" 2>/dev/null || printf '%s' "$f")")
  export HERDR_FLUTTER_BIN
fi

# rerere's recorded resolutions travel on the fork remote's orphan branch
# rr-cache, so CI replays a conflict resolved by hand on any clone.
rr=$(git rev-parse --path-format=absolute --git-path rr-cache)
rr_ref=refs/fork/rr-cache
mkdir -p "$rr"

# Commits the recorded resolutions (directories with a postimage) the branch
# lacks and pushes them, never forced: a rejected push (another clone published
# first) is retried by the next publish, after a sync restored theirs.
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
    echo "sync: could not push rr-cache to $FORK; the next publish retries" >&2
  fi
}

# Pushes the branch, the plain vX.Y.Z tag at its head (the highest, if a
# commit carries two) and new resolutions. The lease expects the remote branch
# where this clone last fetched it (in CI: at checkout; a sync never fetches
# it), and no branch at all when there is no remote-tracking ref, so a push
# made elsewhere since is refused instead of overwritten.
publish() {
  local head tracking tag
  head=$(git rev-parse "refs/heads/$BRANCH")
  tracking=$(git rev-parse --verify --quiet "refs/remotes/$FORK/$BRANCH") || tracking=
  if [ "$head" = "$tracking" ]; then
    echo "$BRANCH at ${head:0:7} is already on $FORK"
  else
    git push --quiet --force-with-lease="refs/heads/$BRANCH:$tracking" "$FORK" "refs/heads/$BRANCH:refs/heads/$BRANCH" ||
      die "$FORK refused $BRANCH: the lease expected ${tracking:-no branch there}; fetch $FORK and look before running again"
    echo "pushed $BRANCH at ${head:0:7} to $FORK"
  fi
  tag=$(git tag --points-at "$head" --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed -n 1p) || true
  if [ -n "$tag" ]; then
    git push --quiet "$FORK" "refs/tags/$tag" || die "$FORK refused tag $tag"
    echo "tag $tag at ${head:0:7} is on $FORK"
  fi
  publish_rr
}

if [ "$PUBLISH" = 1 ]; then
  publish
  exit 0
fi

# Upstream tags live in their own namespace so they never collide with the
# fork's own vX.Y.Z tags.
git fetch --quiet --no-tags "$UPSTREAM" '+refs/tags/*:refs/upstream-tags/*'
tags=$(git for-each-ref --sort=-version:refname --format='%(refname:strip=2)' refs/upstream-tags/)
tag=$(grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$tags" | sed -n 1p) || true
[ -n "$tag" ] || die "no vX.Y.Z tag on $UPSTREAM"
base="refs/upstream-tags/$tag"

# The glob matches nothing (exit 0) until the rr-cache branch exists.
git fetch --quiet "$FORK" '+refs/heads/rr-cache*:refs/fork/rr-cache*' ||
  echo "sync: could not fetch rr-cache from $FORK; going on without shared resolutions" >&2
if git rev-parse --verify --quiet "$rr_ref^{commit}" >/dev/null; then
  git archive "$rr_ref" | tar -xmf - -C "$rr" || die "could not restore $rr_ref into $rr"
fi

if git merge-base --is-ancestor "$base" "$old"; then
  echo "up to date at $tag"
  if [ "$PUSH" = 1 ]; then publish; fi
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

if [ "$TEST" = 1 ] && ! HERDR_TEST_ONLY=rest tool/check.sh --tests; then
  git reset --quiet --hard "$old"
  die "tool/check.sh --tests failed on $tag; $BRANCH reset to ${old:0:7}"
fi

head=$(git rev-parse HEAD)
git tag -f "$tag" "$head" >/dev/null
patches=$(git rev-list --count "$base..$head")
echo "synced $BRANCH onto $tag: $patches patches, tag $tag at ${head:0:7}"
if [ "$PUSH" = 1 ]; then publish; fi
