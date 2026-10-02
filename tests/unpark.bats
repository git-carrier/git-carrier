# unpark.bats: the hangar reader: the five outcomes, real-path selection, the release, and
# every refusal.

load helpers

setup() {
  setup_scratch
}

teardown() {
  teardown_scratch
}

# A parked chain tip with five conflicted paths, one per outcome shape: v1 unchanged, v2 both absent
# (the unchanged deletion), v3 differs, v4 file w present but the file deleted since, v5 file w
# absent but the file restored since. After outcome_repo: HEAD is the parked commit.
outcome_repo() {
  mkrepo "$1"
  local i
  for i in 1 2 3 4 5; do printf 'base%s\n' "$i" >"v$i.txt"; done
  git add -A && git commit -qm base
  git branch side
  for i in 1 2 3 4 5; do printf 'ours%s\n' "$i" >"v$i.txt"; done
  git add -A && git commit -qm ours
  git checkout -q side
  printf 'theirs1\n' >v1.txt
  printf 'theirs3\n' >v3.txt
  printf 'theirs4\n' >v4.txt
  rm v2.txt v5.txt # ours keeps both, theirs deletes: modify/delete
  git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  # mid-merge: plain-rm the modify/delete survivors, so neither has a file w (the parked tree
  # records the deletions)
  rm -f v2.txt v5.txt
  git park -b carrier/side >/dev/null
  git commit -qm parked
  # post-park worktree shapes that select the outcomes:
  printf 'resolved3\n' >v3.txt # differs from the stored markers
  rm -f v4.txt                # file w present, the file deleted since
  printf 'restored5\n' >v5.txt # file w absent, the file restored since
}

@test "the five outcomes, each phrasing asserted" {
  outcome_repo u1
  run git unpark
  assert_success
  assert_output --partial "unchanged (reopened): v1.txt"
  assert_output --partial "no file (reopened): v2.txt"
  assert_output --partial "differs (that content is the resolution): v3.txt"
  assert_output --partial "no file (resolved as a deletion): v4.txt"
  assert_output --partial "restored (that content is the resolution): v5.txt"
  assert_output --partial "2 paths reopened; 3 resolutions released"
  assert_output --partial "3 resolutions are unstaged for review: git add them, then commit"
}

@test "an already staged or already committed resolution is named as such, never 'unstaged'" {
  outcome_repo usr
  # committed: resolved and committed, the release never run
  git add v5.txt
  git commit -qm resolve-v5
  # staged: resolved and added, not yet committed
  git add v3.txt
  run git unpark
  assert_success
  assert_output --partial "already staged (releasing): v3.txt"
  assert_output --partial "already committed (releasing): v5.txt"
  assert_output --partial "2 paths reopened; 3 resolutions released"
  assert_output --partial "1 resolution is unstaged for review: git add it, then commit"
  assert_output --partial "1 resolution already staged: review and commit when ready"
  assert_output --partial "1 resolution already committed: commit the hangar release"
}

@test "a mode-only change is the resolution: the comparison covers the mode, not just the bytes" {
  conflict_repo sy5
  git park -b carrier/side >/dev/null
  git commit -qm parked
  chmod 755 f.txt
  run git unpark f.txt
  assert_success
  assert_output --partial "differs only in mode (that mode is the resolution): f.txt"
  assert_output --partial "1 resolution is unstaged for review"
  [ -z "$(git ls-files --unmerged)" ] ||
    fail "a mode-only change must not reopen the conflict"
  git add f.txt && git commit -qm resolve
  git land main >/dev/null
  git commit -qm finished
  [ "$(git ls-tree main -- f.txt | awk '{print $1}')" = "100755" ] ||
    fail "the landed tree lost the resolution's mode"
}

@test "a type change holding the same blob bytes is the resolution, not an unchanged reopen" {
  # w is a regular file; the worktree file became a symlink holding the same bytes: the
  # blob matches, the mode does not
  conflict_repo sy6
  git park -b carrier/side >/dev/null
  git commit -qm parked
  local content
  content=$(git cat-file blob HEAD:f.txt && printf x)
  rm f.txt
  ln -s -- "${content%x}" f.txt
  run git unpark f.txt
  assert_success
  assert_output --partial "differs only in type (that type is the resolution): f.txt"
  [ -z "$(git ls-files --unmerged)" ] ||
    fail "a type change must not reopen the conflict"

  # the reverse: w is a symlink, the worktree link became a regular file with the target
  # bytes
  mkrepo sy6b
  printf 't\n' >t.txt
  ln -s t.txt link.txt
  git add -A && git commit -qm base
  git branch side
  rm link.txt && ln -s ours link.txt && git add -A && git commit -qm ours
  git checkout -q side
  rm link.txt && ln -s theirs link.txt && git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/side >/dev/null
  git commit -qm parked
  rm link.txt
  printf 'ours' >link.txt
  run git unpark link.txt
  assert_success
  assert_output --partial "differs only in type (that type is the resolution): link.txt"
  [ -z "$(git ls-files --unmerged -- link.txt)" ] ||
    fail "a type change must not reopen the conflict"
}

@test "a mode-only resolution already staged or already committed is named by its kind at the door" {
  # staged: chmod'ed and added, not yet committed
  conflict_repo sy9
  git park -b carrier/side >/dev/null
  git commit -qm parked
  chmod 755 f.txt
  git add f.txt
  run git unpark f.txt
  assert_success
  assert_output --partial "already staged (releasing; differs only in mode): f.txt"
  assert_output --partial "1 resolution already staged: review and commit when ready"

  # committed: chmod'ed, added, and committed, the release never run
  conflict_repo sy9b
  git park -b carrier/side >/dev/null
  git commit -qm parked
  chmod 755 f.txt
  git add f.txt && git commit -qm resolve
  run git unpark f.txt
  assert_success
  assert_output --partial "already committed (releasing; differs only in mode): f.txt"
  assert_output --partial "1 resolution already committed: commit the hangar release"
}

