# acceptance.bats: the demo matrix, one cycle per test:
# merge -> park --branch -> (work the chain) -> land

load helpers

setup() {
  setup_scratch
}

teardown() {
  teardown_scratch
}

# An editor script that EDITS the message file: proof that the finishing commit runs under the
# user's own GIT_EDITOR.
editing_editor() {
  cat >"$CARRIER_WORK/editmsg.sh" <<'EOF'
#!/bin/sh
printf 'EDITED-BY-EDITOR\n' >>"$1"
exit 0
EOF
  chmod +x "$CARRIER_WORK/editmsg.sh"
}

# A three-path conflict parked onto carrier/v1 and pushed to a bare origin, so two workers'
# clones can each resolve their own paths. Sets ORIGIN, O, SRC, TAGV.
fanin_origin() {
  mkrepo "$1"
  local f
  for f in a b c; do printf '%s\n1\n' "$f" >"$f.txt"; done
  git add -A && git commit -qm base
  git branch side
  for f in a b c; do printf '%s\nOURS\n' "$f" >"$f.txt"; done
  git commit -qam ours
  O=$(git rev-parse HEAD)
  git checkout -q side
  for f in a b c; do printf '%s\nTHEIRS\n' "$f" >"$f.txt"; done
  git commit -qam theirs
  git tag -a v1 -m "release v1"
  TAGV=$(git rev-parse v1)
  SRC=$(git rev-parse 'v1^{commit}')
  git checkout -q main
  git clone -q --bare "$REPO" "$CARRIER_WORK/$1.git"
  git remote add origin "$CARRIER_WORK/$1.git"
  git merge v1 >/dev/null 2>&1 || true
  git park -b carrier/v1 >/dev/null
  git commit -qm parked
  git push -q origin main carrier/v1 v1
  ORIGIN="$CARRIER_WORK/$1.git"
}

# A worker: clone the origin, materialize the carrier branch, cd in.
fanin_clone() {
  git clone -q "$ORIGIN" "$CARRIER_WORK/$1"
  cd "$CARRIER_WORK/$1" || fail "cd $1"
  git config user.email "$1@x.y" && git config user.name "$1"
  git checkout -q -b carrier/v1 origin/carrier/v1
}

# Resolve one held path the driven way: unpark reopens it; write, add, commit (the release
# travels with the commit).
fanin_resolve() {
  git unpark "$1" >/dev/null || fail "unpark $1 failed"
  printf '%s\n%s\n' "${1%.txt}" "$2" >"$1"
  git add "$1"
  git commit -qm "resolve $1"
}

@test "C1: the full conflict matrix through park/unpark, finished under the user's editor" {
  matrix_repo c1
  tag_the_source
  # re-drive the merge by its release tag (the strays survive the reset; the mid-merge staged add
  # is covered in park.bats)
  git reset -q --hard
  git merge v1.2.3 >/dev/null 2>&1 || true
  # drive: park the stopped matrix onto the carrier
  run git park -b carrier/v1.2.3
  assert_success
  [ "$(git symbolic-ref --short HEAD)" = "carrier/v1.2.3" ] ||
    fail "the park did not put HEAD on the carrier"
  git commit -qm "parked A"
  git unpark c1.txt >/dev/null # unchanged (crlf round-trip): reopen
  git show :2:c1.txt >c1.txt && git add c1.txt
  git commit -qm "resolve c1"
  # the rest resolved straight in the worktree, then released
  printf '#!/bin/sh\necho merged\n' >run.sh && chmod 755 run.sh
  rm -f link.txt && ln -s keep.txt link.txt
  printf 's0-DONE\n' >s0.txt
  git add run.sh link.txt s0.txt
  git rm -q -r .hangar/stages/run.sh .hangar/stages/link.txt .hangar/stages/s0.txt
  git commit -qm "resolve run.sh, link, and s0"
  git rm -q -r .hangar/stages/c2.txt .hangar/stages/c3.txt
  git commit -qm "release the rest"
  # drive: land the finished chain onto main
  editing_editor
  local tip
  tip=$(git rev-parse HEAD) # the chain tip, before the landing moves HEAD
  run git land main
  assert_success
  assert_prepared main "$O" "$TAGV" "$tip" "tag 'v1.2.3'"
  GIT_EDITOR="$CARRIER_WORK/editmsg.sh" git commit -q >/dev/null
  # the merge is [O, source], carries no hangar, and the editor's edit is in the recorded message
  [ "$(git rev-parse main^1)" = "$O" ] || fail "first parent is not the pre-merge tip"
  [ "$(git rev-parse main^2)" = "$SRC" ] || fail "second parent is not the peeled source"
  [ "$(git ls-tree -r main | grep -c hangar)" = "0" ] || fail "the landed merge carries the hangar"
  git log -1 --format=%B main | grep -q EDITED-BY-EDITOR ||
    fail "the finishing commit did not run under the user's editor"
  # C11 (per-cycle): the re-run from the chain is the idempotent no-op
  git checkout -q carrier/v1.2.3
  run git land main
  assert_success
  assert_output --partial "this merge already landed"
}

