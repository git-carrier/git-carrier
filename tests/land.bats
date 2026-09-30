# land.bats: the states land recognizes, the landing machinery, and every check.

load helpers

setup() {
  setup_scratch
}

teardown() {
  teardown_scratch
}

# A parked chain tip on <carrier>: park moves conflict_repo's stopped merge onto the carrier
# (main stays at O) and the user's commit creates the chain. Sets O, SRC, and CARRIER.
parked_chain() {
  conflict_repo "$1"
  SRC=$(git rev-parse side)
  CARRIER="carrier/$2"
  git park -b "$CARRIER" >/dev/null
  git commit -qm parked
}

# A complete chain tip on <carrier>: every path resolved and released, still standing on it.
complete_chain() {
  parked_chain "$1" "$2"
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt
  git rm -q -r .hangar/stages/f.txt
  git commit -qm resolve
}

@test "usage: <dst> is the one argument; --branch is gone; a missing dst is an error" {
  conflict_repo u1
  run git land
  [ "$status" -eq 129 ]
  assert_output --partial "git land takes <dst>"
  run git land a b
  [ "$status" -eq 129 ]
  assert_output --partial "too many arguments"
  run git land main --branch lb
  [ "$status" -eq 129 ]
  assert_output --partial "unknown flag"
  run git land nosuchbranch
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "no such local branch"
}

@test "case 1: a live merge with unmerged paths is reported, park is the relocation" {
  conflict_repo l5
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "unmerged path"
  assert_output --partial "f.txt"
  assert_output --partial "finish it yourself"
  assert_output --partial "git park --branch <name>"
  # the report is not a refusal of the merge: it is left standing exactly as it was
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] || fail "the report disturbed the live merge"
  [ "$(git rev-parse main)" = "$O" ] || fail "the report moved main"
}

@test "case 1: none unmerged; land refuses, the user's own git commit finishes" {
  conflict_repo l7
  SRC=$(git rev-parse side)
  git show :2:f.txt >f.txt
  git add f.txt
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "already prepared with no unmerged paths"
  assert_output --partial "land never finishes a live merge"
  # the live merge is left standing exactly as it was: main untouched, nothing created
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] || fail "the refusal disturbed the live merge"
  [ "$(git rev-parse main)" = "$O" ] || fail "the refusal moved main"
  git commit -qm finished
  [ "$(git rev-list --parents -n 1 HEAD | wc -w)" = "3" ] ||
    fail "the user's own commit did not finish the merge"
  [ "$(git rev-parse HEAD^2)" = "$SRC" ] ||
    fail "the finished merge's second parent is not the source"
}

@test "case 1: an octopus live here is refused, not finished" {
  mkrepo l7b
  printf 'a\n' >f.txt && git add -A && git commit -qm base
  git branch b1 && git branch b2
  printf 'one\n' >one.txt && git add -A && git commit -qm c1
  git checkout -q b1 && printf 'b1\n' >f.txt && git add -A && git commit -qm B1
  git checkout -q b2 && printf 'b2\n' >f.txt && git add -A && git commit -qm B2
  git checkout -q main
  git merge b1 b2 >/dev/null 2>&1 || true
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "octopus"
  assert_output --partial "MERGE_HEAD lists 2 heads"
}

@test "case 2: HEAD is not a chain; the refusal names the switch, wherever HEAD is" {
  mkrepo l8
  printf 'a\n' >f.txt && git add -A && git commit -qm base
  git branch side && printf 'b\n' >f.txt && git add -A && git commit -qm ours
  # from a plain branch that never carried a chain
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "not a parked merge"
  assert_output --partial "switch to the carrier branch"
  # and from the destination after a landing: the chain is done
  complete_chain l8b lb
  run git land main
  assert_success
  git commit -qm finished
  git checkout -q main
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "not a parked merge"
  case $output in
  *"already merged"*) fail "the old already-merged exit still exists" ;;
  esac
}

@test "case 3: paths still held are reported with the unpark hint, mutating nothing" {
  parked_chain l13 lb
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "conflicts are still held"
  assert_output --partial "f.txt"
  assert_output --partial "git unpark"
  [ "$(git rev-parse main)" = "$O" ] || fail "the held-paths report moved main"
}

@test "case 3: a path resolved and committed without its release is only missing the release" {
  # the usual forgetting point: fixed, added, committed, the release never run. The hangar
  # still holds it, but the tip carries the resolution, so the refusal names only the missing
  # release, not a reopen of work that is already done.
  parked_chain l13r lr
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt
  git commit -qm resolve
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "already resolved but not released: f.txt"
  assert_output --partial "git rm its .hangar/stages/<path>"
  case $output in
  *"reopen and resolve"*) fail "a resolved path was told to reopen" ;;
  esac
  [ "$(git rev-parse main)" = "$O" ] || fail "the report moved main"
  # the named recovery is the whole missing step: release, commit, land
  git rm -q -r .hangar/stages/f.txt
  git commit -qm release
  run git land main
  assert_success
  assert_output --partial "prepared the landing on main"
}