@test "a type-only resolution already staged or already committed is named by its kind at the door" {
  # staged: the file became a link holding the same bytes, added, not yet committed
  conflict_repo sy10
  git park -b carrier/side >/dev/null
  git commit -qm parked
  local content
  content=$(git cat-file blob HEAD:f.txt && printf x)
  rm f.txt
  ln -s -- "${content%x}" f.txt
  git add f.txt
  run git unpark f.txt
  assert_success
  assert_output --partial "already staged (releasing; differs only in type): f.txt"
  assert_output --partial "1 resolution already staged: review and commit when ready"

  # committed: the same, resolved and committed, the release never run
  conflict_repo sy10b
  git park -b carrier/side >/dev/null
  git commit -qm parked
  content=$(git cat-file blob HEAD:f.txt && printf x)
  rm f.txt
  ln -s -- "${content%x}" f.txt
  git add f.txt && git commit -qm resolve
  run git unpark f.txt
  assert_success
  assert_output --partial "already committed (releasing; differs only in type): f.txt"
  assert_output --partial "1 resolution already committed: commit the hangar release"
}

@test "core.fileMode false: the exec bit stays out of the comparison, as git's own add keeps it" {
  conflict_repo sy7
  git park -b carrier/side >/dev/null
  git commit -qm parked
  git config core.fileMode false
  chmod 755 f.txt
  run git unpark f.txt
  assert_success
  assert_output --partial "unchanged (reopened): f.txt"
  [ -n "$(git ls-files --unmerged -- f.txt)" ] ||
    fail "fileMode=false must keep the exec bit out of the comparison"
}

@test "core.symlinks false: a symlink checked out as a regular file still compares whole" {
  # w is a symlink (mode 120000); a symlink-less checkout materializes it as a regular file
  # holding the target text. git's own add keeps the index entry's 120000 for that file
  # (ce_mode_from_stat), so the untouched file is unchanged, not a type change
  mkrepo sy8
  printf 't\n' >t.txt
  ln -s t.txt link.txt
  git add -A && git commit -qm base
  git branch side
  rm link.txt && ln -s ours link.txt && git add -A && git commit -qm ours
  git checkout -q side
  rm link.txt && ln -s theirs link.txt && git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/side >/dev/null
  git commit -qm parked
  # the symlink-less checkout: the parked link materializes as a regular file holding the
  # target text
  git config core.symlinks false
  rm link.txt
  git checkout -q -- link.txt
  { [ -f link.txt ] && [ ! -L link.txt ]; } ||
    fail "core.symlinks false did not materialize the link as a regular file"
  run git unpark link.txt
  assert_success
  assert_output --partial "unchanged (reopened): link.txt"
  [ -n "$(git ls-files --unmerged -- link.txt)" ] ||
    fail "symlinks=false must keep the symlink mode in the comparison"

  # editing the regular file is a content change: the kept mode does not force a reopen
  git park >/dev/null
  printf 'mine\n' >link.txt
  run git unpark link.txt
  assert_success
  assert_output --partial "differs (that content is the resolution): link.txt"
  [ -z "$(git ls-files --unmerged -- link.txt)" ] ||
    fail "an edited file must not reopen the conflict"
}

@test "an unchanged reopen feeds stages 1/2/3 with no stray stage-0" {
  outcome_repo u2
  git unpark v1.txt >/dev/null
  local stages
  stages=$(git ls-files -s -- v1.txt | awk '{print $3}' | sort | tr '\n' ' ')
  [ "$stages" = "1 2 3 " ] ||
    fail "v1.txt stages after reopen are [$stages], want 1 2 3 with no stage 0"
  [ "$(git status --porcelain -- v1.txt)" = "UU v1.txt" ] ||
    fail "v1.txt does not show UU after the reopen"
}

@test "a mismatch leaves no index state: the resolution stays unstaged" {
  outcome_repo u3
  git unpark v3.txt >/dev/null
  local stages
  stages=$(git ls-files -s -- v3.txt | awk '{print $3}' | sort | tr '\n' ' ')
  [ "$stages" = "0 " ] || fail "v3.txt index state is [$stages], want only stage 0"
  [ "$(git status --porcelain -- v3.txt | head -c 1)" = " " ] ||
    fail "v3.txt resolution was staged; it must stay unstaged for review"
}

@test "the reopened path's stage blobs come from the hangar's tree entries" {
  outcome_repo u4
  local want1 want2 want3
  want1=$(git rev-parse HEAD:.hangar/stages/v1.txt/1)
  want2=$(git rev-parse HEAD:.hangar/stages/v1.txt/2)
  want3=$(git rev-parse HEAD:.hangar/stages/v1.txt/3)
  git unpark v1.txt >/dev/null
  local s
  s=$(git ls-files -s -- v1.txt | sed -n 's/^[0-9]* \([0-9a-f]*\) 1.*/\1/p')
  [ "$s" = "$want1" ] || fail "stage 1 of v1.txt is not the hangar's stage file blob"
  s=$(git ls-files -s -- v1.txt | sed -n 's/^[0-9]* \([0-9a-f]*\) 2.*/\1/p')
  [ "$s" = "$want2" ] || fail "stage 2 of v1.txt is not the hangar's stage file blob"
  s=$(git ls-files -s -- v1.txt | sed -n 's/^[0-9]* \([0-9a-f]*\) 3.*/\1/p')
  [ "$s" = "$want3" ] || fail "stage 3 of v1.txt is not the hangar's stage file blob"
}

@test "hangar directories are deleted from index and worktree" {
  outcome_repo u5
  git unpark >/dev/null
  [ -z "$(git ls-files -- .hangar/stages)" ] || fail "stages entries remain in the index"
  [ ! -d .hangar/stages/v1.txt ] || fail "the stages directory remains in the worktree"
  # resolve the reopened paths, then the release commit records it all
  git show :2:v1.txt >v1.txt && git add v1.txt
  git rm -q v2.txt
  git commit -qm released
  if git ls-tree -r --name-only HEAD | grep -q '^\.hangar/stages/'; then
    fail "stages entries remain in the tree after the release commit"
  fi
  assert_hangar HEAD
}

