# tests/helpers.bash: shared Bats helpers. bats-core only: no bats-assert, no bats-support.
#
# Every repository is built under mktemp -d and removed on teardown.
# Nothing depends on the ambient default branch name, committer dates, or the network.
# GIT_EDITOR=true unless an editor is under test.

# The repository root: the directory holding tests/.
CARRIER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CARRIER_ROOT

# git_version_at_least MAJOR MINOR: true when the git under test is >= MAJOR.MINOR. Used to skip
# the few tests that need a newer host git than the floor.
git_version_at_least() {
  local v major minor
  v=$(git --version)
  v=${v#git version }
  major=${v%%.*}
  minor=${v#*.}
  minor=${minor%%.*}
  [ "$major" -gt "$1" ] && return 0
  [ "$major" -eq "$1" ] && [ "$minor" -ge "$2" ]
}

# ------------------------------------------------------------- assertions
# bats-core ships none (bats-assert is deliberately not a dependency); this is the whole set the
# suite uses, reading the status/output that bats' run sets.

fail() {
  printf 'failed: %s\n' "${1:-}" >&2
  return 1
}

assert_success() {
  # status/output are set by bats' run in the test body
  # shellcheck disable=SC2154
  if [ "$#" -gt 0 ]; then
    [ "$status" -eq "$1" ] || fail "expected exit $1, got $status (output: $output)"
  else
    [ "$status" -eq 0 ] || fail "expected success, got exit $status (output: $output)"
  fi
}

assert_failure() {
  # shellcheck disable=SC2154
  [ "$status" -ne 0 ] || fail "expected failure, got exit 0 (output: $output)"
}

assert_output() {
  # shellcheck disable=SC2154
  local mode=exact expected
  case $1 in
  --partial | -p)
    mode=partial
    shift
    ;;
  esac
  expected=${1-}
  case $mode in
  exact)
    [ "$output" = "$expected" ] || fail "expected output [$expected], got [$output]"
    ;;
  partial)
    case $output in
    *"$expected"*) ;;
    *) fail "expected output to contain [$expected], got [$output]" ;;
    esac
    ;;
  esac
}

# Copy git-carrier.bash into <dir>, link the three applet names beside it, put <dir> on PATH: every
# cycle invokes each applet by its own name.
carrier_install() {
  local dir=$1 n
  cp "$CARRIER_ROOT/git-carrier.bash" "$dir/git-carrier.bash"
  chmod +x "$dir/git-carrier.bash"
  for n in park unpark land; do ln -s git-carrier.bash "$dir/git-$n"; done
  PATH="$dir:$PATH"
}

# One scratch bin + one scratch work area per test file, torn down at the end.
setup_scratch() {
  CARRIER_BIN=$(mktemp -d) || return 1
  CARRIER_WORK=$(mktemp -d) || return 1
  carrier_install "$CARRIER_BIN"
  export GIT_EDITOR=true
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export LC_ALL=C
}

teardown_scratch() {
  [ -n "${CARRIER_BIN:-}" ] && rm -rf "$CARRIER_BIN"
  [ -n "${CARRIER_WORK:-}" ] && rm -rf "$CARRIER_WORK"
}

# A fresh repository under the scratch area: init -b main (never the ambient default), identity set.
# Sets REPO and cds into it.
mkrepo() {
  local name=$1
  REPO="$CARRIER_WORK/$name"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email a@b.c
  git -C "$REPO" config user.name T
  cd "$REPO" || return 1
}

# A base + two diverging branches with a content conflict in f.txt. After conflict_repo x: main is
# at "ours", side at "theirs", and a stopped merge is live. Sets O (the pre-merge tip), OURS,
# THEIRS.
conflict_repo() {
  mkrepo "$1"
  printf 'a\nb\nc\n' >f.txt
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >f.txt
  git add -A && git commit -qm ours
  # O is the pre-merge tip of main (land's base commit)
  O=$(git rev-parse HEAD)
  # shellcheck disable=SC2034 # set for the .bats files
  OURS=$O
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt
  git add -A && git commit -qm theirs
  # shellcheck disable=SC2034 # set for the .bats files
  THEIRS=$(git rev-parse HEAD)
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
}