@test "case 3: a mode-only resolution already committed is missing only the release" {
  # the usual forgetting point, mode edition: chmod resolved the file, added, committed,
  # the release never run. The tip carries the same blob as w with a different mode, so it
  # is a resolution already committed, not an unchanged state to reopen
  parked_chain l13m2 lb
  chmod 755 f.txt
  git add f.txt
  git commit -qm "resolve by mode only"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "already resolved but not released: f.txt"
  case $output in
  *"still unchanged"*) fail "a mode-only resolution was reported as unchanged" ;;
  esac
  git rm -q -r .hangar/stages/f.txt
  git commit -qm release
  run git land main
  assert_success
  git commit -qm finished
  [ "$(git ls-tree main -- f.txt | awk '{print $1}')" = "100755" ] ||
    fail "the landed tree lost the resolution's mode"
}

@test "case 3: mixed held paths are reported one line per group, each with its recovery" {
  mkrepo l13m
  printf 'a\nb\nc\n' >f.txt
  printf 'g\n' >g.txt
  git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >f.txt
  printf 'OURS-g\n' >g.txt
  git add -A && git commit -qm ours
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt
  printf 'THEIRS-g\n' >g.txt
  git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/lm >/dev/null && git commit -qm parked
  # f.txt resolved and committed (the release forgotten); g.txt never touched
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt
  git commit -qm resolve-one
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "still unchanged: g.txt"
  assert_output --partial "already resolved but not released: f.txt"
  assert_output --partial "1 conflict still unchanged and 1 resolution committed but not released"
  assert_output --partial "unpark, fix, add, and commit unchanged paths"
  assert_output --partial "unpark already-resolved paths and commit their releases"
}

@test "case 3: paths nested under each other are each listed once, in record order" {
  mkrepo lnest
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  git branch side
  git checkout -q side
  printf 'theirs\n' >keep.txt
  git commit -qam theirs
  SRC=$(git rev-parse side)
  git checkout -q main
  # a hand-built hangar (git's own D/F handling renames colliding paths, so no merge parks these):
  # a holds 1/2/3/w, a/2z holds 1, a/b holds 3. '2z' parks between a's 2 and 3 and 'b' between
  # its 3 and w, splitting a's records three ways; the held list must still take each path once,
  # in record order
  mkdir -p .hangar/stages/a/2z .hangar/stages/a/b
  printf 'base\n' >.hangar/stages/a/1
  printf 'ours\n' >.hangar/stages/a/2
  printf 'theirs\n' >.hangar/stages/a/3
  printf 'worktree-a\n' >.hangar/stages/a/w
  printf 'nested-z\n' >.hangar/stages/a/2z/1
  printf 'nested-b\n' >.hangar/stages/a/b/3
  craft_hangar "$SRC"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "still unchanged: a/2z, a/b"
  assert_output --partial "already resolved but not released: a"
  assert_output --partial "2 conflicts still unchanged and 1 resolution committed but not released"
  [ "$(git rev-parse main)" = "$(git rev-parse HEAD)" ] || fail "the held-paths report moved main"
}

@test "case 3: w-only directories nested under each other list once, in record order" {
  mkrepo lnestw
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  git branch side
  git checkout -q side
  printf 'theirs\n' >keep.txt
  git commit -qam theirs
  SRC=$(git rev-parse side)
  git checkout -q main
  # every path holds only file w: 'b' sorts under 'w', so a/b/w parks before a/w and the
  # w-only list is a/b, then a
  mkdir -p .hangar/stages/a/b
  printf 'worktree-a\n' >.hangar/stages/a/w
  printf 'worktree-b\n' >.hangar/stages/a/b/w
  craft_hangar "$SRC"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "incomplete hangar: .hangar/stages/ holds only file w at: a/b, a"
}

@test "case 3: a stage file sorting after w keeps the held list one entry per path" {
  mkrepo lnestz
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  git branch side
  git checkout -q side
  printf 'theirs\n' >keep.txt
  git commit -qam theirs
  SRC=$(git rev-parse side)
  git checkout -q main
  # land classifies leniently (naming a mangled hangar is unpark's refusal), so the walk meets
  # stage file names outside 1-3 and w: 'zz' sorts after 'w', so a resumes after the nested a/x,
  # and a must still be listed once
  mkdir -p .hangar/stages/a/x
  printf 'base\n' >.hangar/stages/a/1
  printf 'worktree-a\n' >.hangar/stages/a/w
  printf 'odd\n' >.hangar/stages/a/zz
  printf 'nested\n' >.hangar/stages/a/x/1
  craft_hangar "$SRC"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "still unchanged: a/x"
  assert_output --partial "already resolved but not released: a"
  assert_output --partial "1 conflict still unchanged and 1 resolution committed but not released"
  # the same hangar is unpark's mangled-hangar refusal
  run git unpark
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "mangled hangar: .hangar/stages/a/zz is not a stage file"
}