@test "paths: literal, directory subtree, cwd-relative" {
  mkrepo u6
  printf 'a\n' >a.txt
  printf 'e\n' >e.txt
  mkdir -p sub sub2
  printf 'b\n' >sub/b.txt
  printf 'c\n' >sub/c.txt
  printf 'd\n' >sub2/d.txt
  printf 'e2\n' >sub2/e2.txt
  git add -A && git commit -qm base
  git branch side
  for f in a.txt e.txt sub/b.txt sub/c.txt sub2/d.txt sub2/e2.txt; do
    printf 'ours-%s\n' "$f" >"$f"
  done
  git add -A && git commit -qm ours
  git checkout -q side
  for f in a.txt e.txt sub/b.txt sub/c.txt sub2/d.txt sub2/e2.txt; do
    printf 'theirs-%s\n' "$f" >"$f"
  done
  git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/side >/dev/null && git commit -qm parked

  # literal, after --
  run git unpark -- a.txt
  assert_success
  assert_output --partial "unchanged (reopened): a.txt"
  git show :2:a.txt >a.txt && git add a.txt
  git commit -qm r1

  # a directory argument takes the whole subtree of held paths beneath it
  run git unpark sub
  assert_success
  assert_output --partial "sub/b.txt"
  assert_output --partial "sub/c.txt"
  git show :2:sub/b.txt >sub/b.txt && git add sub/b.txt
  git show :2:sub/c.txt >sub/c.txt && git add sub/c.txt
  git commit -qm r2

  # cwd-relative, from inside the directory: the argument resolves against the cwd's
  # own prefix, as in any git command
  cd sub2
  run git unpark d.txt
  assert_success
  assert_output --partial "sub2/d.txt"
  git show :2:sub2/d.txt >d.txt && git add d.txt
  git commit -qm r3
  cd "$REPO"

  run git unpark sub2
  assert_success
  assert_output --partial "sub2/e2.txt"
  git show :2:sub2/e2.txt >sub2/e2.txt && git add sub2/e2.txt
  git commit -qm r4
}

@test "a path naming no held path is an error" {
  outcome_repo u7
  run git unpark nosuch.txt
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "nosuch.txt is not a held path"
  [ -n "$(git ls-files -- .hangar/stages)" ] ||
    fail "the failed match must not take anything out of the hangar"
}

@test "a w-only (incomplete) directory is released without a reopen" {
  outcome_repo u8
  git rm -q .hangar/stages/v1.txt/1 .hangar/stages/v1.txt/2 .hangar/stages/v1.txt/3
  git commit -qm "reduce v1 to file w only"
  run git unpark v1.txt
  assert_success
  assert_output --partial "no stage files, only the parked copy (releasing): v1.txt"
  [ -z "$(git ls-files --unmerged -- v1.txt)" ] || fail "a w-only directory must not reopen"
  git commit -qm released
  if git cat-file -e HEAD:.hangar/stages/v1.txt/w 2>/dev/null; then
    fail "the w-only directory was not released"
  fi
}

@test "an empty parked-paths set refuses with the land hint" {
  outcome_repo u9
  git rm -q -r .hangar/stages
  git commit -qm "release everything"
  run git unpark
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "nothing to reopen"
  assert_output --partial "git land"
}

@test "refusals: mid-merge on and off the chain, mid-rebase, non-parked HEAD" {
  outcome_repo u10
  git reset -q --hard # drop the fixture's post-park edits: clean for a merge
  git merge side >/dev/null 2>&1 || true
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] || fail "fixture: the merge did not stop"
  run git unpark
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "a merge is in progress"
  assert_output --partial "then re-run"
  git merge --abort

  # off the chain: a stopped merge is park's subject, so the refusal names it
  mkrepo u10d
  printf 'a\n' >f.txt && git add -A && git commit -qm base
  git branch side && printf 'b\n' >f.txt && git add -A && git commit -qm ours
  git checkout -q side && printf 'c\n' >f.txt && git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] || fail "fixture: the merge did not stop"
  run git unpark
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "a merge is in progress"
  assert_output --partial "park it with 'git park --branch <name>'"
  git merge --abort

  mkrepo u10b
  printf 'a\n' >f.txt && git add -A && git commit -qm base
  git branch side && printf 'b\n' >f.txt && git add -A && git commit -qm ours
  git checkout -q side && printf 'c\n' >f.txt && git add -A && git commit -qm theirs
  git checkout -q main
  git rebase side >/dev/null 2>&1 || true
  run git unpark
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "REBASE_HEAD"
  git rebase --abort

  mkrepo u10c
  printf 'a\n' >f.txt && git add -A && git commit -qm base
  run git unpark
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "not a parked merge"
}

@test "the recorded source merged back into the carrier unparks per path like a chain tip" {
  outcome_repo u11
  git merge -s ours side -m "merge the source back in" >/dev/null 2>&1
  [ "$(git rev-list --parents -n 1 HEAD | wc -w)" = "3" ] ||
    fail "fixture: HEAD is not a merge commit"
  run git unpark
  assert_success
  assert_output --partial "unchanged (reopened): v1.txt"
  assert_output --partial "differs (that content is the resolution): v3.txt"
  assert_output --partial "2 paths reopened; 3 resolutions released"
  [ "$(git ls-files -s -- v1.txt | grep -c .)" = "3" ] ||
    fail "the reopen did not restore v1.txt's stages"
}

@test "a hangar at HEAD that is not ours dies, a missing one is not parked" {
  mkrepo u12
  printf 'x\n' >f.txt && git add -A && git commit -qm base
  mkdir .hangar
  printf "someone else's directory\n" >.hangar/manifest
  git add -f .hangar >/dev/null && git commit -qm not-ours
  run git unpark
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "cannot verify"

  git rm -q -r .hangar && git commit -qm no-hangar
  run git unpark
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "not a parked merge"
}