# The full conflict matrix: content (crlf), modify/delete, plain-rm'd, an add while the merge is
# stopped, exec mode, symlink, with untracked and ignored files present. A stopped merge is live
# on main. Sets O, OURS, THEIRS, and the pre-park stage-2 blob of c1.txt (S2WANT).
matrix_repo() {
  mkrepo "$1"
  printf 'junk.out\n' >.gitignore
  printf 'c1.txt text eol=crlf\n' >.gitattributes
  printf 'a\nb\nc\n' >c1.txt
  printf 'keep\n' >keep.txt
  printf 'c2\n' >c2.txt
  printf 'c3\n' >c3.txt
  printf 's0\n' >s0.txt
  printf '#!/bin/sh\necho base\n' >run.sh
  chmod 755 run.sh
  ln -s keep.txt link.txt
  git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >c1.txt
  git rm -q c2.txt
  printf 'c3-OURS\n' >c3.txt
  printf 's0-OURS\n' >s0.txt
  printf '#!/bin/sh\necho ours\n' >run.sh
  chmod 755 run.sh
  rm link.txt
  ln -s keep.txt ours-link
  ln -s ours-link link.txt
  git add -A && git commit -qm ours
  # O is the pre-merge tip of main (land's base commit)
  O=$(git rev-parse HEAD)
  # shellcheck disable=SC2034 # set for the .bats files
  OURS=$O
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >c1.txt
  printf 'c2-THEIRS\n' >c2.txt
  rm c3.txt
  printf 's0-THEIRS\n' >s0.txt
  printf '#!/bin/sh\necho theirs\n' >run.sh
  chmod 755 run.sh
  rm link.txt
  ln -s c1.txt link.txt
  git add -A && git commit -qm theirs
  # shellcheck disable=SC2034 # set for the .bats files
  THEIRS=$(git rev-parse HEAD)
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  # user mid-merge actions: add while the merge is stopped, then edit (the re-edit stays
  # unstaged), then a plain rm.
  printf 's0-SNAPSHOT\n' >s0.txt
  git add s0.txt
  printf 's0-EDITED\n' >s0.txt
  rm -f c3.txt
  echo untracked-work >new.txt
  echo artifact >junk.out
  # shellcheck disable=SC2034 # set for the .bats files
  S2WANT=$(git ls-files -s -- c1.txt | sed -n 's/^100644 \([0-9a-f]*\) 2\t.*/\1/p')
}

# The value of field <name> in <rev>'s hangar manifest, empty when absent.
manifest_value() {
  git cat-file blob "$1:.hangar/manifest" 2>/dev/null |
    sed -n "s/^$2: //p" | sed -n 1p
}

# Finish a hand-built .hangar (stages/ written by the caller) into a parked chain tip at HEAD: the
# chrome park itself writes, committed and shape-asserted. Git's own D/F handling renames colliding
# paths, so no merge parks a path nested under another held path; a hand-built hangar can, and
# the walks must read it as well.
craft_hangar() {
  printf 'hangar-format: 1\nsource: %s\n' "$1" >.hangar/manifest
  printf "source-desc: commit '%s'\n" "$1" >>.hangar/manifest
  printf '* -text -filter -ident -working-tree-encoding\n' >.hangar/.gitattributes
  printf 'crafted\n' >.hangar/message
  git add -f .hangar >/dev/null
  git commit -qm crafted
  assert_hangar HEAD
}

# An annotated tag over side's tip; sets SRC (the commit) and TAGV (the tag object id, kept verbatim
# through the hangar).
tag_the_source() {
  git tag -a v1.2.3 -m "release v1.2.3" side
  # shellcheck disable=SC2034 # set for the .bats files
  TAGV=$(git rev-parse v1.2.3)
  # shellcheck disable=SC2034 # set for the .bats files
  SRC=$(git rev-parse 'v1.2.3^{commit}')
}