@test "case 3: mixed-length paths nested under each other list once, in record order" {
  mkrepo lsorted
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  git branch side
  git checkout -q side
  printf 'theirs\n' >keep.txt
  git commit -qam theirs
  SRC=$(git rev-parse side)
  git checkout -q main
  # a mixed-length set: 'a/c' parks before 'ab' ('/' sorts under 'b'), and s/-x parks before
  # every record of s ('-' sorts under '1'), so the walk meets the parent after the nested
  # path, once; the held list reads in record order: a/c, ab, s/-x, s, z. Every path holds
  # stage 1 only and no w, and the tip carries none of them, so all five are unchanged.
  mkdir -p .hangar/stages/a/c .hangar/stages/ab '.hangar/stages/s/-x' .hangar/stages/s .hangar/stages/z
  printf 'x\n' >.hangar/stages/a/c/1
  printf 'x\n' >.hangar/stages/ab/1
  printf 'x\n' >.hangar/stages/s/1
  printf 'x\n' >'.hangar/stages/s/-x/1'
  printf 'x\n' >.hangar/stages/z/1
  craft_hangar "$SRC"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "conflicts are still held: a/c, ab, s/-x, s, z"
  [ "$(git rev-parse main)" = "$(git rev-parse HEAD)" ] || fail "the held-paths report moved main"
}

@test "case 3: a manifest missing a field is incomplete and refused" {
  complete_chain l32 lb
  printf 'hangar-format: 1\nsource: %s\n' "$SRC" >.hangar/manifest
  git add .hangar/manifest && git commit -qm "drop the desc"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "no source-desc"
  assert_output --partial "incomplete"
  printf "hangar-format: 1\nsource-desc: commit '$SRC'\n" >.hangar/manifest
  git add .hangar/manifest && git commit -qm "drop the source"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "no source"
}

@test "case 3: a mangled manifest is refused, never misread as no chain" {
  complete_chain l32m lb
  printf 'hangar-format: 1\nsource: %s\nsource: %s\nsource-desc: commit x\n' "$SRC" "$SRC" >.hangar/manifest
  git add .hangar/manifest && git commit -qm "duplicate the source"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "source appears twice"
  printf 'hangar-format: 1\nhangar-format: 1\nsource: %s\nsource-desc: commit x\n' "$SRC" >.hangar/manifest
  git add .hangar/manifest && git commit -qm "misplace the format line"
  run git land main
  assert_failure
  assert_output --partial "reserved for the format line"
  printf 'hangar-format: 1\nSource: %s\nsource-desc: commit x\n' "$SRC" >.hangar/manifest
  git add .hangar/manifest && git commit -qm "uppercase the name"
  run git land main
  assert_failure
  assert_output --partial "is not a field"
  printf 'hangar-format: 1\n\nsource: %s\nsource-desc: commit x\n' "$SRC" >.hangar/manifest
  git add .hangar/manifest && git commit -qm "blank line"
  run git land main
  assert_failure
  assert_output --partial "is not a field"
  printf 'hangar-format: 1\nsource: %s\0x\nsource-desc: commit x\n' "$SRC" >.hangar/manifest
  git add .hangar/manifest && git commit -qm "nul byte"
  run git land main
  assert_failure
  assert_output --partial "NUL"
  printf 'hangar-format: 1\nsource: not-an-object-id\nsource-desc: commit x\n' >.hangar/manifest
  git add .hangar/manifest && git commit -qm "break the source"
  run git land main
  assert_failure
  assert_output --partial "not an object id"
  # a known value is non-empty and never begins with a space
  printf 'hangar-format: 1\nsource: %s\nsource-desc:\n' "$SRC" >.hangar/manifest
  git add .hangar/manifest && git commit -qm "empty the desc"
  run git land main
  assert_failure
  assert_output --partial "source-desc's value"
  printf 'hangar-format: 1\nsource: %s\nsource-desc:  commit x\n' "$SRC" >.hangar/manifest
  git add .hangar/manifest && git commit -qm "pad the desc"
  run git land main
  assert_failure
  assert_output --partial "begins with a space"
  case $output in
  *"not a parked merge"*) fail "the damaged chain was misread as no chain" ;;
  esac
}

@test "case 3: the source not present in this clone is refused, the desc naming what to fetch" {
  mkrepo l33
  printf 'a\nb\nc\n' >f.txt && git add -A && git commit -qm base
  # the bare is cloned before side exists, so a push of the carrier shares no source with it
  git clone -q --bare "file://$REPO" "$CARRIER_WORK/l33origin.git"
  git remote add origin "$CARRIER_WORK/l33origin.git"
  git branch side
  printf 'a\nOURS\nc\n' >f.txt && git add -A && git commit -qm ours
  O=$(git rev-parse HEAD)
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt && git add -A && git commit -qm theirs
  git tag -a v1.2.3 -m "release v1.2.3"
  TAGV=$(git rev-parse v1.2.3)
  git checkout -q main
  git merge v1.2.3 >/dev/null 2>&1 || true
  git park -b carrier/lb >/dev/null
  git commit -qm parked
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git rm -q -r .hangar/stages/f.txt && git commit -qm resolve
  git push -q origin main carrier/lb
  git clone -q "$CARRIER_WORK/l33origin.git" "$CARRIER_WORK/l33clone"
  cd "$CARRIER_WORK/l33clone" || return 1
  git config user.email a@b.c && git config user.name T
  git switch -q -c carrier/lb origin/carrier/lb
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "is not present here"
  assert_output --partial "fetch it (tag 'v1.2.3'), then re-run"
  # the named ref, pushed and fetched, is the whole recovery
  git -C "$REPO" push -q origin v1.2.3
  git fetch -q origin "refs/tags/v1.2.3:refs/tags/v1.2.3"
  run git land main
  assert_success
  assert_prepared main "$O" "$TAGV" "$(git rev-parse carrier/lb)" "tag 'v1.2.3'"
}