@test "C2: the ordinary landing, from the carrier branch" {
  conflict_repo c2
  git park -b carrier/lb >/dev/null && git commit -qm parked
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git rm -q -r .hangar/stages/f.txt && git commit -qm resolve
  run git land main
  assert_success
  assert_output --partial "prepared the landing on main"
  assert_prepared main "$O" "$(git rev-parse side)" "$(git rev-parse carrier/lb)" "commit '$(git rev-parse side)'"
  git commit -qm finished
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "not a parked merge" # the landing runs from the chain, not from main
  git checkout -q carrier/lb
  run git land main
  assert_success
  assert_output --partial "this merge already landed"
}

@test "C4: a resolved-but-unfinished stop (a hook rejected the auto-commit) lands as an empty chain" {
  conflict_repo c4
  SRC=$(git rev-parse side)
  git show :3:f.txt >f.txt
  git add f.txt
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] || fail "fixture: MERGE_HEAD is not live"
  run git park -b carrier/lb
  assert_success
  git commit -qm "parked: an empty mirror"
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$(git rev-parse carrier/lb)" "commit '$SRC'"
  git commit -qm finished
  [ "$(git rev-parse main^2)" = "$SRC" ] ||
    fail "the empty chain's landing is not [base, source]"
}

@test "C6: byte-identical and kept-deletion landings are committable" {
  mkrepo c6
  printf 'a\nb\nc\n' >f.txt
  printf 'gone\n' >g.txt
  git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >f.txt
  git rm -q g.txt
  git add -A && git commit -qm ours
  O=$(git rev-parse HEAD)
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt
  printf 'g-THEIRS\n' >g.txt
  git add -A && git commit -qm theirs
  SRC=$(git rev-parse side)
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/lb >/dev/null && git commit -qm parked
  # byte-identical: resolve f.txt back to ours' exact bytes (the stage-2 blob); keep ours' deletion
  # of g.txt; both leave the tree equal to O's, with no tree delta to signal the resolution
  git show HEAD:.hangar/stages/f.txt/2 >f.txt && git add f.txt
  git rm -q g.txt
  git rm -q -r .hangar/stages/f.txt .hangar/stages/g.txt
  git commit -qm resolve
  # fixture check: apart from the hangar, the chain tip's tree is byte-identical to O's (no tree
  # delta signals either resolution)
  [ "$(git rev-parse HEAD:f.txt)" = "$(git rev-parse "$O:f.txt")" ] ||
    fail "fixture: f.txt is not byte-identical to ours"
  if git cat-file -e "HEAD:g.txt" 2>/dev/null; then
    fail "fixture: the kept deletion did not stay deleted"
  fi
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$(git rev-parse carrier/lb)" "commit '$SRC'"
  # the nothing-to-commit check is bypassed with MERGE_HEAD written
  git commit -qm "byte-identical landing"
  [ "$(git rev-list --parents -n 1 main | wc -w)" = "3" ] ||
    fail "the byte-identical landing did not commit"
  [ "$(git rev-parse 'main^{tree}')" = "$(git rev-parse "$O^{tree}")" ] ||
    fail "the landed tree is not the byte-identical one"
}