@test "detached HEAD at a parked tip is refused with the switch recovery" {
  outcome_repo u13
  git checkout -q --detach
  run git unpark
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "detached HEAD"
  assert_output --partial "git switch -c"
}

@test "a dirty checkout is fine for the paths being unparked" {
  outcome_repo u14
  printf 'dirty but unrelated\n' >other.txt
  git add other.txt
  run git unpark v1.txt
  assert_success
  [ "$(git status --porcelain -- other.txt)" = "A  other.txt" ] ||
    fail "unpark disturbed an unrelated staged change"
}

@test "symlink outcomes: unchanged reopens, a changed link is the resolution" {
  mkrepo u15
  printf 't\n' >t.txt && ln -s t.txt link.txt
  git add -A && git commit -qm base
  git branch side
  rm link.txt && ln -s ours-target link.txt
  git add -A && git commit -qm ours
  git checkout -q side
  rm link.txt && ln -s theirs-target link.txt
  git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/side >/dev/null && git commit -qm parked
  run git unpark link.txt
  assert_success
  assert_output --partial "unchanged (reopened): link.txt"
  local stages
  stages=$(git ls-files -s -- link.txt | awk '{print $1, $3}' | sort | tr '\n' ' ')
  [ "$stages" = "120000 1 120000 2 120000 3 " ] || fail "symlink stages after reopen are [$stages]"
  # back to the parked tip (reset --hard clears the reopened state), then change the link: the
  # outcome is a resolution, no index state
  git reset -q --hard
  rm link.txt && ln -s changed-target link.txt
  run git unpark link.txt
  assert_success
  assert_output --partial "differs (that content is the resolution): link.txt"
  [ -z "$(git ls-files --unmerged -- link.txt)" ] || fail "a changed symlink must not reopen"
}

@test "an unchanged symlink whose target ends in a newline reopens, and stage 2 is byte-exact" {
  mkrepo u20
  printf 'a\n' >f.txt && git add -A && git commit -qm base
  git branch side
  rm f.txt && ln -s $'foo\n' f.txt && git add -A && git commit -qm ours
  git checkout -q side
  rm f.txt && ln -s bar f.txt && git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/side >/dev/null && git commit -qm parked
  run git unpark f.txt
  assert_success
  # a corrupted w would release the path as a resolution instead of reopening the live
  # conflict it still is
  assert_output --partial "unchanged (reopened): f.txt"
  local want
  want=$(printf 'foo\n' | git hash-object --stdin)
  [ "$(git ls-files -s -- f.txt | awk '$3 == 2 {print $2}')" = "$want" ] ||
    fail "the reopened stage 2 lost the target's trailing newline"
}

@test "an unfinished git am is refused while working a chain" {
  conflict_repo u21
  git park -b carrier/side >/dev/null
  git commit -qm parked
  # a conflicting am on the carrier (the patch and the carrier both touch keep.txt). A stopped am
  # writes no REBASE_HEAD; its state marker is the rebase-apply directory.
  printf 'carrier\n' >keep.txt && git commit -qam 'carrier touches keep'
  git checkout -q -b patchsrc main
  printf 'patched\n' >keep.txt && git commit -qam patched
  git format-patch -q -1
  git checkout -q carrier/side
  git am 0001-*.patch >/dev/null 2>&1 || true
  [ -d "$(git rev-parse --git-path rebase-apply)" ] || fail "fixture: no am in progress"
  run git unpark f.txt
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "git am"
  git am --abort
  # nothing was taken out: f.txt's stages directory is still parked
  [ -d .hangar/stages/f.txt ] || fail "unpark released f.txt during the am stop"
}

# The index stages of one exact path, as a sorted "1 2 3 " list (a directory argument takes
# nested held paths in by design, so the path column is matched exactly).
stage_list() {
  git ls-files -s -- "$1" | awk -F'\t' -v want="$1" '$2 == want { n = split($1, f, " "); print f[n] }' |
    sort | tr '\n' ' '
}

# A hand-built hangar over five held paths, in record order: a (stages 1, 3, and w, the
# worktree file holding w: unchanged), a/b (stage 2, no worktree file: no file), other
# (unchanged), sub/x (unchanged), sub/y (stage 2, no worktree file).
paths_repo() {
  mkrepo "$1"
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  mkdir -p sub
  mkdir -p .hangar/stages/a/b .hangar/stages/other .hangar/stages/sub/x .hangar/stages/sub/y
  printf 'base-a\n' >.hangar/stages/a/1
  printf 'theirs-a\n' >.hangar/stages/a/3
  printf 'worktree-a\n' >a
  printf 'worktree-a\n' >.hangar/stages/a/w
  printf 'ours-ab\n' >.hangar/stages/a/b/2
  printf 'base-o\n' >.hangar/stages/other/1
  printf 'theirs-o\n' >.hangar/stages/other/3
  printf 'worktree-o\n' >other
  printf 'worktree-o\n' >.hangar/stages/other/w
  printf 'base-subx\n' >.hangar/stages/sub/x/1
  printf 'theirs-subx\n' >.hangar/stages/sub/x/3
  printf 'worktree-subx\n' >sub/x
  printf 'worktree-subx\n' >.hangar/stages/sub/x/w
  printf 'ours-suby\n' >.hangar/stages/sub/y/2
  craft_hangar "$(git rev-parse HEAD)"
}