@test "case 3: an id-only desc is refused with the ref to look for, never a bare id to fetch" {
  # the merge's source is a local branch, never pushed under any name: the desc freezes
  # to the id-only class, and no landing elsewhere can fetch it by that label
  mkrepo l33b
  printf 'a\nb\nc\n' >f.txt && git add -A && git commit -qm base
  # the bare is cloned before side exists, so a push of the carrier shares no source with it
  git clone -q --bare "file://$REPO" "$CARRIER_WORK/l33borigin.git"
  git remote add origin "$CARRIER_WORK/l33borigin.git"
  git branch side
  printf 'a\nOURS\nc\n' >f.txt && git add -A && git commit -qm ours
  O=$(git rev-parse HEAD)
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt && git add -A && git commit -qm theirs
  SRC=$(git rev-parse side)
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  run git park -b carrier/lb
  assert_success
  git commit -qm parked
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git rm -q -r .hangar/stages/f.txt && git commit -qm resolve
  git push -q origin main carrier/lb
  git clone -q "$CARRIER_WORK/l33borigin.git" "$CARRIER_WORK/l33bclone"
  cd "$CARRIER_WORK/l33bclone" || return 1
  git config user.email a@b.c && git config user.name T
  git switch -q -c carrier/lb origin/carrier/lb
  [ "$(manifest_value HEAD source-desc)" = "commit '$SRC'" ] ||
    fail "fixture: the desc is not the id-only class: [$(manifest_value HEAD source-desc)]"
  SHORT=$(git rev-parse --short "$SRC")
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "is not present here"
  assert_output --partial "the source is recorded by id, not by name; fetch it from a remote that has it (a branch or tag at $SHORT), then re-run"
  case $output in
  *"fetch it (commit"*) fail "the old dead-end hint survives (output: $output)" ;;
  esac
  # the recovery works: the source pushed under a name, then fetched here by that name
  git -C "$REPO" push -q origin side
  git fetch -q origin "refs/heads/side:refs/remotes/origin/side"
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$(git rev-parse carrier/lb)" "commit '$SRC'"
}

@test "case 3: the landed chain is the idempotent no-op, wherever dst went after the landing" {
  complete_chain l9 lb
  run git land main
  assert_success
  git commit -qm finished
  # from the chain, right after the landing
  git checkout -q carrier/lb
  run git land main
  assert_success
  assert_output --partial "this merge already landed in main"
  # and after <dst> moved on: the landing is still in its history
  git checkout -q main
  printf 'after\n' >h.txt && git add h.txt && git commit -qm moved-on
  git checkout -q carrier/lb
  run git land main
  assert_success
  assert_output --partial "this merge already landed"
}

@test "case 3: another chain's landing of the same source does not strand this chain" {
  # the regression the tree comparison exists for: the release reaching <dst> any other way used
  # to read as "already merged", exit 0, stranding this chain unfinished, because ancestry
  # survives a revert.
  complete_chain l9b lb
  printf 'a\nRESOLVED-OUR-WAY\nc\n' >f.txt
  git add f.txt && git commit -qm "resolve our way"
  # while the chain is worked, a colleague lands the same source their own way on main
  git checkout -q main
  git show side:f.txt >f.txt && git add f.txt && git commit -qm ours-take-theirs
  git merge --no-edit -m "colleague: their landing" side >/dev/null 2>&1 || true
  [ "$(git rev-parse main^2)" = "$(git rev-parse side)" ] ||
    fail "fixture: the colleague's landing did not finish"
  git checkout -q carrier/lb
  # the colleague's landing is not this chain's landing (a different tree, so no match): the
  # check names the landing it would supersede, the landing prepares over it superseding and
  # naming the colleague's landing, and this chain's own resolutions finish
  run git land --check main
  assert_success
  assert_output --partial "a landing supersedes main's previous landing"
  assert_output --partial "check: ready to land MERGE_HEAD ($(git rev-parse --short "$SRC")) from carrier/lb onto main ($(git rev-parse --short "$O"))"
  run git land main
  assert_success
  case $output in
  *"already"*) fail "the colleague's landing still strands this chain at exit 0" ;;
  esac
  assert_output --partial "superseded main's previous landing"
  assert_output --partial "main@{1}"
  assert_output --partial "prepared the landing on main"
  git commit -qm "our landing after all"
  [ "$(git show main:f.txt)" = "a
RESOLVED-OUR-WAY
c" ] || fail "this chain's resolutions did not land"
  [ "$(git rev-parse main^2)" = "$(git rev-parse side)" ] ||
    fail "our landing's second parent is not the source"

  # a dst that moved PAST the colleague's landing is not an allowed position: the refusal names
  # the rebase and the reset, and the user's own reset then lands this chain's resolutions
  complete_chain l9c lb2
  printf 'a\nRESOLVED-AGAIN\nc\n' >f.txt
  git add f.txt && git commit -qm "resolve again"
  git checkout -q main
  git show side:f.txt >f.txt && git add f.txt && git commit -qm ours-take-theirs-2
  git merge --no-edit -m "colleague: their landing 2" side >/dev/null 2>&1 || true
  printf 'carried on\n' >h.txt && git add h.txt && git commit -qm carried-on
  git checkout -q carrier/lb2
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  case $output in
  *"already"*) fail "the colleague's landing still strands this chain at exit 0" ;;
  esac
  assert_output --partial "cannot move from"
  assert_output --partial "git rebase"
  assert_output --partial "git branch -f main"
  # the user's own reset, the refusal's exact recipe, then the landing
  git branch -f main "$O"
  run git land main
  assert_success
  git commit -qm "our landing after all 2"
  [ "$(git show main:f.txt)" = "a
RESOLVED-AGAIN
c" ] || fail "this chain's resolutions did not land"
}