@test "C7: an annotated tag source: verbatim id through the hangar, peeled parent, tag block" {
  mkrepo c7
  printf 'p\nq\nr\n' >t.txt && git add -A && git commit -qm base
  git branch side
  printf 'p\nOURS\nr\n' >t.txt && git add -A && git commit -qm ours
  O=$(git rev-parse HEAD)
  git checkout -q side
  printf 'p\nTHEIRS\nr\n' >t.txt && git add -A && git commit -qm theirs
  git tag -a v1.2.3 -m "release v1.2.3" side
  TAGV=$(git rev-parse v1.2.3)
  SRC=$(git rev-parse 'v1.2.3^{commit}')
  git checkout -q main
  git merge v1.2.3 >/dev/null 2>&1 || true
  git park -b carrier/lb >/dev/null && git commit -qm parked
  [ "$(manifest_value HEAD source)" = "$TAGV" ] ||
    fail "the hangar did not keep the tag id verbatim"
  [ "$(manifest_value HEAD source-desc)" = "tag 'v1.2.3'" ] ||
    fail "the hangar did not record the tag description"
  printf 'p\nRESOLVED\nr\n' >t.txt
  git add t.txt && git rm -q -r .hangar/stages/t.txt && git commit -qm resolve
  run git land main
  assert_success
  # MERGE_HEAD holds the verbatim TAG id, not the peeled commit
  assert_prepared main "$O" "$TAGV" "$(git rev-parse carrier/lb)" "tag 'v1.2.3'"
  git commit -q --no-edit # the message is the fresh render (recorded == rendered: no comment block)
  [ "$(git rev-parse main^2)" = "$SRC" ] || fail "the second parent is not the peeled commit"
  git log -1 --format=%B main | grep -q 'release v1.2.3' ||
    fail "the tag block did not travel with the message"
  git log -1 --format=%B main | grep -q "tag 'v1.2.3'" ||
    fail "the subject is not Merge tag 'v1.2.3'"
}

