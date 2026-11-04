#!/usr/bin/env bash
# Checks fork/sync.sh against throwaway repos: bash fork/test-sync.sh
set -uo pipefail

SYNC="$(cd "$(dirname "$0")" && pwd)/sync.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

passed=0
failed=0
fail() { echo "FAIL $name: $*"; ok=0; }
check() {
  if [ "$ok" = 1 ]; then passed=$((passed + 1)); echo "ok   $name"; else failed=$((failed + 1)); fi
}
begin() { name=$1; ok=1; }
up() { git -C "$tmp/up" "$@"; }
fk() { git -C "$tmp/fork" "$@"; }
run_sync() { out=$(cd "$tmp/fork" && bash "$SYNC" "$@" 2>&1); code=$?; }
# line 2 is the one patch2 and the later upstream change both touch
upcommit() { printf '%s\n' "$2" >"$tmp/up/$1"; up add -A; up commit -qm "$3"; }

mkdir "$tmp/up"
up init -q -b main
upcommit a.txt "$(printf 'title\nname=herdr\nx\ny\nversion=1')" "base"
up tag v0.1.1
upcommit a.txt "$(printf 'title\nname=herdr\nx\ny\nversion=2')" "release 2"
up tag -a v0.1.2 -m v0.1.2
up tag v0.2.0-rc1 # not a release: must never be picked

git init -q --bare "$tmp/remote.git"
git init -q -b main "$tmp/fork"
fk remote add upstream "$tmp/up"
fk remote add jaya "$tmp/remote.git"
fk fetch -q upstream # plain fetch: local v0.1.1 and v0.1.2 tags point at upstream commits
fk checkout -q -b jaya v0.1.1
printf 'fork\n' >"$tmp/fork/p1.txt"; fk add p1.txt; fk commit -qm "patch1"
sed -i.bak 's/^name=herdr$/name=herdr j/' "$tmp/fork/a.txt"; rm "$tmp/fork/a.txt.bak"
fk commit -qam "patch2"
fk push -q jaya jaya
fk fetch -q jaya

begin "a new tag rebases cleanly and both patches survive"
run_sync --push
[ "$code" = 0 ] || fail "exit $code: $out"
head=$(fk rev-parse jaya)
[ "$(sed -n 1p <<<"$out")" = "synced jaya onto v0.1.2: 2 patches, tag v0.1.2 at ${head:0:7}" ] || fail "output: $out"
[ "$(fk log --format=%s refs/upstream-tags/v0.1.2..jaya | tr '\n' ' ')" = "patch2 patch1 " ] || fail "patches on top of v0.1.2"
fk merge-base --is-ancestor refs/upstream-tags/v0.1.2 jaya || fail "v0.1.2 not in jaya"
[ "$(fk show jaya:a.txt | tr '\n' ' ')" = "title name=herdr j x y version=2 " ] || fail "a.txt merged wrong"
[ "$(fk rev-parse 'v0.1.2^{commit}')" = "$head" ] || fail "local tag v0.1.2 not on the new head"
[ "$(git -C "$tmp/remote.git" rev-parse jaya 'v0.1.2^{commit}' | tr '\n' ' ')" = "$head $head " ] || fail "push"
check

begin "running again changes nothing"
before=$(fk for-each-ref)
run_sync
[ "$code" = 0 ] && [ "$out" = "up to date at v0.1.2" ] || fail "exit $code: $out"
[ "$(fk for-each-ref)" = "$before" ] || fail "refs changed"
check

begin "an unresolved conflict exits 2 and leaves the branch as it was"
upcommit a.txt "$(printf 'title\nname=herdr up\nx\ny\nversion=3')" "release 3 renames"
up tag v0.1.3
old=$(fk rev-parse jaya)
run_sync
[ "$code" = 2 ] || fail "exit $code: $out"
[ "$(tail -1 <<<"$out")" = "a.txt" ] || fail "conflicted files not listed: $out"
[ "$(fk rev-parse jaya)" = "$old" ] && [ "$(fk rev-parse HEAD)" = "$old" ] || fail "branch or HEAD moved"
[ "$(fk symbolic-ref -q HEAD)" = "refs/heads/jaya" ] || fail "HEAD left detached"
[ -z "$(fk status --porcelain)" ] || fail "tree not clean: $(fk status --porcelain)"
[ ! -e "$tmp/fork/.git/rebase-merge" ] || fail "rebase still in progress"
fk rev-parse -q --verify refs/tags/v0.1.3 >/dev/null && fail "tagged despite the conflict"
check