@test "case 3 complete: the landing is prepared from the carrier branch" {
  complete_chain l15 lb
  local tip
  tip=$(git rev-parse carrier/lb)
  run git land main
  assert_success
  assert_output --partial "prepared the landing on main"
  assert_prepared main "$O" "$SRC" "$tip" "commit '$SRC'"
  git commit -qm finished
  [ "$(git rev-parse main^1)" = "$O" ] || fail "the landed merge's first parent is not O"
  [ "$(git rev-parse main^2)" = "$SRC" ] ||
    fail "the landed merge's second parent is not the source"
  [ "$(git ls-tree -r main | grep -c hangar)" = "0" ] || fail "the landed merge carries the hangar"
  [ "$(git rev-parse carrier/lb)" = "$tip" ] || fail "the chain did not survive on the carrier"
}

@test "a landing in a clone prints only land's report, never the switch's chatter" {
  # switch -C to a branch with an upstream prints its tracking hint to stdout ("Your branch is
  # up to date with 'origin/main'."); a clone's destination branch tracks its origin. The landing
  # captures both: land's report is the only output.
  complete_chain l35 lb
  git clone -q "file://$REPO" "$CARRIER_WORK/clone"
  git -C "$CARRIER_WORK/clone" config user.email a@b.c
  git -C "$CARRIER_WORK/clone" config user.name T
  cd "$CARRIER_WORK/clone" || return 1
  git switch -q -c main origin/main
  git switch -q carrier/lb
  run git land main
  assert_success
  assert_output --partial "prepared the landing on main"
  case $output in
  *"Your branch"*) fail "the switch's tracking hint leaked into the report" ;;
  *"Switched to branch"*) fail "the switch's own line leaked into the report" ;;
  esac
  git commit -qm finished
  [ "$(git rev-parse main^2)" = "$SRC" ] || fail "the landing is not [base, source]"
}

@test "case 3: a detached chain tip is refused with the switch recovery" {
  complete_chain l16 lb
  git checkout -q --detach
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "detached HEAD"
  assert_output --partial "git switch -c"
  # a landed chain is the no-op even from a detached tip: nothing is left to move
  git switch -q carrier/lb
  git land main >/dev/null
  git commit -qm finished
  git switch -q --detach carrier/lb
  run git land main
  assert_success
  assert_output --partial "this merge already landed"
}

@test "dst-position check: behind O is a fast-forward position and lands" {
  complete_chain l22 lb
  BASE=$(git rev-parse "$O~1")
  git branch -f main "$BASE"
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$(git rev-parse carrier/lb)" "commit '$SRC'"
}

@test "dst-position check: dst at the chain tip may move" {
  complete_chain l23 lb
  git branch -f main "$(git rev-parse carrier/lb)"
  local tip
  tip=$(git rev-parse carrier/lb)
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$tip" "commit '$SRC'"
  git commit -qm finished
  [ "$(git rev-parse carrier/lb)" = "$tip" ] || fail "the chain did not survive on the carrier"
  [ "$(git rev-parse main^1)" = "$O" ] || fail "the landed merge's first parent is not O"
}

@test "a re-land after a chain rewrite: the already-landed exit, then a clean re-land" {
  complete_chain l24 lb
  git land main >/dev/null
  git commit -qm "first landing"
  M1=$(git rev-parse main)
  # rewrite the chain: squash the parked chain onto one commit. The resolved tree does not change,
  # so the landing still matches the rewritten chain
  git checkout -q carrier/lb
  GIT_SEQUENCE_EDITOR='sed -i "2s/^pick/fixup/"' git rebase -i "$O" >/dev/null 2>&1
  local newtip
  newtip=$(git rev-parse carrier/lb)
  git checkout -q carrier/lb
  run git land main
  assert_success
  assert_output --partial "this merge already landed"
  # move dst off the landing, and the rewritten chain re-lands cleanly
  git branch -f main "$O"
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$newtip" "commit '$SRC'"
  git commit -qm "second landing"
  [ "$(git rev-parse main)" != "$M1" ] || fail "the re-land produced the same commit"
  [ "$(git rev-parse main^2)" = "$SRC" ] || fail "the re-land's second parent is not the source"
}