@test "nested held paths: the split parent reopens from both its blocks, once" {
  mkrepo u18
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  # a holds stages 1 and 3 plus w equal to the worktree file (unchanged); a/b holds stage 2 only
  # and no worktree file (no file). 'b' sorts between '3' and 'w', so ls-tree parks a/b between
  # a's 3 and its w: a's records span two blocks, and naive prev-tracking would take a out twice.
  mkdir -p .hangar/stages/a/b
  printf 'base\n' >.hangar/stages/a/1
  printf 'theirs\n' >.hangar/stages/a/3
  printf 'worktree-a\n' >a
  printf 'worktree-a\n' >.hangar/stages/a/w
  printf 'ours-b\n' >.hangar/stages/a/b/2
  craft_hangar "$(git rev-parse HEAD)"
  run git unpark
  assert_success
  assert_output --partial "unchanged (reopened): a"
  assert_output --partial "no file (reopened): a/b"
  assert_output --partial "2 paths reopened; 0 resolutions released"
  case $output in
  *"reopened): a"$'\n'"unpark: no file (reopened): a/b"*) ;;
  *) fail "the parent was not taken once, before the nested path" ;;
  esac
  [ "$(stage_list a)" = "1 3 " ] ||
    fail "a's stages after reopen are [$(stage_list a)], want 1 3 from both its blocks"
  [ "$(stage_list a/b)" = "2 " ] ||
    fail "a/b's stage after reopen is [$(stage_list a/b)], want 2"
  [ -z "$(git ls-files -- .hangar/stages)" ] || fail "stages entries remain in the index"
  [ ! -e .hangar/stages/a ] || fail "the split stages directories remain in the worktree"
}

@test "a path split between its own stage files reopens whole" {
  mkrepo u19
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  # '2z' sorts between '1' and '3', so a/2z parks inside a's own stage run: a's records span
  # blocks 1 and 3-w, and the reopen feed must still carry every stage file of a from both.
  mkdir -p .hangar/stages/a/2z
  printf 'base\n' >.hangar/stages/a/1
  printf 'theirs\n' >.hangar/stages/a/3
  printf 'worktree-a\n' >a
  printf 'worktree-a\n' >.hangar/stages/a/w
  printf 'ours-nested\n' >.hangar/stages/a/2z/2
  craft_hangar "$(git rev-parse HEAD)"
  run git unpark
  assert_success
  assert_output --partial "unchanged (reopened): a"
  assert_output --partial "no file (reopened): a/2z"
  assert_output --partial "2 paths reopened; 0 resolutions released"
  [ "$(stage_list a)" = "1 3 " ] ||
    fail "a's stages after reopen are [$(stage_list a)], want 1 3 from both sides of the split"
  [ "$(stage_list a/2z)" = "2 " ] ||
    fail "a/2z's stage after reopen is [$(stage_list a/2z)], want 2"
}

@test "a nested path sorting before the parent's stage files reopens before it" {
  mkrepo u22
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  # '-' sorts under '1', so ls-tree parks a/-b before every record of a: the walk meets the
  # nested path first and takes the parent once after it, so the report reads in record order.
  # a holds stages 1 and 3 plus w equal to the worktree file (unchanged); a/-b holds stage 2 only
  # and no worktree file (no file).
  mkdir -p '.hangar/stages/a/-b'
  printf 'base\n' >.hangar/stages/a/1
  printf 'theirs\n' >.hangar/stages/a/3
  printf 'worktree-a\n' >a
  printf 'worktree-a\n' >.hangar/stages/a/w
  printf 'ours-not\n' >'.hangar/stages/a/-b/2'
  craft_hangar "$(git rev-parse HEAD)"
  run git unpark
  assert_success
  assert_output --partial "unchanged (reopened): a"
  assert_output --partial "no file (reopened): a/-b"
  assert_output --partial "2 paths reopened; 0 resolutions released"
  case $output in
  *"reopened): a/-b"$'\n'"unpark: unchanged (reopened): a"*) ;;
  *) fail "the nested path was not taken before the parent" ;;
  esac
  [ "$(stage_list a)" = "1 3 " ] ||
    fail "a's stages after reopen are [$(stage_list a)], want 1 3"
  [ "$(stage_list 'a/-b')" = "2 " ] ||
    fail "a/-b's stage after reopen is [$(stage_list 'a/-b')], want 2"
  [ -z "$(git ls-files -- .hangar/stages)" ] || fail "stages entries remain in the index"
  [ ! -e .hangar/stages/a ] || fail "the split stages directories remain in the worktree"
}

@test "nested held paths: a parent argument takes the pair whole" {
  # the old design's blind spot: a synthetic index cannot hold a beside a/b, so the old
  # match over it reopened and released only a/b -- the wrong path -- and exited 0
  mkrepo u23
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  # a holds stages 1 and 3 plus w equal to the worktree file (unchanged); a/b holds
  # stage 2 only and no worktree file (no file)
  mkdir -p .hangar/stages/a/b
  printf 'base\n' >.hangar/stages/a/1
  printf 'theirs\n' >.hangar/stages/a/3
  printf 'worktree-a\n' >a
  printf 'worktree-a\n' >.hangar/stages/a/w
  printf 'ours-b\n' >.hangar/stages/a/b/2
  craft_hangar "$(git rev-parse HEAD)"
  run git unpark -- a
  assert_success
  assert_output --partial "unchanged (reopened): a"
  assert_output --partial "no file (reopened): a/b"
  assert_output --partial "2 paths taken out of the hangar; 2 paths reopened; 0 resolutions released"
  [ "$(stage_list a)" = "1 3 " ] ||
    fail "a's stages after reopen are [$(stage_list a)], want 1 3"
  [ "$(stage_list a/b)" = "2 " ] ||
    fail "a/b's stage after reopen is [$(stage_list a/b)], want 2"
  [ -z "$(git ls-files -- .hangar/stages)" ] ||
    fail "the parent's whole stages subtree must be released"
  [ ! -e .hangar/stages/a ] || fail "the a stages directory remains in the worktree"
}

@test "nested held paths: a child argument takes only the child" {
  mkrepo u24
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  mkdir -p .hangar/stages/a/b
  printf 'base\n' >.hangar/stages/a/1
  printf 'theirs\n' >.hangar/stages/a/3
  printf 'worktree-a\n' >a
  printf 'worktree-a\n' >.hangar/stages/a/w
  printf 'ours-b\n' >.hangar/stages/a/b/2
  craft_hangar "$(git rev-parse HEAD)"
  run git unpark -- a/b
  assert_success
  assert_output --partial "no file (reopened): a/b"
  assert_output --partial "1 path taken out of the hangar; 1 path reopened; 0 resolutions released"
  [ "$(stage_list a/b)" = "2 " ] ||
    fail "a/b's stage after reopen is [$(stage_list a/b)], want 2"
  [ -n "$(git ls-files -- .hangar/stages/a)" ] || fail "the parent must stay parked"
  [ -e .hangar/stages/a/1 ] || fail "the parent's stage files must remain"
}