begin "a conflict resolved once by hand is replayed by rerere"
# resolve v0.1.3 by hand on a scratch branch, so rerere records it
fk checkout -q -b scratch jaya
GIT_EDITOR=true fk rebase -q refs/upstream-tags/v0.1.3 >/dev/null 2>&1 && fail "expected a conflict"
printf 'title\nname=herdr up j\nx\ny\nversion=3\n' >"$tmp/fork/a.txt"
fk add a.txt
GIT_EDITOR=true fk rebase --continue >/dev/null 2>&1 || fail "hand resolution"
fk checkout -q jaya
fk branch -qD scratch
upcommit b.txt "unrelated" "release 4"
up tag v0.1.10 # v0.1.10 sorts above v0.1.3 only by version
run_sync
head=$(fk rev-parse jaya)
[ "$code" = 0 ] && [ "$out" = "synced jaya onto v0.1.10: 2 patches, tag v0.1.10 at ${head:0:7}" ] ||
  fail "exit $code: $out"
[ "$(fk show jaya:a.txt | tr '\n' ' ')" = "title name=herdr up j x y version=3 " ] || fail "resolution not replayed"
[ "$(fk log --format=%s refs/upstream-tags/v0.1.10..jaya | tr '\n' ' ')" = "patch2 patch1 " ] || fail "patches"
[ -z "$(fk status --porcelain)" ] || fail "tree not clean"
check

begin "a resolution published with --push is replayed by a fresh clone on the next tag"
# The clone above recorded the v0.1.3 resolution but never pushed jaya. --push
# publishes it now; clone B below starts from the branch as it was before the
# conflict, so its rebase meets the conflict again.
git -C "$tmp/remote.git" rev-parse -q --verify rr-cache >/dev/null && fail "rr-cache written without --push"
before_conflict=$(git -C "$tmp/remote.git" rev-parse jaya)
run_sync --push
[ "$code" = 0 ] && [ "$(tail -1 <<<"$out")" = "published conflict resolutions to jaya rr-cache" ] || fail "publish: exit $code: $out"
rrc=$(git -C "$tmp/remote.git" rev-parse -q --verify rr-cache) || fail "no rr-cache branch"
git -C "$tmp/remote.git" merge-base rr-cache jaya >/dev/null && fail "rr-cache shares history with jaya"
upcommit c.txt "unrelated" "release 5"
up tag v0.1.11
git clone -q -b jaya "$tmp/remote.git" "$tmp/b"
git -C "$tmp/b" remote add upstream "$tmp/up"
git -C "$tmp/b" reset -q --hard "$before_conflict"
[ "$(git -C "$tmp/b" show jaya:a.txt | sed -n 2p)" = "name=herdr j" ] || fail "clone B does not start before the conflict"
[ ! -e "$tmp/b/.git/rr-cache" ] || fail "fresh clone already has an rr-cache"
out=$(cd "$tmp/b" && bash "$SYNC" --fork origin --push 2>&1); code=$?
head=$(git -C "$tmp/b" rev-parse jaya)
[ "$code" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "synced jaya onto v0.1.11: 2 patches, tag v0.1.11 at ${head:0:7}" ] ||
  fail "clone B: exit $code: $out"
[ "$(git -C "$tmp/remote.git" rev-parse jaya)" = "$head" ] || fail "clone B did not push jaya"
[ "$(git -C "$tmp/b" show jaya:a.txt | tr '\n' ' ')" = "title name=herdr up j x y version=3 " ] || fail "not replayed in B"
[ "$(git -C "$tmp/remote.git" rev-parse rr-cache)" = "$rrc" ] || fail "rr-cache rewritten with nothing new"
check

# Clone C plays CI: a sync run without --push, then --publish (fork/sync.sh
# --fork origin --publish) in a later step of the same job.
cs() { out=$(cd "$tmp/c" && bash "$SYNC" --fork origin "$@" 2>&1); code=$?; }
rem() { git -C "$tmp/remote.git" "$@"; }