@test "dst-position check: a moved dst is blocked, naming the rebase and the reset; the reset then lands" {
  complete_chain l25 lb
  git checkout -q -b moved "$O"
  printf 'moved on\n' >h.txt && git add h.txt && git commit -qm moved-c
  MOVED=$(git rev-parse moved)
  git branch -f main "$MOVED"
  git checkout -q carrier/lb
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "cannot move from"
  assert_output --partial "git rebase"
  assert_output --partial "git branch -f main"
  assert_output --partial "the reset tip remains reflog-reachable as main@{1}"
  # the user's own reset, the refusal's exact recipe, then the landing
  git branch -f main "$O"
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$(git rev-parse carrier/lb)" "commit '$SRC'"
  git commit -qm finished
  [ "$(git rev-parse main^1)" = "$O" ] || fail "the landed merge's first parent is not O"
}

@test "--check: every check runs, nothing moves" {
  complete_chain ldr lb
  MAIN=$(git rev-parse main)
  TIP=$(git rev-parse HEAD)
  run git land --check main
  assert_success
  assert_output --partial "check: ready to land MERGE_HEAD ($(git rev-parse --short "$SRC")) from carrier/lb onto main ($(git rev-parse --short "$O"))"
  assert_output --partial "nothing changed"
  [ "$(git rev-parse main)" = "$MAIN" ] || fail "the check moved main"
  [ "$(git rev-parse HEAD)" = "$TIP" ] || fail "the check moved HEAD"
  [ -z "$(git status --porcelain)" ] || fail "the check dirtied the checkout"
  [ ! -e "$(git rev-parse --git-path MERGE_HEAD)" ] ||
    fail "the check wrote merge state"
  # the real landing still prepares afterwards
  run git land main
  assert_success
  assert_output --partial "prepared the landing on main"
}

@test "--check over held paths reports them and refuses, mutating nothing" {
  parked_chain ldro lb
  MAIN=$(git rev-parse main)
  run git land --check main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "conflicts are still held"
  [ "$(git rev-parse main)" = "$MAIN" ] || fail "the check moved main"
  [ -z "$(git status --porcelain)" ] || fail "the check dirtied the checkout"
}

@test "--check over a moved dst names both exits, without moving anything" {
  complete_chain ldrf lb
  git checkout -q -b moved "$O"
  printf 'moved on\n' >h.txt && git add h.txt && git commit -qm moved-c
  MOVED=$(git rev-parse moved)
  git branch -f main "$MOVED"
  git checkout -q carrier/lb
  run git land --check main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "cannot move from"
  assert_output --partial "git rebase"
  assert_output --partial "git branch -f main"
  [ "$(git rev-parse main)" = "$MOVED" ] || fail "the check moved main"
  [ -z "$(git status --porcelain)" ] || fail "the check dirtied the checkout"
}

@test "the chain's own checked-out branch is never the destination" {
  complete_chain l27 lb
  run git land carrier/lb
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "cannot land onto its own carrier branch"
  assert_output --partial "git switch -c"
}

@test "content is never inspected: never-touched and resolved-with-markers both land" {
  parked_chain l30 lb
  git rm -q -r .hangar/stages/f.txt
  git commit -qm "release without touching"
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$(git rev-parse carrier/lb)" "commit '$SRC'"
  git commit -qm "finish: the never-touched markers are the resolution"
  git show main:f.txt | grep -q '^<<<<<<< ' ||
    fail "the marker-laden resolution did not land verbatim"
  # a resolution that keeps markers on purpose lands too, on its own chain
  parked_chain l30b lb2
  git rm -q -r .hangar/stages/f.txt
  git commit -qm "release without touching"
  printf 'a\n<<<<<<< kept on purpose\nRESOLVED\n=======\nc\n>>>>>>> side\n' >f.txt
  git add f.txt
  git commit -qm "resolve keeping markers"
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$(git rev-parse carrier/lb2)" "commit '$SRC'"
}

@test "an incomplete w-only stages directory refuses, naming the fix" {
  complete_chain l32i lb
  mkdir -p .hangar/stages/f.txt
  printf 'x\n' >.hangar/stages/f.txt/w
  git add -f .hangar >/dev/null
  git commit -qm "an incomplete w-only directory"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "only file w"
  assert_output --partial "f.txt"
}

@test "a dst checked out in another worktree is refused (porcelain move)" {
  complete_chain l33 lb
  git worktree add -q "$CARRIER_WORK/wt" main
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "worktree"
  [ "$(git rev-parse main)" = "$O" ] || fail "main moved despite the worktree refusal"
  git worktree remove "$CARRIER_WORK/wt"
  run git land main
  assert_success
}