@test "nested held paths, four deep: the parent argument takes the chain whole" {
  # no index-based selection can take this chain (three stages cannot express it); the
  # reopened index cannot express it either: git's own update-index resolves the two
  # intermediate stage-2 links away and keeps the deepest, beside the reopened parent
  # as one d/f pair (measured: the pristine tool lands the identical index)
  mkrepo u25
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  mkdir -p .hangar/stages/a/b/c/d
  printf 'base\n' >.hangar/stages/a/1
  printf 'theirs\n' >.hangar/stages/a/3
  printf 'worktree-a\n' >a
  printf 'worktree-a\n' >.hangar/stages/a/w
  printf 'ours-ab\n' >.hangar/stages/a/b/2
  printf 'ours-abc\n' >.hangar/stages/a/b/c/2
  printf 'ours-abcd\n' >.hangar/stages/a/b/c/d/2
  craft_hangar "$(git rev-parse HEAD)"
  run git unpark -- a
  assert_success
  assert_output --partial "unchanged (reopened): a"
  assert_output --partial "no file (reopened): a/b"
  assert_output --partial "no file (reopened): a/b/c"
  assert_output --partial "no file (reopened): a/b/c/d"
  assert_output --partial "4 paths taken out of the hangar; 4 paths reopened; 0 resolutions released"
  [ "$(stage_list a)" = "1 3 " ] ||
    fail "a's stages after reopen are [$(stage_list a)], want 1 3"
  [ "$(stage_list a/b/c/d)" = "2 " ] ||
    fail "the deepest link's stage after reopen is [$(stage_list a/b/c/d)], want 2"
  [ "$(stage_list a/b)" = "" ] ||
    fail "git did not resolve the a/b link away: the index cannot hold the same-stage chain"
  [ -z "$(git ls-files -- .hangar/stages)" ] ||
    fail "the chain's whole stages subtree must be released"
  [ ! -e .hangar/stages/a ] || fail "the a stages directory remains in the worktree"
}

@test "overlapping arguments select each path once" {
  # the first prototype draft of the selection loop reported a path once per matching
  # argument; keep this test against that class
  paths_repo u26
  run git unpark -- a a/b a
  assert_success
  assert_output --partial "2 paths taken out of the hangar; 2 paths reopened; 0 resolutions released"
  [ "$(printf '%s\n' "$output" | grep -c 'reopened): a$')" -eq 1 ] ||
    fail "a was reported once per matching argument, not once"
  [ "$(printf '%s\n' "$output" | grep -c 'reopened): a/b$')" -eq 1 ] ||
    fail "a/b was reported once per matching argument, not once"
  # a named parent plus its nested child
  mkrepo u27
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  mkdir -p .hangar/stages/src/x
  printf 'base\n' >.hangar/stages/src/1
  printf 'theirs\n' >.hangar/stages/src/3
  printf 'worktree-src\n' >src
  printf 'worktree-src\n' >.hangar/stages/src/w
  printf 'ours-x\n' >.hangar/stages/src/x/2
  craft_hangar "$(git rev-parse HEAD)"
  run git unpark -- src src/x
  assert_success
  assert_output --partial "2 paths taken out of the hangar; 2 paths reopened; 0 resolutions released"
  [ "$(printf '%s\n' "$output" | grep -c 'reopened): src$')" -eq 1 ] ||
    fail "src was reported once per matching argument, not once"
  [ "$(printf '%s\n' "$output" | grep -c 'reopened): src/x$')" -eq 1 ] ||
    fail "src/x was reported once per matching argument, not once"
  # a resolved top among the arguments takes everything, once each
  paths_repo u28
  run git unpark -- other .
  assert_success
  assert_output --partial "5 paths taken out of the hangar; 5 paths reopened; 0 resolutions released"
  [ "$(printf '%s\n' "$output" | grep -c 'reopened): a$')" -eq 1 ] ||
    fail "a was reported once per matching argument, not once"
}

@test "an argument naming no held path is an error even when others match" {
  paths_repo u29
  run git unpark -- a nosuch
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "nosuch is not a held path"
  [ -n "$(git ls-files -- .hangar/stages)" ] ||
    fail "the failed run must not take anything out of the hangar"
  # a pathspec-magic spelling is a literal name that selects nothing: refused, never
  # silently ignored while the parent's subtree is taken
  run git unpark -- a ':(exclude)a/b'
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial ':\(exclude\)a/b is not a held path'
  [ -n "$(git ls-files -- .hangar/stages)" ] ||
    fail "the failed run must not take anything out of the hangar"
}

@test "an absolute path argument is refused with the current-directory recovery" {
  paths_repo u30
  run git unpark -- "$REPO/a"
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "an absolute path is not taken"
  assert_output --partial "name the path from your current directory"
  [ -n "$(git ls-files -- .hangar/stages)" ] ||
    fail "the refused run must not take anything out of the hangar"
}

@test "a trailing slash is the directory itself" {
  paths_repo u31
  run git unpark -- sub/
  assert_success
  assert_output --partial "unchanged (reopened): sub/x"
  assert_output --partial "no file (reopened): sub/y"
  assert_output --partial "2 paths taken out of the hangar; 2 paths reopened; 0 resolutions released"
  [ -n "$(git ls-files -- .hangar/stages/a)" ] ||
    fail "sub/ must not take paths parked outside sub"
}