begin "--publish pushes the branch and the tag a sync run left unpushed"
upcommit d.txt "unrelated" "release 6"
up tag v0.1.12
git clone -q -b jaya "$tmp/remote.git" "$tmp/c"
git -C "$tmp/c" remote add upstream "$tmp/up"
cs
head=$(git -C "$tmp/c" rev-parse jaya)
[ "$code" = 0 ] && [ "$out" = "synced jaya onto v0.1.12: 2 patches, tag v0.1.12 at ${head:0:7}" ] || fail "sync: exit $code: $out"
[ "$(rem rev-parse jaya)" != "$head" ] || fail "a sync without --push pushed jaya"
git -C "$tmp/c" tag v0.1.9 jaya # a second plain tag on the head: only the highest goes out
cs --publish
[ "$code" = 0 ] || fail "publish: exit $code: $out"
[ "$(rem rev-parse jaya 'v0.1.12^{commit}' | tr '\n' ' ')" = "$head $head " ] || fail "jaya or v0.1.12 not pushed: $out"
rem rev-parse -q --verify refs/tags/v0.1.9 >/dev/null && fail "pushed the lower tag v0.1.9 too"
[ "$out" = "pushed jaya at ${head:0:7} to origin
tag v0.1.12 at ${head:0:7} is on origin" ] || fail "output: $out"
check

begin "--publish with nothing new changes nothing, with or without a tag at the head"
git -C "$tmp/c" tag -d v0.1.9 >/dev/null
before=$(rem for-each-ref)
cs --publish
[ "$code" = 0 ] || fail "exit $code: $out"
[ "$(rem for-each-ref)" = "$before" ] || fail "remote refs changed"
grep -q '^pushed' <<<"$out" && fail "pushed something: $out"
printf 'p3\n' >"$tmp/c/p3.txt"
git -C "$tmp/c" add p3.txt
git -C "$tmp/c" commit -qm "patch3"
git -C "$tmp/c" push -q origin jaya # by hand: the head has no tag, the remote has it
before=$(rem for-each-ref)
cs --publish
[ "$code" = 0 ] || fail "untagged head: exit $code: $out"
[ "$(rem for-each-ref)" = "$before" ] || fail "untagged head: remote refs changed"
[ "$out" = "jaya at $(git -C "$tmp/c" rev-parse --short=7 jaya) is already on origin" ] || fail "untagged head: $out"
check

begin "--publish refuses when the remote branch moved after the checkout"
# It moves before the sync, which fetches rr-cache from the same remote: that
# fetch must not refresh the lease.
head_before_sync=$(git -C "$tmp/c" rev-parse refs/remotes/origin/jaya)
git clone -q -b jaya "$tmp/remote.git" "$tmp/d"
git -C "$tmp/d" commit -q --allow-empty -m "pushed from elsewhere"
git -C "$tmp/d" push -q origin jaya
moved=$(rem rev-parse jaya)
upcommit e.txt "unrelated" "release 7"
up tag v0.1.13
cs
[ "$code" = 0 ] || fail "sync: exit $code: $out"
cs --publish
[ "$code" = 1 ] && [ "$(tail -1 <<<"$out")" = "sync: origin refused jaya: the lease expected $head_before_sync; fetch origin and look before running again" ] ||
  fail "exit $code: $out"
[ "$(rem rev-parse jaya)" = "$moved" ] || fail "overwrote the moved branch"
rem rev-parse -q --verify refs/tags/v0.1.13 >/dev/null && fail "pushed the tag after the lease refused"
check

begin "--publish without a remote-tracking ref only creates the branch"
git init -q --bare "$tmp/empty.git"
git -C "$tmp/c" remote add empty "$tmp/empty.git"
out=$(cd "$tmp/c" && bash "$SYNC" --fork empty --publish 2>&1); code=$?
[ "$code" = 0 ] || fail "empty remote: exit $code: $out"
[ "$(git -C "$tmp/empty.git" rev-parse jaya)" = "$(git -C "$tmp/c" rev-parse jaya)" ] || fail "branch not created"
git clone -q --bare "$tmp/remote.git" "$tmp/full.git"
git -C "$tmp/c" remote add full "$tmp/full.git" # never fetched
out=$(cd "$tmp/c" && bash "$SYNC" --fork full --publish 2>&1); code=$?
[ "$code" = 1 ] && [ "$(tail -1 <<<"$out")" = "sync: full refused jaya: the lease expected no branch there; fetch full and look before running again" ] ||
  fail "unfetched remote: exit $code: $out"
[ "$(git -C "$tmp/full.git" rev-parse jaya)" = "$moved" ] || fail "overwrote a branch it never fetched"
check

begin "--test runs tool/check.sh --tests without timing tests, and a failure resets the branch"
mkdir -p "$tmp/up/tool" "$tmp/sdk/bin"
# shellcheck disable=SC2016 # expanded by the fake check.sh, not here
printf '#!/bin/sh\necho "$* ${HERDR_TEST_ONLY:-} ${HERDR_FLUTTER_BIN:-}" >"%s"\nexit 1\n' "$tmp/check.log" >"$tmp/up/tool/check.sh"
chmod +x "$tmp/up/tool/check.sh"
up add -A
up commit -qm "release 8 adds the test entry"
up tag v0.1.14
printf '#!/bin/sh\n' >"$tmp/sdk/bin/flutter"
chmod +x "$tmp/sdk/bin/flutter"
old=$(git -C "$tmp/c" rev-parse jaya)
out=$(cd "$tmp/c" && FLUTTER="$tmp/sdk/bin/flutter" bash "$SYNC" --fork origin --test 2>&1); code=$?
[ "$code" = 1 ] || fail "exit $code: $out"
[ "$(cat "$tmp/check.log" 2>/dev/null)" = "--tests rest $(cd "$tmp/sdk/bin" && pwd -P)" ] || fail "check.sh ran as: $(cat "$tmp/check.log" 2>/dev/null)"
[ "$(git -C "$tmp/c" rev-parse jaya)" = "$old" ] || fail "branch not reset"
git -C "$tmp/c" rev-parse -q --verify refs/tags/v0.1.14 >/dev/null && fail "tagged despite failing tests"
check

if [ "$failed" = 0 ]; then echo "$passed passed"; else echo "$passed passed, $failed failed"; exit 1; fi