@test "worktree-collision and clean-checkout refuse; untracked and ignored files otherwise survive" {
  mkrepo l34
  printf 'a\nb\nc\n' >f.txt
  printf 'ignored-add.txt\n' >.gitignore
  git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >f.txt
  git add -A && git commit -qm ours
  O=$(git rev-parse HEAD) # the pre-merge tip: land's base commit
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt
  printf 'new-from-theirs\n' >added.txt
  printf 'also-new\n' >ignored-add.txt
  git add -Af ignored-add.txt
  git add -A
  git commit -qm theirs
  SRC=$(git rev-parse side)
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/lb >/dev/null && git commit -qm parked
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git rm -q -r .hangar/stages/f.txt && git commit -qm resolve
  # the landing starts from the chain's own checkout, where added.txt is tracked: a modified
  # tracked file is the dirty checkout the clean-checkout check refuses
  echo "local-only" >added.txt
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "tracked changes"
  assert_output --partial "commit or stash"
  # a file removed from the index but left in the worktree is untracked at a path the resolved tree
  # tracks: the collision refusal names it and the ways out
  git checkout -q -- added.txt
  git rm -q --cached added.txt
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "untracked or ignored"
  assert_output --partial "added.txt"
  assert_output --partial "track it"
  git reset -q
  [ "$(git rev-parse main)" = "$O" ] || fail "a blocked landing moved main"
  # cleared, the landing proceeds; an untracked file and an ignored file at paths the resolved
  # tree does not track survive it
  echo "keep me" >untracked-keeper.txt
  echo "keep me ignored" >junk.out
  run git land main
  assert_success
  assert_prepared main "$O" "$SRC" "$(git rev-parse carrier/lb)" "commit '$SRC'"
  [ -f untracked-keeper.txt ] ||
    fail "an untracked file at a path the resolved tree does not track did not survive the landing"
  [ -f junk.out ] ||
    fail "an ignored file at a path the resolved tree does not track did not survive the landing"
  git commit -qm finished
}

@test "a newer hangar at HEAD is refused with the upgrade recovery" {
  conflict_repo l36
  SRC=$(git rev-parse side)
  git merge --abort
  mkdir .hangar
  printf 'hangar-format: 2\nsource: %s\nsource-desc: commit x\n' "$SRC" >.hangar/manifest
  git add -f .hangar >/dev/null && git commit -qm "a format-2 chain"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "newer hangar format"
}

@test "the prepared message renders for a non-suppressed dst: into <dst>" {
  conflict_repo l37
  git merge --abort
  tag_the_source
  git switch -qc devel
  git merge v1.2.3 >/dev/null 2>&1 || true
  git park -b carrier/v1.2.3 >/dev/null && git commit -qm parked
  git unpark >/dev/null
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git commit -qm resolve
  git switch -q carrier/v1.2.3
  run git land devel
  assert_success
  [ "$(head -1 "$(git rev-parse --git-path MERGE_MSG)")" = "Merge tag 'v1.2.3' into devel" ] ||
    fail "the render did not name devel: $(head -1 "$(git rev-parse --git-path MERGE_MSG)")"
  if grep -q 'Message recorded at park' "$(git rev-parse --git-path MERGE_MSG)"; then
    fail "matching render and record still produced a comment block"
  fi
}

@test "a recorded message that differs travels as a comment block; an edited commit strips it" {
  conflict_repo l38
  git merge --abort
  tag_the_source
  git switch -qc work
  git merge -m "custom subject from the user" v1.2.3 >/dev/null 2>&1 || true
  git park -b carrier/v1.2.3 >/dev/null && git commit -qm parked
  git unpark >/dev/null
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git commit -qm resolve
  run git land work
  assert_success
  [ "$(head -1 "$(git rev-parse --git-path MERGE_MSG)")" = "Merge tag 'v1.2.3' into work" ] ||
    fail "the fresh render is not the prepared subject: $(head -1 "$(git rev-parse --git-path MERGE_MSG)")"
  grep -q '^# Message recorded at park:$' "$(git rev-parse --git-path MERGE_MSG)" ||
    fail "no comment block on a mismatch"
  grep -q '^# custom subject from the user$' "$(git rev-parse --git-path MERGE_MSG)" ||
    fail "the recorded message is not in the comment block"
  git commit -q # GIT_EDITOR=true: an editor runs, so comments are stripped
  [ "$(git log -1 --format=%s work)" = "Merge tag 'v1.2.3' into work" ] ||
    fail "the finished subject is not the fresh render"
  if git log -1 --format=%B work | grep -q 'Message recorded at park'; then
    fail "the comment block survived an edited commit"
  fi
}

@test "--no-edit keeps the comment block (git's cleanup contract)" {
  conflict_repo l39
  git merge --abort
  tag_the_source
  git switch -qc work
  git merge -m "custom subject from the user" v1.2.3 >/dev/null 2>&1 || true
  git park -b carrier/v1.2.3 >/dev/null && git commit -qm parked
  git unpark >/dev/null
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git commit -qm resolve
  run git land work
  assert_success
  git commit -q --no-edit
  git log -1 --format=%B work | grep -q '^# Message recorded at park:$' ||
    fail "the comment block did not survive --no-edit"
  git log -1 --format=%B work | grep -q '^# custom subject from the user$' ||
    fail "the recorded message is not in the committed comment block"
}

@test "the comment block honors core.commentChar" {
  conflict_repo l40
  git merge --abort
  tag_the_source
  git config core.commentChar ';'
  git switch -qc work
  git merge -m "custom subject" v1.2.3 >/dev/null 2>&1 || true
  git park -b carrier/v1.2.3 >/dev/null && git commit -qm parked
  git unpark >/dev/null
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git commit -qm resolve
  run git land work
  assert_success
  grep -q '^; Message recorded at park:$' "$(git rev-parse --git-path MERGE_MSG)" ||
    fail "the comment block does not use core.commentChar"
  git commit -q # the editor strips ';' comments like any other
  if git log -1 --format=%B work | grep -q 'Message recorded at park'; then
    fail "the comment block survived an edited commit under core.commentChar"
  fi
}