@test "'.' and '..' resolve, and an empty argument is refused" {
  # from the top, '.' is every held path
  paths_repo u32
  run git unpark -- .
  assert_success
  assert_output --partial "unchanged (reopened): a"
  assert_output --partial "no file (reopened): sub/y"
  assert_output --partial "5 paths taken out of the hangar; 5 paths reopened; 0 resolutions released"
  [ -z "$(git ls-files -- .hangar/stages)" ] || fail "'.' at the top must take every held path"

  # from a subdirectory, '.' is only what is parked under it
  paths_repo u33
  cd sub
  run git unpark -- .
  assert_success
  cd "$REPO"
  assert_output --partial "unchanged (reopened): sub/x"
  assert_output --partial "no file (reopened): sub/y"
  assert_output --partial "2 paths taken out of the hangar; 2 paths reopened; 0 resolutions released"
  [ -n "$(git ls-files -- .hangar/stages/a)" ] ||
    fail "'.' inside sub/ must not take paths parked outside it"

  # from a subdirectory, '..' is every held path and '../other' is other's subtree
  paths_repo u34
  cd sub
  run git unpark -- ..
  assert_success
  cd "$REPO"
  assert_output --partial "unchanged (reopened): other"
  assert_output --partial "5 paths taken out of the hangar; 5 paths reopened; 0 resolutions released"
  paths_repo u35
  cd sub
  run git unpark -- ../other
  assert_success
  cd "$REPO"
  assert_output --partial "unchanged (reopened): other"
  assert_output --partial "1 path taken out of the hangar; 1 path reopened; 0 resolutions released"
  [ -n "$(git ls-files -- .hangar/stages/a)" ] ||
    fail "'../other' must not take paths parked outside other"

  # interior components resolve too: './a' is a, 'a/../other' is other, 'a/..' is the top
  paths_repo u36
  run git unpark -- ./a
  assert_success
  [ -z "$(git ls-files -- .hangar/stages/a)" ] || fail "'./a' must take a's subtree whole"
  paths_repo u37
  run git unpark -- a/../other
  assert_success
  assert_output --partial "unchanged (reopened): other"
  paths_repo u38
  run git unpark -- a/..
  assert_success
  assert_output --partial "5 paths taken out of the hangar; 5 paths reopened; 0 resolutions released"

  # a resolution above the repository root is refused, git's own outside rule
  paths_repo u39
  run git unpark -- ..
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "resolves above the repository root; name the path from the repository root"
  [ -n "$(git ls-files -- .hangar/stages)" ] ||
    fail "the refused run must not take anything out of the hangar"
  cd sub
  run git unpark -- ../..
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "resolves above the repository root"
  cd "$REPO"

  # an empty argument is a usage error from any directory, git add's own rule: never
  # the cwd's whole subtree (the first prototype draft checked emptiness after the
  # prefix join, so from a subdirectory an empty argument silently named the subtree)
  run git unpark -- ''
  assert_failure
  [ "$status" -eq 129 ]
  assert_output --partial "an empty path argument"
  cd sub
  run git unpark -- ''
  assert_failure
  [ "$status" -eq 129 ]
  assert_output --partial "an empty path argument"
  cd "$REPO"
  [ -n "$(git ls-files -- .hangar/stages/sub)" ] ||
    fail "an empty argument must not silently name the cwd's whole subtree"
}

@test "prefix-sibling paths: record order, with paths and without" {
  # a and a.txt are byte-prefix siblings: ls-tree parks a.txt/1 before a/1 ('.' sorts
  # under '/'), so both runs report in record order (a.txt before a); the argument run
  # no longer reports in ls-files byte order, which went with the scratch index.
  prefix_repo() {
    mkrepo "$1"
    printf 'a\n' >a
    printf 't\n' >a.txt
    git add -A && git commit -qm base
    git branch side
    printf 'ours-a\n' >a
    printf 'ours-t\n' >a.txt
    git add -A && git commit -qm ours
    git checkout -q side
    printf 'theirs-a\n' >a
    printf 'theirs-t\n' >a.txt
    git add -A && git commit -qm theirs
    git checkout -q main
    git merge side >/dev/null 2>&1 || true
    git park -b carrier/side >/dev/null && git commit -qm parked
  }
  prefix_repo u20
  run git unpark
  assert_success
  assert_output --partial "2 paths reopened; 0 resolutions released"
  case $output in
  *"reopened): a.txt"$'\n'"unpark: unchanged (reopened): a"*) ;;
  *) fail "without an argument the record order (a.txt before a) was not kept" ;;
  esac
  prefix_repo u21
  run git unpark a a.txt
  assert_success
  assert_output --partial "2 paths reopened; 0 resolutions released"
  case $output in
  *"reopened): a.txt"$'\n'"unpark: unchanged (reopened): a"*) ;;
  *) fail "with arguments the record order (a.txt before a) was not kept" ;;
  esac
}

@test "git commit while unmerged is refused by git itself" {
  outcome_repo u16
  git unpark v1.txt >/dev/null
  run git commit -qm premature
  assert_failure
  assert_output --partial "unmerged"
}

@test "a missing worktree .hangar is refused with the restore recovery" {
  outcome_repo u17
  rm -rf .hangar
  run git unpark v1.txt
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "missing or unreadable"
  assert_output --partial "restore it"
  assert_output --partial "git checkout -- .hangar"
}

@test "a worktree .hangar that is not a directory is refused with the move-away recovery" {
  outcome_repo u21
  rm -rf .hangar
  >.hangar
  run git unpark v1.txt
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "not a directory"
  assert_output --partial "move it away"
}

@test "a symlinked worktree .hangar is refused with the move-away recovery, not the restore" {
  outcome_repo u23
  mv .hangar .hangar-aside
  ln -s .hangar-aside .hangar
  run git unpark v1.txt
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "not a directory"
  assert_output --partial "move it away"
}

@test "an unreadable worktree .hangar manifest is refused with the restore recovery" {
  outcome_repo u24
  : >.hangar/manifest
  run git unpark v1.txt
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "missing or unreadable"
  assert_output --partial "git checkout -- .hangar"
}