@test "C8: rebase -r re-execution control: stops at the conflict, recreates the merge, no leak, no drop" {
  # Asserts a host-git behavior (rebase -r faithfully re-executing a merge) that only holds from
  # git 2.52; skipped on older git so the floor-version CI leg can run the rest.
  git_version_at_least 2 52 || skip "git rebase -r merge recreation needs git >= 2.52"
  conflict_repo c8
  SRC=$(git rev-parse side)
  git park -b carrier/lb >/dev/null && git commit -qm parked
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git rm -q -r .hangar/stages/f.txt && git commit -qm resolve
  git land main >/dev/null
  git commit -qm finished
  BASE=$(git rev-parse "$O~1")
  # force a rebase -r re-execution of the landed merge: edit the commit below it so every sha
  # changes and the merge must truly re-run
  git checkout -q -b rctl
  # the -r todo reads `pick <sha> # ours`: edit that line so the merge below it must truly
  # re-execute (same-sha commits would be skipped)
  GIT_SEQUENCE_EDITOR='sed -i "s/^pick \([0-9a-f]*\) # ours/edit \1 # ours/"' git rebase -i -r "$BASE" >/dev/null 2>&1 || true
  echo ctl-marker >ctl-marker.txt
  git add ctl-marker.txt && git commit -q --amend --no-edit
  GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || true
  # it stops at the ORIGINAL conflict, not a re-merge of the chain
  [ -n "$(git ls-files --unmerged -- f.txt)" ] ||
    fail "the re-execution did not stop at the original conflict"
  printf 'a\nRESOLVED\nc\n' >f.txt && git add f.txt
  GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
  [ "$(git rev-list --parents -n 1 HEAD | wc -w)" = "3" ] ||
    fail "the merge was dropped from the rewritten history"
  [ "$(git ls-tree -r HEAD | grep -c hangar)" = "0" ] ||
    fail "the hangar leaked into the recreated merge"
  [ "$(git cat-file blob HEAD:f.txt)" = "a
RESOLVED
c" ] || fail "the recreated merge lost the resolution"
}

@test "C12: a hand-run merge parks directly onto the carrier you name: no recipe to remember" {
  conflict_repo c12
  SRC=$(git rev-parse side)
  # hand-started: park relocates the user's own merge onto a carrier of their choosing
  run git park -b carrier/hand
  assert_success
  assert_output --partial "main stays at"
  [ "$(git rev-parse main)" = "$O" ] || fail "the hand-started park moved main"
  git commit -qm "parked A"
  # the recorded message is the one git rendered on main: the merge was never recreated
  [ "$(git cat-file blob HEAD:.hangar/message)" = "Merge branch 'side'" ] ||
    fail "the hand-started park re-rendered the message: [$(git cat-file blob HEAD:.hangar/message)]"
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git rm -q -r .hangar/stages/f.txt && git commit -qm resolve
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$(git rev-parse carrier/hand)" "commit '$SRC'"
  git commit -qm finished
  [ "$(git rev-parse main^1)" = "$O" ]
  [ "$(git rev-parse main^2)" = "$SRC" ]
}

@test "C13: handoff: push the carrier, clone, drive the landing on the second clone" {
  mkrepo c13
  printf 'a\nb\nc\n' >f.txt && git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >f.txt && git add -A && git commit -qm ours
  O=$(git rev-parse HEAD)
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt && git add -A && git commit -qm theirs
  git tag -a v1.2.3 -m "release v1.2.3" side
  SRC=$(git rev-parse 'v1.2.3^{commit}')
  git checkout -q main
  git clone -q --bare "$REPO" "$CARRIER_WORK/c13bare.git"
  git remote add origin "$CARRIER_WORK/c13bare.git"
  # machine 1: the stopped merge, parked and resolved on the carrier
  git merge v1.2.3 >/dev/null 2>&1 || true
  git park -b carrier/v1.2.3 >/dev/null
  git commit -qm parked
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git rm -q -r .hangar/stages/f.txt && git commit -qm resolve
  git push -q origin main carrier/v1.2.3 v1.2.3
  # machine 2: clone, stand on the chain, drive the same landing
  git clone -q "$CARRIER_WORK/c13bare.git" "$CARRIER_WORK/c13b"
  cd "$CARRIER_WORK/c13b"
  git config user.email a@b.c && git config user.name T
  git checkout -q -b carrier/v1.2.3 origin/carrier/v1.2.3
  [ "$(git rev-parse main)" = "$(git rev-parse 'origin/main')" ] ||
    fail "fixture: the clone's main is not at O"
  # the stage files traveled byte-exact through the push and the clone
  assert_hangar "$(git rev-parse carrier/v1.2.3)"
  run git land main
  assert_success
  assert_prepared main "$O" "$(git rev-parse v1.2.3)" "$(git rev-parse carrier/v1.2.3)" "tag 'v1.2.3'"
  git commit -qm "landed on machine 2"
  [ "$(git rev-parse main^2)" = "$SRC" ] ||
    fail "the second landing's second parent is not the source"
  [ "$(git ls-tree -r main | grep -c hangar)" = "0" ]
  git checkout -q carrier/v1.2.3
  run git land main
  assert_success
  assert_output --partial "this merge already landed"
}

@test "C14: linked worktree end to end; dst checked out elsewhere is refused" {
  conflict_repo c14
  SRC=$(git rev-parse side)
  git worktree add -q "$CARRIER_WORK/c14wt" -b worker main
  cd "$CARRIER_WORK/c14wt"
  # the whole cycle runs in a linked worktree, where .git is a file: --git-path must locate every
  # MERGE_* correctly
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/lb >/dev/null
  [ "$(git symbolic-ref --short HEAD)" = "carrier/lb" ] ||
    fail "the park failed in the linked worktree"
  git commit -qm parked
  git unpark f.txt >/dev/null
  git show :2:f.txt >f.txt && git add f.txt
  git commit -qm resolve
  # the destination (main) is checked out in the primary worktree: the landing is refused without
  # moving it
  git branch -f main "$O" 2>/dev/null || true
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "worktree"
  # land onto worker's own rescue branch instead: the chain moves off
  git switch -q -c rescue
  run git land worker
  assert_success
  assert_prepared worker "$O" "$SRC" "$(git rev-parse rescue)" "commit '$SRC'"
  git commit -qm finished
  [ "$(git rev-parse worker^2)" = "$SRC" ]
}

@test "C15: -z filenames: spaces, quotes, UTF-8, tab, newline through park, unpark, land" {
  mkrepo c15
  local n1="with space.txt"
  local n2="with'quote.txt"
  local n3="héllo-wörld.txt"
  local n4="$(printf 'with\ttab.txt')"
  local n5="$(printf 'with\nnewline.txt')"
  printf 'base\n' >"$n1"
  printf 'base\n' >"$n2"
  printf 'base\n' >"$n3"
  printf 'base\n' >"$n4"
  printf 'base\n' >"$n5"
  git add -A && git commit -qm base
  git branch side
  printf 'ours\n' >"$n1"
  printf 'ours\n' >"$n2"
  printf 'ours\n' >"$n3"
  printf 'ours\n' >"$n4"
  printf 'ours\n' >"$n5"
  git add -A && git commit -qm ours
  O=$(git rev-parse HEAD)
  git checkout -q side
  printf 'theirs\n' >"$n1"
  printf 'theirs\n' >"$n2"
  printf 'theirs\n' >"$n3"
  printf 'theirs\n' >"$n4"
  printf 'theirs\n' >"$n5"
  git add -A && git commit -qm theirs
  SRC=$(git rev-parse side)
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  run git park -b carrier/lb
  assert_success
  git commit -qm parked
  # every name round-tripped into the hangar
  local n
  for n in "$n1" "$n2" "$n3" "$n4" "$n5"; do
    git cat-file -e "HEAD:.hangar/stages/$n/2" ||
      fail "stage file 2 of [$n] did not round-trip through park"
  done
  # unpark them all (unchanged: they reopen), resolve, release
  run git unpark
  assert_success
  # the unpark above released every directory; resolve the reopened content and commit
  for n in "$n1" "$n2" "$n3" "$n4" "$n5"; do
    git show ":2:$n" >"$n" && git add -- "$n"
  done
  git commit -qm resolve
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$(git rev-parse carrier/lb)" "commit '$SRC'"
  git commit -qm finished
  # the landed tree carries every name, byte-exact
  for n in "$n1" "$n2" "$n3" "$n4" "$n5"; do
    [ "$(git cat-file blob "main:$n")" = "ours" ] || fail "[$n] did not land byte-exact"
  done
  [ "$(git ls-tree -r main | grep -c hangar)" = "0" ]
}

@test "C16: the exit codes" {
  mkrepo c16
  printf 'a\n' >f.txt && git add -A && git commit -qm base
  # 129: usage: wrong arg count, unknown flag, the bare run
  run git land
  [ "$status" -eq 129 ]
  run git land one two
  [ "$status" -eq 129 ]
  run git park --nonsense
  [ "$status" -eq 129 ]
  run bash "$CARRIER_BIN/git-carrier.bash"
  [ "$status" -eq 129 ]
  # 1: error: not a repository, a missing dst branch
  cd "$CARRIER_WORK"
  run git park
  [ "$status" -eq 1 ]
  cd "$REPO"
  run git land nosuchbranch
  [ "$status" -eq 1 ]
  # 2: refusal: state a user can change (unmerged paths on a hand-run merge)
  git branch side
  printf 'b\n' >f.txt && git add -A && git commit -qm ours
  git checkout -q side && printf 'c\n' >f.txt && git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  run git land main
  [ "$status" -eq 2 ]
  # 0: success and the no-ops
  run git park --version
  [ "$status" -eq 0 ]
  run git park -b carrier/side
  [ "$status" -eq 0 ]
  git commit -qm parked
  printf 'c\n' >f.txt && git add f.txt && git rm -q -r .hangar/stages/f.txt && git commit -qm resolve
  run git land main
  [ "$status" -eq 0 ]
  git commit -qm finished
  git checkout -q carrier/side
  run git land main
  [ "$status" -eq 0 ]
  assert_output --partial "this merge already landed"
}

@test "C17: the landed message is rendered for the destination, never naming the carrier" {
  conflict_repo c17
  git merge --abort
  tag_the_source
  git merge v1.2.3 >/dev/null 2>&1 || true
  git park -b carrier/v1.2.3 >/dev/null && git commit -qm "park: merge of v1.2.3"
  git unpark >/dev/null
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git commit -qm resolve
  run git land main
  assert_success
  git commit -q --no-edit
  [ "$(git log -1 --format=%s main)" = "Merge tag 'v1.2.3'" ] ||
    fail "the landed subject is not exactly the render for main: $(git log -1 --format=%s main)"
  if git log -1 --format=%B main | grep -q carrier; then
    fail "the landed message names the carrier branch"
  fi
  if git log -1 --format=%B main | grep -q 'Message recorded at park'; then
    fail "matching render and record still produced a comment block"
  fi
  git log -1 --format=%B main | grep -q 'release v1.2.3' ||
    fail "the tag body did not travel with the fresh render"
}

@test "C18: fan-out/fan-in: disjoint resolutions joined by a plain merge land from the join tip" {
  fanin_origin c18
  # both workers start from the same parked tip
  fanin_clone w1
  fanin_clone w2
  # worker 1 resolves a.txt and pushes
  cd "$CARRIER_WORK/w1" || fail "cd w1"
  fanin_resolve a.txt BY-W1
  git push -q origin carrier/v1
  # worker 2 resolves b.txt and c.txt, then merges worker 1's carrier: the join tip
  cd "$CARRIER_WORK/w2" || fail "cd w2"
  fanin_resolve b.txt BY-W2
  fanin_resolve c.txt BY-W2
  git fetch -q origin
  git merge -q --no-edit origin/carrier/v1 ||
    fail "the fan-in merge of disjoint resolutions should be clean"
  [ "$(git rev-list --parents -n 1 HEAD | wc -w)" = "3" ] ||
    fail "fixture: the chain tip is not the join commit"
  [ -z "$(git ls-tree -r HEAD -- .hangar/stages)" ] ||
    fail "fixture: the join tip still has held paths"
  grep -q BY-W1 a.txt || fail "a.txt lost w1's resolution"
  grep -q BY-W2 b.txt || fail "b.txt lost w2's resolution"
  # land from the join tip (the clone's local main sits at O)
  local tip
  tip=$(git rev-parse HEAD)
  run git land main
  assert_success
  assert_prepared main "$O" "$TAGV" "$tip" "tag 'v1'"
  git commit -qm "landed the join"
  [ "$(git rev-parse main^1)" = "$O" ] || fail "first parent is not the pre-merge tip"
  [ "$(git rev-parse main^2)" = "$SRC" ] || fail "second parent is not the source"
  grep -q BY-W1 a.txt && grep -q BY-W2 b.txt && grep -q BY-W2 c.txt ||
    fail "the landed tree lost a worker's resolution"
  [ "$(git ls-tree -r main | grep -c hangar)" = "0" ] || fail "the landed merge carries the hangar"
}

@test "C19: unpark on a join tip reopens a still-held path" {
  fanin_origin c19
  # both workers start from the same parked tip
  fanin_clone w1
  fanin_clone w2
  cd "$CARRIER_WORK/w1" || fail "cd w1"
  fanin_resolve a.txt BY-W1
  git push -q origin carrier/v1
  cd "$CARRIER_WORK/w2" || fail "cd w2"
  fanin_resolve b.txt BY-W2
  git fetch -q origin
  git merge -q --no-edit origin/carrier/v1 || fail "the fan-in merge failed"
  [ "$(git rev-list --parents -n 1 HEAD | wc -w)" = "3" ] ||
    fail "fixture: the chain tip is not the join commit"
  [ -n "$(git ls-tree -r HEAD -- .hangar/stages/c.txt)" ] ||
    fail "fixture: c.txt is not still held on the join tip"
  run git unpark c.txt
  assert_success
  assert_output --partial "unchanged (reopened): c.txt"
  [ "$(git ls-files -s -- c.txt | grep -c .)" = "3" ] ||
    fail "the reopen did not restore stages 1/2/3"
  # and the chain still lands after the join-tip unpark
  printf 'c\nBY-W2\n' >c.txt
  git add c.txt && git commit -qm "resolve c.txt"
  local tip
  tip=$(git rev-parse HEAD)
  run git land main
  assert_success
  assert_prepared main "$O" "$TAGV" "$tip" "tag 'v1'"
}

@test "C20: a sha256 repository round-trips park, unpark, and land" {
  if ! git init -q -b main --object-format=sha256 "$CARRIER_WORK/c20" 2>/dev/null; then
    skip "this git has no sha256 repository support"
  fi
  REPO="$CARRIER_WORK/c20"
  cd "$REPO" || fail "cd $REPO"
  git config user.email a@b.c && git config user.name T
  printf 'a\nb\nc\n' >f.txt && git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >f.txt && git commit -qam ours
  O=$(git rev-parse HEAD)
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt && git commit -qam theirs
  git tag -a v1 -m "release v1"
  TAGV=$(git rev-parse v1)
  SRC=$(git rev-parse 'v1^{commit}')
  git checkout -q main
  git merge v1 >/dev/null 2>&1 || true
  git park -b carrier/v1 >/dev/null && git commit -qm parked
  # the regression: the reopen fed a sha1-length zero id and died mid-unpark
  run git unpark
  assert_success
  assert_output --partial "unchanged (reopened): f.txt"
  [ "$(git ls-files -s -- f.txt | grep -c .)" = "3" ] ||
    fail "the reopen did not restore stages 1/2/3"
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git commit -qm resolve
  local tip
  tip=$(git rev-parse carrier/v1)
  run git land main
  assert_success
  assert_prepared main "$O" "$TAGV" "$tip" "tag 'v1'"
  git commit -q --no-edit
  [ "$(git rev-parse main^1)" = "$O" ] || fail "first parent is not the pre-merge tip"
  [ "$(git rev-parse main^2)" = "$SRC" ] || fail "second parent is not the source"
}