@test "a remote-tracking source renders 'Merge remote-tracking branch'" {
  conflict_repo l41
  git merge --abort
  git update-ref refs/remotes/origin/side side
  git merge origin/side >/dev/null 2>&1 || true
  git park -b carrier/origin-side >/dev/null && git commit -qm parked
  git unpark >/dev/null
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git commit -qm resolve
  run git land main
  assert_success
  [ "$(head -1 "$(git rev-parse --git-path MERGE_MSG)")" = "Merge remote-tracking branch 'origin/side'" ] ||
    fail "the remote-tracking render is wrong: $(head -1 "$(git rev-parse --git-path MERGE_MSG)")"
}

@test "a dirty submodule worktree does not block the landing; a moved pointer still refuses" {
  # a library to be the submodule
  git init -q -b main "$CARRIER_WORK/lib"
  git -C "$CARRIER_WORK/lib" config user.email a@b.c
  git -C "$CARRIER_WORK/lib" config user.name T
  printf 'lib v1\n' >"$CARRIER_WORK/lib/l.txt"
  git -C "$CARRIER_WORK/lib" add -A
  git -C "$CARRIER_WORK/lib" commit -qm lib1
  # a parked, resolved chain in a superproject that carries the submodule
  mkrepo subm
  git -c protocol.file.allow=always submodule add -q "$CARRIER_WORK/lib" lib
  git -C lib config user.email a@b.c
  git -C lib config user.name T
  printf 'a\nb\nc\n' >f.txt && git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >f.txt && git commit -qam ours
  O=$(git rev-parse HEAD)
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt && git commit -qam theirs
  SRC=$(git rev-parse side)
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/lb >/dev/null && git commit -qm parked
  git unpark >/dev/null
  printf 'a\nRESOLVED\nc\n' >f.txt && git add f.txt && git commit -qm resolve
  # a moved submodule pointer IS a tracked change of the superproject: refuse
  printf 'lib v2\n' >lib/l.txt
  git -C lib add l.txt && git -C lib commit -qm lib2
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "tracked changes"
  git -C lib reset -q --hard HEAD~1
  # dirt inside the submodule worktree cannot be committed or stashed from here: it must not block
  printf 'dirt\n' >>lib/l.txt
  run git land main
  assert_success
  assert_output --partial "prepared the landing"
  assert_prepared main "$O" "$SRC" "$(git rev-parse carrier/lb)" "commit '$SRC'"
}

@test "branch.<dst>.mergeOptions=--no-commit: land refuses, the user's own commit finishes" {
  conflict_repo noc
  SRC=$(git rev-parse side)
  git merge --abort
  # make the merge clean: take theirs' content on main
  git show side:f.txt >f.txt
  git add f.txt && git commit -qm ours-take-theirs
  git config branch.main.mergeoptions --no-commit
  git merge side >/dev/null 2>&1 || true
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] || fail "fixture: MERGE_HEAD is not live"
  [ "$(git log -1 --format=%s)" = "ours-take-theirs" ] ||
    fail "fixture: a commit was created despite --no-commit"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "already prepared with no unmerged paths"
  git commit -qm finished
  [ "$(git rev-list --parents -n 1 HEAD | wc -w)" = "3" ] ||
    fail "the --no-commit merge was not finished as [ours, source]"
  [ "$(git rev-parse HEAD^2)" = "$SRC" ] ||
    fail "the finished merge's second parent is not the source"
}

@test "a refusal listing many held paths is capped with a count" {
  mkrepo cap
  local i
  for i in $(seq 1 12); do printf 'a\nb\n' >"f$i.txt"; done
  git add -A && git commit -qm base
  git branch side
  for i in $(seq 1 12); do printf 'a\nOURS\n' >"f$i.txt"; done
  git commit -qam ours
  git checkout -q side
  for i in $(seq 1 12); do printf 'a\nTHEIRS\n' >"f$i.txt"; done
  git commit -qam theirs
  SRC=$(git rev-parse side)
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/lb >/dev/null && git commit -qm parked
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "conflicts are still held"
  assert_output --partial "... (12 total)"
  case $output in
  *f8.txt* | *f9.txt*) fail "more than 10 paths were listed" ;;
  esac
}

# The uncommitted park window. The guard sits with in_progress_check, ahead of every case that
# can move a ref, and the refusal names both ways out.
@test "the park window is refused on the carrier: dst untouched, no switch advice" {
  conflict_repo l60
  SRC=$(git rev-parse side)
  git park -b carrier/lb >/dev/null
  [ "$(git symbolic-ref --short HEAD)" = "carrier/lb" ] || fail "fixture: not on the carrier"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "staged but not committed"
  assert_output --partial "git commit"
  case $output in
  *"not a parked merge"*) fail "land read the uncommitted park as no chain here" ;;
  esac
  [ "$(git rev-parse main)" = "$O" ] || fail "main moved while the park was uncommitted"
}

@test "the park window precedes the already-landed exit" {
  conflict_repo l62
  SRC=$(git rev-parse side)
  git park -b carrier/lb >/dev/null
  # main acquires the source by another route entirely
  git update-ref refs/heads/main "$SRC"
  run git land main
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "staged but not committed"
  case $output in
  *"already"*) fail "an idempotent exit hid the uncommitted park" ;;
  esac
}