@test "a symlink in place of the whole stages directory is refused before the release removes anything" {
  # the release's rm -rf works by the worktree path .hangar/stages/<path>: a link anywhere
  # on it would carry the removal outside the repository
  conflict_repo sy2
  git park -b carrier/side >/dev/null
  git commit -qm parked
  mkdir -p "$CARRIER_WORK/outside/f.txt"
  printf 'precious\n' >"$CARRIER_WORK/outside/f.txt/keeper"
  mv .hangar/stages .hangar/stages-aside
  ln -s "$CARRIER_WORK/outside" .hangar/stages
  run git unpark -- f.txt
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "symlink"
  assert_output --partial "git checkout -- .hangar/stages"
  # the file outside the repository survived the refusal, and nothing was taken out
  [ -f "$CARRIER_WORK/outside/f.txt/keeper" ] ||
    fail "the release removed a file outside the repository"
  [ -n "$(git ls-files -- .hangar/stages)" ] ||
    fail "the refused unpark took the path out of the hangar"
  [ -z "$(git ls-files --unmerged)" ] ||
    fail "the refused unpark reopened the conflict"
}

@test "a symlink on a nested stages path is refused the same way" {
  # the held path sub/f.txt crosses .hangar/stages/sub: a link there would carry the
  # release's rm -rf outside the repository just the same
  mkrepo sy3
  mkdir sub
  printf 'a\nb\nc\n' >sub/f.txt
  printf 'keep\n' >keep.txt
  git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >sub/f.txt
  git add -A && git commit -qm ours
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >sub/f.txt
  git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/side >/dev/null
  git commit -qm parked
  mkdir -p "$CARRIER_WORK/outside/f.txt"
  printf 'precious\n' >"$CARRIER_WORK/outside/f.txt/keeper"
  mv .hangar/stages/sub .hangar/sub-aside
  ln -s "$CARRIER_WORK/outside" .hangar/stages/sub
  run git unpark -- sub/f.txt
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "symlink"
  [ -f "$CARRIER_WORK/outside/f.txt/keeper" ] ||
    fail "the release removed a file outside the repository"
  [ -n "$(git ls-files -- .hangar/stages)" ] ||
    fail "the refused unpark took the path out of the hangar"
  [ -z "$(git ls-files --unmerged)" ] ||
    fail "the refused unpark reopened the conflict"
}

@test "a symlink in place of a path's own stages directory is refused too" {
  conflict_repo sy4
  git park -b carrier/side >/dev/null
  git commit -qm parked
  mkdir -p "$CARRIER_WORK/outside"
  printf 'precious\n' >"$CARRIER_WORK/outside/keeper"
  mv .hangar/stages/f.txt .hangar/f.txt-aside
  ln -s "$CARRIER_WORK/outside" .hangar/stages/f.txt
  run git unpark -- f.txt
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "symlink"
  # rm -rf of the link itself unlinks only the link, outside nothing to lose: the refusal
  # is the contract either way, every component of the hangar's own path a real directory
  [ -f "$CARRIER_WORK/outside/keeper" ] ||
    fail "the release reached a file outside the repository"
  [ -n "$(git ls-files -- .hangar/stages)" ] ||
    fail "the refused unpark took the path out of the hangar"
}

@test "a symlink or a non-regular file in place of the hangar's .gitattributes is refused before the release records it into the carrier" {
  # the release stages the worktree hangar verbatim: a symlink standing there would travel
  # into the carrier as the transit guarantee itself, so unpark refuses it before anything
  # is taken out
  conflict_repo sy13
  git park -b carrier/side >/dev/null
  git commit -qm parked
  printf 'precious\n' >"$CARRIER_WORK/attrs-target"
  rm .hangar/.gitattributes
  ln -s "$CARRIER_WORK/attrs-target" .hangar/.gitattributes
  run git unpark -- f.txt
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "a symlink or a non-regular file stands where the hangar holds its .gitattributes"
  assert_output --partial "git checkout -- .hangar/.gitattributes"
  # nothing was taken out and nothing was recorded: the release never staged the symlink
  [ -n "$(git ls-files -- .hangar/stages)" ] ||
    fail "the refused unpark took the path out of the hangar"
  git diff --cached --quiet ||
    fail "the refused unpark staged something"
  [ "$(cat "$CARRIER_WORK/attrs-target")" = "precious" ] ||
    fail "the refused unpark disturbed a file outside the repository"
  # the named recovery: move it away, restore it, and the release proceeds without it
  rm .hangar/.gitattributes
  git checkout -- .hangar/.gitattributes
  run git unpark -- f.txt
  assert_success
  assert_output --partial "unchanged (reopened)"
  git ls-files -s -- .hangar/.gitattributes | grep -q '^100644 ' ||
    fail "the release staged a foreign entry in place of the transit line"
  # the crafted carrier carries the symlink itself: any clone refuses it the same way, and
  # moving it away drops the foreign entry from the carrier's next release
  conflict_repo sy14
  git park -b carrier/side >/dev/null
  git commit -qm parked
  rm .hangar/.gitattributes
  ln -s "$CARRIER_WORK/attrs-target" .hangar/.gitattributes
  git add .hangar/.gitattributes
  git commit -qm crafted
  run git unpark -- f.txt
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "a symlink or a non-regular file stands where the hangar holds its .gitattributes"
  [ "$(cat "$CARRIER_WORK/attrs-target")" = "precious" ] ||
    fail "the refused unpark disturbed a file outside the repository"
  rm .hangar/.gitattributes
  run git unpark -- f.txt
  assert_success
  git diff --cached --name-only -- .hangar | grep -qxF .hangar/.gitattributes ||
    fail "the release did not drop the crafted transit entry from the carrier"
}

@test "the uncommitted park window is refused, not reported as a missing chain" {
  conflict_repo u30
  git park -b carrier/side >/dev/null
  run git unpark
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "staged but not committed"
  assert_output --partial "git commit"
  case $output in
  *"not a parked merge"*) fail "the window was reported as a missing chain" ;;
  esac
}