# Assert the hangar at <rev>: the manifest's first line is the format line with both fields (a
# lowercase hex source of the repository's hash length, a non-empty source-desc), .gitattributes
# exact, message present or absent, stages absent or a directory.
assert_hangar() {
  local rev=$1 line t
  line=$(git cat-file blob "$rev:.hangar/manifest" 2>/dev/null | sed -n 1p)
  [ "$line" = "hangar-format: 1" ] || fail "hangar at $rev: the manifest's first line is [$line]"
  line=$(manifest_value "$rev" source)
  case $line in
  *[!0-9a-f]* | '') fail "hangar at $rev: the manifest's source is [$line]" ;;
  esac
  case ${#line} in
  40 | 64) ;;
  *) fail "hangar at $rev: the manifest's source is not a full id: [$line]" ;;
  esac
  [ -n "$(manifest_value "$rev" source-desc)" ] ||
    fail "hangar at $rev: the manifest has no source-desc"
  [ "$(git cat-file blob "$rev:.hangar/.gitattributes" 2>/dev/null)" = "* -text -filter -ident -working-tree-encoding" ] ||
    fail "hangar at $rev: .gitattributes is not exact"
  if t=$(git cat-file -t "$rev:.hangar/stages" 2>/dev/null); then
    [ "$t" = tree ] || fail "hangar at $rev: stages is a $t, not a directory"
  fi
}

# Assert git's most ordinary prepared state: HEAD on <dst> at <O>, MERGE_HEAD holding <verbatim-id>,
# MERGE_MSG equal to the fresh render for <desc>, carrying the chain tip's recorded message, when
# there is one, as a comment block when it differs, and status reading "All conflicts fixed but
# you are still merging".
assert_prepared() {
  local dst=$1 o=$2 vid=$3 tip=$4 desc=$5 line oids gpaths raw gmh gmm
  [ "$(git symbolic-ref --short HEAD)" = "$dst" ] ||
    fail "prepared: HEAD is on $(git symbolic-ref --short HEAD), not $dst"
  oids=$(git rev-parse HEAD "$o") || fail "prepared: could not resolve HEAD and $o"
  [ "${oids%%$'\n'*}" = "${oids##*$'\n'}" ] || fail "prepared: HEAD is not at O"
  gpaths=$(git rev-parse --git-path MERGE_HEAD --git-path MERGE_MSG)
  gmh=${gpaths%%$'\n'*} gmm=${gpaths##*$'\n'}
  [ "$(cat "$gmh")" = "$vid" ] ||
    fail "prepared: MERGE_HEAD is not the verbatim id"
  printf '%s\t\t%s\n' "$vid" "$desc" >"$CARRIER_WORK/fetchhead"
  git fmt-merge-msg <"$CARRIER_WORK/fetchhead" | git stripspace >"$CARRIER_WORK/wantmsg" ||
    fail "prepared: could not render the expected message"
  : >"$CARRIER_WORK/recmsg"
  # a missing recorded message is ordinary (the chain tip need not carry one)
  raw=$(git cat-file blob "$tip:.hangar/message" 2>/dev/null) || :
  if [ -n "$raw" ]; then
    git stripspace <<<"$raw" >"$CARRIER_WORK/recmsg" ||
      fail "prepared: could not stripspace the recorded message"
  fi
  if [ -s "$CARRIER_WORK/recmsg" ] && ! cmp -s "$CARRIER_WORK/recmsg" "$CARRIER_WORK/wantmsg"; then
    {
      printf '\n# Message recorded at park:\n'
      while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$line" ]; then printf '# %s\n' "$line"; else printf '#\n'; fi
      done <"$CARRIER_WORK/recmsg"
    } >>"$CARRIER_WORK/wantmsg"
  fi
  cmp -s "$CARRIER_WORK/wantmsg" "$gmm" ||
    fail "prepared: MERGE_MSG is not the fresh render: $(diff "$CARRIER_WORK/wantmsg" "$gmm" | head -10)"
  git status | grep -q 'All conflicts fixed but you are still merging' ||
    fail "prepared: status does not read 'All conflicts fixed'"
}
