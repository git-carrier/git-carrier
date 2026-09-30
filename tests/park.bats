# park.bats: the hangar writer: the conflict matrix, mode round-trip, the message, the merge-state
# clearing, the carrier naming and relocation, and every refusal.

load helpers

setup() {
  setup_scratch
}

teardown() {
  teardown_scratch
}

@test "the conflict matrix parks: stages byte-exact, file w post-add, plain-rm'd absent" {
  matrix_repo m1
  run git park -b carrier/v1.2.3
  assert_success
  git commit -qm parked
  assert_hangar HEAD
  # stage files 1/2/3 are byte-equal to the pre-park index stage blobs
  [ "$(git rev-parse HEAD:.hangar/stages/c1.txt/2)" = "$S2WANT" ] ||
    fail "stage-2 blob of c1.txt did not round-trip"
  # file w is the post-add stage-0 blob: the parked tree's own content (byte equality by sha), while
  # the worktree file itself is CRLF
  [ "$(git rev-parse HEAD:.hangar/stages/c1.txt/w)" = "$(git rev-parse HEAD:c1.txt)" ] ||
    fail "file w of c1.txt is not the post-add blob"
  od -c c1.txt | head -1 | grep -q '\\r' || fail "fixture: the crlf worktree file is not CRLF"
  # plain-rm'd c3.txt: no file w, and theirs has no file (no stage file 3)
  if git cat-file -e HEAD:.hangar/stages/c3.txt/w 2>/dev/null; then
    fail "plain-rm'd c3.txt must have no file w"
  fi
  if git cat-file -e HEAD:.hangar/stages/c3.txt/3 2>/dev/null; then
    fail "theirs deleted c3.txt: stage file 3 must be absent"
  fi
  # modify/delete survivor c2.txt: ours has no file (no stage file 2)
  if git cat-file -e HEAD:.hangar/stages/c2.txt/2 2>/dev/null; then
    fail "ours deleted c2.txt: stage file 2 must be absent"
  fi
  # the add while the merge is stopped is carried as ordinary content, not as a stage file: the staged
  # snapshot, not the later unstaged re-edit (which stays dirty in the worktree)
  [ "$(git cat-file blob HEAD:s0.txt)" = "s0-SNAPSHOT" ] ||
    fail "the staged mid-merge snapshot was not carried into the parked tree"
  [ "$(cat s0.txt)" = "s0-EDITED" ] || fail "the unstaged re-edit did not survive parking"
  if git cat-file -e HEAD:.hangar/stages/s0.txt/2 2>/dev/null; then
    fail "s0.txt was resolved by its mid-merge add: it must have no stage file"
  fi
}

@test "park relocates the stopped merge onto the carrier: dst untouched, the merge never recreated" {
  conflict_repo m0
  # the message git rendered standing on main is the one park records, never re-rendered for the
  # carrier: the merge was never recreated
  run git park -b carrier/v1.2.3
  assert_success
  assert_output --partial "park: 1 path parked into .hangar on carrier/v1.2.3"
  assert_output --partial "main stays at"
  assert_output --partial "land there later with: git land main"
  # main is untouched at its pre-merge tip, the chain starts on the carrier
  [ "$(git rev-parse main)" = "$O" ] || fail "the relocation moved main"
  [ "$(git symbolic-ref --short HEAD)" = "carrier/v1.2.3" ] ||
    fail "HEAD is not on the carrier branch"
  # the merge state is cleared, and nothing is unmerged anymore: the stored content is staged as
  # the parked tree
  [ ! -e "$(git rev-parse --git-path MERGE_HEAD)" ] || fail "park left MERGE_HEAD behind"
  [ -z "$(git ls-files --unmerged)" ] ||
    fail "the parked index is not the stored frame (it is unmerged, as a recreated conflict would be)"
  git commit -qm parked
  assert_hangar HEAD
  [ "$(git cat-file blob HEAD:.hangar/message)" = "Merge branch 'side'" ] ||
    fail "the recorded message is not the one rendered for main: [$(git cat-file blob HEAD:.hangar/message)]"
}

@test "the carrier name: required on the first park (129), refused on a re-park" {
  conflict_repo m0b
  run git park
  assert_failure
  [ "$status" -eq 129 ]
  assert_output --partial "names the carrier branch"
  assert_output --partial "git park --branch <name>"
  run git park -b
  assert_failure
  [ "$status" -eq 129 ]
  assert_output --partial "needs a name"
  git park -b carrier/side >/dev/null
  git commit -qm parked
  # the merge work already lives on its branch: refused, not ignored
  run git park -b another
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "the merge work already lives on carrier/side"
  # --branch=NAME spells the same flag
  run git park --branch=another
  assert_failure
  [ "$status" -eq 2 ]
}

@test "the carrier name must be valid and free; a remote-tracking collision warns only" {
  conflict_repo m0c
  # an invalid name is an error
  run git park -b 'bad..name'
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "not a valid branch name"
  git branch carrier/side
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "a branch named 'carrier/side' already exists"
  # one refusal whatever the taken branch holds: the recovery is always another name
  assert_output --partial "choose another carrier name"
  # the refused park left the merge standing: nothing moved, nothing staged
  [ "$(git symbolic-ref --short HEAD)" = "main" ] || fail "the refused park moved HEAD"
  [ -e "$(git rev-parse --git-path MERGE_HEAD)" ] ||
    fail "the refused park disturbed the merge"
  git merge --abort
  git branch -D carrier/side >/dev/null
  # a remote-tracking branch by that name never blocks the park: one warning names it
  git update-ref refs/remotes/origin/carrier/side "$(git rev-parse side)"
  git merge side >/dev/null 2>&1 || true
  run git park -b carrier/side
  assert_success
  assert_output --partial "warning: carrier/side already exists as the remote-tracking branch origin/carrier/side"
  # the warned park parked: HEAD on the carrier, the merge state cleared
  [ "$(git symbolic-ref --short HEAD)" = "carrier/side" ] ||
    fail "the warned park did not move HEAD"
  [ ! -e "$(git rev-parse --git-path MERGE_HEAD)" ] ||
    fail "the warned park left the merge standing"
}

@test "a taken carrier name holding a chain draws the same refusal as any other" {
  conflict_repo m0d
  git park -b carrier/first >/dev/null
  git commit -qm first
  # a second stopped merge on main, to take a carrier name again
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  run git park -b carrier/first
  assert_failure
  [ "$status" -eq 2 ]
  # the taken branch's content is never read: a chain draws the same refusal and recovery
  assert_output --partial "a branch named 'carrier/first' already exists"
  assert_output --partial "choose another carrier name"
  # the refused park left the merge standing: nothing moved, nothing staged
  [ "$(git symbolic-ref --short HEAD)" = "main" ] || fail "the refused park moved HEAD"
  [ -e "$(git rev-parse --git-path MERGE_HEAD)" ] ||
    fail "the refused park disturbed the merge"
}

@test "a pushed handoff under the carrier name warns; the park proceeds" {
  conflict_repo m0e
  git park -b carrier/first >/dev/null
  git commit -qm first
  local chain
  chain=$(git rev-parse carrier/first)
  git checkout -q main
  git branch -D carrier/first >/dev/null
  # the pushed form: the local branch gone, the remote-tracking ref a live handoff
  git update-ref refs/remotes/origin/carrier/first "$chain"
  git merge side >/dev/null 2>&1 || true
  run git park -b carrier/first
  assert_success
  assert_output --partial "warning: carrier/first already exists as the remote-tracking branch origin/carrier/first"
  # the warned park parked: HEAD on the carrier, the merge state cleared
  [ "$(git symbolic-ref --short HEAD)" = "carrier/first" ] ||
    fail "the warned park did not move HEAD"
  [ ! -e "$(git rev-parse --git-path MERGE_HEAD)" ] ||
    fail "the warned park left the merge standing"
}

@test "file w over prefix-sibling paths; a plain-rm'd conflict has none" {
  mkrepo m3
  printf 'a\n' >a
  printf 't\n' >a.txt
  printf 'd\n' >d.txt
  git add -A && git commit -qm base
  git branch side
  printf 'ours-a\n' >a
  printf 'ours-t\n' >a.txt
  printf 'ours-d\n' >d.txt
  git add -A && git commit -qm ours
  git checkout -q side
  printf 'theirs-a\n' >a
  printf 'theirs-t\n' >a.txt
  git rm -q d.txt
  git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  rm -f d.txt # modify/delete, plain-rm'd: stages as a deletion, no file w
  run git park -b carrier/x
  assert_success
  git commit -qm parked
  assert_hangar HEAD
  # a and a.txt are byte-prefix siblings: 'a.txt/1' parks before 'a/1' in ls-tree order while
  # ls-files lists a before a.txt. The w files must still land on their own paths
  [ "$(git rev-parse HEAD:.hangar/stages/a/w)" = "$(git rev-parse HEAD:a)" ] ||
    fail "file w of a is not the post-add blob"
  [ "$(git rev-parse HEAD:.hangar/stages/a.txt/w)" = "$(git rev-parse HEAD:a.txt)" ] ||
    fail "file w of a.txt is not the post-add blob"
  if git cat-file -e HEAD:.hangar/stages/d.txt/w 2>/dev/null; then
    fail "the plain-rm'd modify/delete must have no file w"
  fi
}

@test "the parked commit is one ordinary parent; untracked and ignored stay out of the chain" {
  matrix_repo m2
  git park -b carrier/v1.2.3 >/dev/null
  git commit -qm parked
  [ "$(git rev-list --parents -n 1 HEAD | wc -w)" = "2" ] ||
    fail "the parked commit is not single-parent"
  if git ls-tree -r --name-only HEAD | grep -qx new.txt; then
    fail "untracked new.txt was swept into the chain"
  fi
  if git ls-tree -r --name-only HEAD | grep -qx junk.out; then
    fail "ignored junk.out was swept into the chain"
  fi
  [ "$(git status --porcelain -- new.txt)" = "?? new.txt" ] || fail "new.txt did not stay untracked"
  [ -f junk.out ] || fail "ignored junk.out left the worktree"
}

@test "unrelated dirty tracked files stay out of the chain unless deliberately staged" {
  conflict_repo m4
  # keep.txt is tracked and dirty, and the merge never touches it: park must leave it alone
  printf 'UNSTAGED WIP\n' >>keep.txt
  git park -b carrier/side >/dev/null
  git commit -qm parked
  [ "$(git cat-file blob HEAD:keep.txt)" = "keep" ] ||
    fail "an unrelated unstaged change was swept into the chain"
  [ "$(cat keep.txt)" = "keep
UNSTAGED WIP" ] || fail "the unrelated worktree change did not survive parking"

  # deliberate inclusion stays available: staged before park, it is carried as it would be in any
  # mid-merge commit
  conflict_repo m5
  printf 'STAGED ON PURPOSE\n' >>keep.txt
  git add keep.txt
  git park -b carrier/side >/dev/null
  git commit -qm parked
  [ "$(git cat-file blob HEAD:keep.txt)" = "keep
STAGED ON PURPOSE" ] || fail "a deliberately staged change was not carried into the chain"
}

@test "exec and symlink modes round-trip through stage file tree entries" {
  matrix_repo m3
  git park -b carrier/v1.2.3 >/dev/null
  git commit -qm parked
  local mode
  mode=$(git ls-tree HEAD:.hangar/stages/run.sh | sed -n 's/^\([0-9]*\) blob.*/\1/p' | sort -u | tr '\n' ' ')
  [ "$mode" = "100755 " ] || fail "run.sh stage files are not all 100755: [$mode]"
  mode=$(git ls-tree HEAD:.hangar/stages/link.txt | sed -n 's/^\([0-9]*\) blob.*/\1/p' | sort -u | tr '\n' ' ')
  [ "$mode" = "120000 " ] || fail "link.txt stage files are not all 120000: [$mode]"
  [ -L .hangar/stages/link.txt/2 ] || fail "the symlink stage file is not a symlink in the worktree"
  [ "$(readlink .hangar/stages/link.txt/2)" = "ours-link" ] ||
    fail "symlink stage file 2 does not hold ours' target"
}

@test "park clears the merge state: MERGE_HEAD, MERGE_MSG, MERGE_MODE, MERGE_RR are gone" {
  conflict_repo m4
  local f
  touch "$(git rev-parse --git-path MERGE_RR)"
  git park -b carrier/side >/dev/null
  for f in MERGE_HEAD MERGE_MSG MERGE_MODE MERGE_RR; do
    if [ -e "$(git rev-parse --git-path "$f")"; then
      fail "park left $f behind"
    fi
  done
  return 0
}

@test "the message is rendered with stripspace: # Conflicts: stripped" {
  conflict_repo m5
  grep -q '# Conflicts:' "$(git rev-parse --git-path MERGE_MSG)" ||
    fail "fixture: MERGE_MSG has no conflicts block"
  git park -b carrier/side >/dev/null
  git commit -qm parked
  [ "$(git cat-file blob HEAD:.hangar/message)" = "Merge branch 'side'" ] ||
    fail "the message was not rendered to [Merge branch 'side']"
}

@test "the manifest's source-desc is derived once at park: tag, then remote-tracking, else the commit id and the park warning" {
  # an annotated tag: MERGE_HEAD holds the tag object id verbatim, and the desc names the tag
  mkrepo m6a
  printf 'p\nq\nr\n' >t.txt
  git add -A && git commit -qm base
  git branch side
  printf 'p\nOURS\nr\n' >t.txt
  git add -A && git commit -qm ours
  git checkout -q side
  printf 'p\nTHEIRS\nr\n' >t.txt
  git add -A && git commit -qm theirs
  git tag -a v1.2.3 -m "release v1.2.3" side
  TAGV=$(git rev-parse v1.2.3)
  git checkout -q main
  git merge v1.2.3 >/dev/null 2>&1 || true
  [ "$(cat "$(git rev-parse --git-path MERGE_HEAD)")" = "$TAGV" ] ||
    fail "fixture: git did not record the tag id in MERGE_HEAD"
  run git park -b carrier/v1.2.3
  assert_success
  case $output in
  *"warning:"*) fail "a tagged source drew a warning (output: $output)" ;;
  esac
  git commit -qm parked
  assert_hangar HEAD
  [ "$(manifest_value HEAD source)" = "$TAGV" ] ||
    fail "the manifest's source is not the verbatim tag object id"
  [ "$(git cat-file -t "$(manifest_value HEAD source)")" = "tag" ] ||
    fail "the manifest's source does not name a tag object"
  [ "$(manifest_value HEAD source-desc)" = "tag 'v1.2.3'" ] ||
    fail "the desc is not the tag class: [$(manifest_value HEAD source-desc)]"

  # a remote-tracking merge: the desc names the remote-tracking branch, and no warning is drawn
  conflict_repo m6b
  git update-ref refs/remotes/origin/side "$(git rev-parse side)"
  run git park -b carrier/side
  assert_success
  case $output in
  *"warning:"*) fail "a remote-tracking source drew a warning (output: $output)" ;;
  esac
  git commit -qm parked
  [ "$(manifest_value HEAD source-desc)" = "remote-tracking branch 'origin/side'" ] ||
    fail "the desc is not the remote-tracking class: [$(manifest_value HEAD source-desc)]"

  # a bare commit merge (no tag, no remote-tracking at it): the commit class with the full id,
  # and the park warning: the source has no name here that a landing elsewhere could fetch by
  conflict_repo m6c
  SRC=$(git rev-parse side)
  SHORT=$(git rev-parse --short "$SRC")
  run git park -b carrier/side
  assert_success
  assert_output --partial "warning: the merge's source $SHORT has no tag or remote-tracking branch here"
  git commit -qm parked
  [ "$(manifest_value HEAD source-desc)" = "commit '$SRC'" ] ||
    fail "the desc is not the commit class: [$(manifest_value HEAD source-desc)]"
}

@test "a resolved-but-unfinished stop (hook rejected the auto-commit) parks an empty mirror" {
  conflict_repo m7
  git show :3:f.txt >f.txt
  git add f.txt
  [ -z "$(git ls-files --unmerged)" ] || fail "fixture: the merge is not fully resolved"
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] || fail "fixture: MERGE_HEAD is not live"
  run git park -b carrier/side
  assert_success
  git commit -qm parked
  assert_hangar HEAD
  [ "$(git ls-tree -r --name-only HEAD | grep -c '^\.hangar/stages/')" = "0" ] ||
    fail "the empty mirror parked stage entries"
}

@test "a parked tip with nothing unmerged is a no-op" {
  conflict_repo m8
  git park -b carrier/side >/dev/null && git commit -qm parked
  # right after the parked commit: nothing unmerged, no MERGE_HEAD
  run git park
  assert_success
  assert_output --partial "already parked"
  # and after the last path is resolved and released: still a no-op
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt
  git rm -q -r .hangar/stages/f.txt
  git commit -qm resolve
  run git park
  assert_success
  assert_output --partial "already parked"
}

@test "a re-park of a merely reopened conflict matches HEAD: no commit needed" {
  conflict_repo m8r
  git park -b carrier/side >/dev/null && git commit -qm parked
  TIP=$(git rev-parse HEAD)
  # re-parking the reopened conflict writes the same stage files back, so the staged result is
  # byte-identical to HEAD: nothing to commit
  git unpark >/dev/null
  run git park
  assert_success
  assert_output --partial "1 path re-parked; the restored state matches HEAD: no commit needed"
  [ "$(git rev-parse HEAD)" = "$TIP" ] || fail "the re-park expected a commit for nothing"
  [ -z "$(git status --porcelain)" ] || fail "the re-park left a dirty checkout"
  [ -z "$(git ls-files --unmerged)" ] || fail "the reopened conflict is still unmerged"
}

@test "a re-park unions: released paths stay released, message verbatim, desc untouched" {
  mkrepo m9
  printf 'a\nb\nc\n' >f.txt
  printf 'x\ny\n' >g.txt
  git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >f.txt
  printf 'x\nOURS\n' >g.txt
  git add -A && git commit -qm ours
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt
  printf 'x\nTHEIRS\n' >g.txt
  git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/side >/dev/null && git commit -qm parked
  # make the message something stripspace would change: a comment line
  printf "Merge branch 'side'\n\n# kept on purpose\n" >.hangar/message
  # and an unknown manifest field is carried through a re-park untouched: the extension path of a newer
  # same-major tool
  printf 'future-field: carried\n' >>.hangar/manifest
  git add .hangar/message .hangar/manifest && git commit -qm "message with a comment"
  MSGWANT=$(git cat-file blob HEAD:.hangar/message)
  git unpark >/dev/null
  # resolve f.txt by content; g.txt stays unmerged (the re-park)
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt
  run git park
  assert_success
  git commit -qm reparked
  assert_hangar HEAD
  # f.txt's directory was released by the unpark: it stays released
  if git cat-file -e HEAD:.hangar/stages/f.txt/2 2>/dev/null; then
    fail "released f.txt re-entered the record"
  fi
  # g.txt is still held, with a fresh file w (the stored resolution)
  git cat-file -e HEAD:.hangar/stages/g.txt/2 2>/dev/null || fail "still-held g.txt lost its stage files"
  [ "$(git rev-parse HEAD:.hangar/stages/g.txt/w)" = "$(git rev-parse HEAD:g.txt)" ] ||
    fail "g.txt file w is not the stored post-add content"
  # the message was trusted verbatim, never re-rendered
  [ "$(git cat-file blob HEAD:.hangar/message)" = "$MSGWANT" ] ||
    fail "the re-park re-rendered the message instead of trusting it verbatim"
  # and the unknown field survived the re-park
  [ "$(manifest_value HEAD future-field)" = "carried" ] ||
    fail "the re-park dropped an unknown manifest field"
}

@test "octopus merges are refused" {
  mkrepo m10
  printf 'a\n' >f.txt && git add -A && git commit -qm base
  git branch b1 && git branch b2
  printf 'one\n' >one.txt && git add -A && git commit -qm c1
  git checkout -q b1 && printf 'b1\n' >f.txt && git add -A && git commit -qm B1
  git checkout -q b2 && printf 'b2\n' >f.txt && git add -A && git commit -qm B2
  git checkout -q main
  git merge b1 b2 >/dev/null 2>&1 || true
  [ "$(grep -c . "$(git rev-parse --git-path MERGE_HEAD)")" = "2" ] ||
    fail "fixture: not an octopus stop"
  run git park -b carrier/oct
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "octopus"
  assert_output --partial "MERGE_HEAD lists 2 heads"
  # a refused park creates no carrier
  [ -z "$(git branch --list carrier/oct)" ] || fail "the refused park created the carrier branch"
}

@test "gitlink conflicts are refused, naming the path and the escape" {
  mkrepo sub
  SUB=$REPO
  printf 's\n' >s.txt && git add -A && git commit -qm base
  printf 's1\n' >s.txt && git add -A && git commit -qm sub1 # main
  git checkout -q -b subb HEAD~1 && printf 's2\n' >s.txt && git add -A && git commit -qm sub2
  git checkout -q -b subc HEAD~1 && printf 's3\n' >s.txt && git add -A && git commit -qm sub3
  git checkout -q main
  mkrepo m11
  git -c protocol.file.allow=always submodule add -q "$SUB" sub >/dev/null 2>&1 ||
    fail "fixture: submodule add failed"
  git commit -qm base
  git branch side
  git -C sub checkout -q subb
  git add sub && git commit -qm ours
  git checkout -q side
  git -C sub checkout -q subc
  git add sub && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git ls-files --unmerged | grep -q '^160000' || fail "fixture: no gitlink conflict"
  run git park -b carrier/sub
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "gitlink"
  assert_output --partial "sub"
  assert_output --partial "submodule pointers"
  # the path is listed once, not once per stage record
  assert_output --partial "conflicts at: sub;"
  [ -z "$(git branch --list carrier/sub)" ] || fail "the refused park created the carrier branch"
}

@test "a .hangar of the user's in the worktree: the shapes are refused, a manifest that is not ours dies" {
  conflict_repo m12
  printf 'mine\n' >.hangar
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "touch"
  rm -f .hangar
  # a directory whose manifest's first line is not a format id: it is not this tool's
  mkdir .hangar && printf 'junk\n' >.hangar/manifest
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "cannot verify"
  assert_output --partial "hangar-format id"
  rm -rf .hangar
  mkdir elsewhere && ln -s elsewhere .hangar
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "touch"
}

@test "a symlink standing on a stages path is refused before the re-park writes through it" {
  # park writes the hangar by the worktree path .hangar/stages/<path>: a link anywhere on
  # it would carry the writes outside the repository, so the re-park refuses it before
  # anything moves
  mkrepo sy1
  printf 'a\nb\nc\n' >f.txt
  printf 'x\ny\n' >g.txt
  git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >f.txt
  printf 'x\nOURS\n' >g.txt
  git add -A && git commit -qm ours
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt
  printf 'x\nTHEIRS\n' >g.txt
  git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git park -b carrier/side >/dev/null
  git commit -qm parked
  git unpark f.txt >/dev/null # the reopened f.txt is the re-park's subject; g.txt stays held
  mkdir -p "$CARRIER_WORK/outside/f.txt"
  printf 'precious\n' >"$CARRIER_WORK/outside/f.txt/keeper"
  mv .hangar/stages .hangar/stages-aside
  ln -s "$CARRIER_WORK/outside" .hangar/stages
  run git park
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "symlink"
  assert_output --partial "git checkout -- .hangar/stages"
  # the refused re-park wrote nothing through the link: outside is untouched
  [ ! -e "$CARRIER_WORK/outside/f.txt/1" ] ||
    fail "the re-park wrote a stage file outside the repository"
  [ "$(cat "$CARRIER_WORK/outside/f.txt/keeper")" = "precious" ] ||
    fail "the refused re-park disturbed a file outside the repository"
  # nothing moved: the reopened conflict still stands
  [ -n "$(git ls-files --unmerged -- f.txt)" ] ||
    fail "the refused re-park disturbed the reopened conflict"
}

@test "the format line: a greater major refuses with the upgrade, anything else dies" {
  conflict_repo m14
  mkdir .hangar
  printf 'hangar-format: 2\n' >.hangar/manifest
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "newer hangar format"
  assert_output --partial "upgrade"
  case $output in
  *verify*) fail "an integer greater major was read as not this tool's" ;;
  esac
  # there is no version 0: format 1 is the first one, so a zero major is not this tool's
  printf 'hangar-format: 0\n' >.hangar/manifest
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "cannot verify"
  case $output in
  *upgrade*) fail "version 0 was read as an upgrade" ;;
  esac
  # no leading zeros: a padded number is not this tool's by rule, never a version
  printf 'hangar-format: 01\n' >.hangar/manifest
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "cannot verify"
  case $output in
  *older*) fail "a leading zero was read as an older major" ;;
  esac
  # the v spelling is a pre-release draft, never an upgrade hint
  printf 'hangar-format: v2\n' >.hangar/manifest
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "cannot verify"
  case $output in
  *upgrade*) fail "a v-spelled draft was read as an upgrade" ;;
  esac
  # and so is the dotted spelling
  printf 'hangar-format: 1.0\n' >.hangar/manifest
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 1 ]
  assert_output --partial "cannot verify"
}

@test "an unfinished git rebase, cherry-pick, or revert is refused" {
  mkrepo m15
  printf 'a\n' >f.txt && git add -A && git commit -qm base
  git branch side && printf 'b\n' >f.txt && git add -A && git commit -qm ours
  git checkout -q side && printf 'c\n' >f.txt && git add -A && git commit -qm theirs
  git checkout -q main
  git cherry-pick side >/dev/null 2>&1 || true
  [ -e "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ] ||
    fail "fixture: no cherry-pick in progress"
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "CHERRY_PICK_HEAD"
  assert_output --partial "cherry-pick is in progress"
  git cherry-pick --abort
  git revert --no-edit side >/dev/null 2>&1 || true
  [ -e "$(git rev-parse --git-path REVERT_HEAD)" ] || fail "fixture: no revert in progress"
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "REVERT_HEAD"
  assert_output --partial "revert is in progress"
  git revert --abort 2>/dev/null || true
  git rebase side >/dev/null 2>&1 || true
  [ -d "$(git rev-parse --git-path rebase-merge)" ] || fail "fixture: no rebase in progress"
  run git park -b carrier/side
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "REBASE_HEAD"
  assert_output --partial "rebase is in progress"
}

@test "an unfinished git am is refused: a re-park must not absorb the am's conflicts" {
  conflict_repo m21
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
  if [ -e "$(git rev-parse --git-path REBASE_HEAD)" ]; then
    fail "fixture: this git's am writes REBASE_HEAD (the blind spot is gone)"
  fi
  run git park
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "am is in progress"
  git am --abort
  # nothing was absorbed: the hangar still parks exactly f.txt's stages
  [ "$(git ls-tree --name-only HEAD:.hangar/stages)" = "f.txt" ] ||
    fail "the am stop changed the parked set"
}

@test "a detached HEAD parks just the same: the carrier is created from anywhere" {
  mkrepo m16
  printf 'a\nb\nc\n' >f.txt && git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >f.txt && git add -A && git commit -qm ours
  O=$(git rev-parse HEAD)
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt && git add -A && git commit -qm theirs
  git checkout -q main
  git checkout -q --detach
  git merge side >/dev/null 2>&1 || true
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] ||
    fail "fixture: the merge did not stop on the detached head"
  run git park -b carrier/side
  assert_success
  assert_output --partial "parked into .hangar on carrier/side"
  assert_output --partial "detached HEAD; land it later with: git land <dst>"
  [ "$(git symbolic-ref --short HEAD)" = "carrier/side" ] ||
    fail "the carrier was not created from the detached head"
  [ "$(git rev-parse main)" = "$O" ] || fail "the detached park moved main"
  git commit -qm parked
  assert_hangar HEAD
  # and the chain lands from the carrier like any other
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git rm -q -r .hangar/stages/f.txt && git commit -qm resolve
  run git land main
  assert_success
  assert_prepared main "$O" "$(git rev-parse side)" "$(git rev-parse carrier/side)" "commit '$(git rev-parse side)'"
}

@test "an empty message render parks no message file; the landing renders fresh, no comment" {
  conflict_repo m17
  tag_the_source
  printf '# only a comment\n' >"$(git rev-parse --git-path MERGE_MSG)"
  run git park -b carrier/v1.2.3
  assert_success
  git commit -qm parked
  if git cat-file -e HEAD:.hangar/message 2>/dev/null; then
    fail "an empty render must park no message at all"
  fi
  # resolve, then land: the prepared message is the fresh render alone (nothing to comment)
  printf 'a\nRESOLVED\nc\n' >f.txt
  git add f.txt && git rm -q -r .hangar/stages/f.txt && git commit -qm resolve
  run git land main
  assert_success
  assert_prepared main "$O" "$(git rev-parse side)" "$(git rev-parse carrier/v1.2.3)" "tag 'v1.2.3'"
  if grep -q 'Message recorded at park' "$(git rev-parse --git-path MERGE_MSG)"; then
    fail "an empty record produced a comment block"
  fi
}

@test "a symlink target starting with a dash round-trips (ln -s --)" {
  mkrepo m18
  printf 'a\n' >f.txt && git add -A && git commit -qm base
  git branch side
  ln -s -- '-dashtarget' link && git add -A && git commit -qm ours
  git checkout -q side
  ln -s -- 'other' link && git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git ls-files --unmerged | grep -q '^120000' || fail "fixture: no symlink conflict"
  run git park -b carrier/side
  assert_success
  [ "$(readlink .hangar/stages/link/2)" = '-dashtarget' ] ||
    fail "the dashed target was not preserved: $(readlink .hangar/stages/link/2)"
}

@test "a symlink target ending in a newline parks byte-exact, even an all-newline target" {
  mkrepo m20
  printf 'a\n' >f.txt && printf 'g\n' >g.txt && git add -A && git commit -qm base
  git branch side
  # f.txt: a trailing newline (command substitution strips it); g.txt: nothing but a newline (the
  # substitution empties the argument). Both must park byte-exact.
  rm f.txt && ln -s $'foo\n' f.txt
  rm g.txt && ln -s $'\n' g.txt
  git add -A && git commit -qm ours
  git checkout -q side
  rm f.txt && ln -s bar f.txt
  rm g.txt && ln -s baz g.txt
  git add -A && git commit -qm theirs
  git checkout -q main
  git merge side >/dev/null 2>&1 || true
  git ls-files --unmerged | grep -q '^120000' || fail "fixture: no symlink conflict"
  run git park -b carrier/side
  assert_success
  git commit -qm parked
  assert_hangar HEAD
  local fwant gwant
  fwant=$(printf 'foo\n' | git hash-object --stdin)
  gwant=$(printf '\n' | git hash-object --stdin)
  [ "$(git rev-parse HEAD:.hangar/stages/f.txt/2)" = "$fwant" ] ||
    fail "stage 2 of f.txt lost the target's trailing newline"
  [ "$(git rev-parse HEAD:.hangar/stages/f.txt/w)" = "$fwant" ] ||
    fail "file w of f.txt lost the target's trailing newline"
  [ "$(git rev-parse HEAD:.hangar/stages/g.txt/2)" = "$gwant" ] ||
    fail "stage 2 of the all-newline target is wrong"
  [ "$(git rev-parse HEAD:.hangar/stages/g.txt/w)" = "$gwant" ] ||
    fail "file w of the all-newline target is wrong"
  [ "$(readlink -n .hangar/stages/f.txt/w | git hash-object --stdin)" = "$fwant" ] ||
    fail "the worktree symlink of file w lost the trailing newline"
}

@test "park works under a sparse checkout that excludes the repo root" {
  mkrepo m19
  mkdir sub
  printf 'a\nb\nc\n' >f.txt
  printf 'k\n' >sub/deep.txt
  git add -A && git commit -qm base
  git branch side
  printf 'a\nOURS\nc\n' >f.txt && git commit -qam ours
  git checkout -q side
  printf 'a\nTHEIRS\nc\n' >f.txt && git commit -qam theirs
  git checkout -q main
  git sparse-checkout set --cone sub
  git merge side >/dev/null 2>&1 || true
  run git park -b carrier/side
  assert_success
  [ "$(git ls-files -s -- .hangar | wc -l)" -gt 0 ] ||
    fail "the hangar was not staged under a sparse checkout"
}

@test "a failed park leaves the merge recoverable, relocated onto the carrier" {
  conflict_repo m20
  # Force a stage-file failure after the unmerged dump (a dangling stage blob). The branch
  # creation is park's first mutation, so the failed park leaves the merge standing ON THE
  # CARRIER, mid-merge and abortable; the merge state is never cleared.
  git update-index --index-info <<EOF
100644 0000000000000000000000000000000000000001 1	f.txt
100644 0000000000000000000000000000000000000002 2	f.txt
100644 0000000000000000000000000000000000000003 3	f.txt
EOF
  run git park -b carrier/side
  assert_failure
  [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] ||
    fail "a failed park cleared MERGE_HEAD: the merge is no longer recoverable"
  [ "$(git symbolic-ref --short HEAD)" = "carrier/side" ] ||
    fail "the failed park left HEAD off the carrier: $(git symbolic-ref --short HEAD)"
  git merge --abort || fail "the merge could not be aborted after the failed park"
  # the unwind back to the branch the merge started on
  git switch main || fail "the carrier could not be left"
  git branch -D carrier/side >/dev/null || fail "the empty carrier could not be removed"
  rm -rf .hangar
  [ -z "$(git status --porcelain)" ] || fail "the unwind left a dirty checkout"
}

# The uncommitted park window: park stages the hangar and never commits, so until the user's own
# commit the chain exists only in the index, invisible to the chain lookups. All three applets
# name it explicitly.
@test "the uncommitted park window is named, with the commit and the unwind" {
  conflict_repo m30
  git park -b carrier/side >/dev/null
  # the hangar is staged, HEAD carries none
  git ls-files --cached --error-unmatch -- .hangar/manifest >/dev/null ||
    fail "fixture: the hangar is not staged"
  if git cat-file -e HEAD:.hangar/manifest 2>/dev/null; then
    fail "fixture: HEAD already carries the hangar"
  fi
  run git park
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "staged but not committed"
  assert_output --partial "git commit"
  assert_output --partial "--no-verify"
  assert_output --partial "git reset --hard"
}

@test "the park window's named unwind leaves an ordinary repository" {
  conflict_repo m32
  git park -b carrier/side >/dev/null
  git reset -q --hard
  rm -rf .hangar
  [ -z "$(git status --porcelain)" ] || fail "the unwind did not leave a clean checkout"
  run git park
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "no stopped merge here"
}

@test "a chain tip with a mangled or incomplete manifest is named at the re-park" {
  conflict_repo m34
  SRC=$(git rev-parse side)
  git park -b carrier/side >/dev/null && git commit -qm parked
  # the manifest is machine-written: a mangled one is corruption. The re-park refuses it with the
  # hand fix, never misreading the damaged chain as no stopped merge
  printf 'hangar-format: 1\nsource: not-an-object-id\nsource-desc: commit x\n' >.hangar/manifest
  git add .hangar/manifest && git commit -qm "mangle the source"
  # unpark reopens f.txt: unmerged entries over the damaged chain tip, the re-park's subject
  git unpark >/dev/null
  run git park
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "mangled"
  assert_output --partial "not an object id"
  case $output in
  *"no stopped merge"*) fail "the damaged chain was misread as no stopped merge" ;;
  esac

  # and an incomplete one: a missing field is a missing record
  conflict_repo m34b
  SRC=$(git rev-parse side)
  git park -b carrier/side >/dev/null && git commit -qm parked
  printf 'hangar-format: 1\nsource: %s\n' "$SRC" >.hangar/manifest
  git add .hangar/manifest && git commit -qm "drop the desc"
  git unpark >/dev/null
  run git park
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "incomplete"
  assert_output --partial "no source-desc"
}

@test "a chain tip with stages as a file is named at the re-park" {
  conflict_repo m36
  git park -b carrier/side >/dev/null && git commit -qm parked
  # the tip's stages is a file, not a directory: a hand edit the shape check names
  git rm -q -r .hangar/stages
  printf 'torn\n' >.hangar/stages
  git add -f .hangar/stages && git commit -qm "stages as a file"
  # unmerged entries over the tip: the re-park's subject, fed by hand as unpark would feed it
  {
    printf '100644 %s 1\tf.txt\0' "$(git rev-parse "$OURS^1:f.txt")"
    printf '100644 %s 2\tf.txt\0' "$(git rev-parse "$OURS:f.txt")"
    printf '100644 %s 3\tf.txt\0' "$(git rev-parse "$THEIRS:f.txt")"
  } | git update-index -z --index-info
  run git park
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "mangled hangar"
  assert_output --partial "not a directory"
  case $output in
  *"no stopped merge"*) fail "the damaged chain was misread as no stopped merge" ;;
  esac
}

@test "an uncommitted hand edit to message survives a re-park (the one place a hand edit may land)" {
  conflict_repo m35
  git park -b carrier/side >/dev/null && git commit -qm parked
  git unpark >/dev/null
  printf "Merge branch 'side'\n\n# hand note\n" >.hangar/message
  run git park
  assert_success
  git commit -qm reparked
  [ "$(git cat-file blob HEAD:.hangar/message)" = "Merge branch 'side'

# hand note" ] ||
    fail "the re-park clobbered the hand-edited message"
}

@test "file w survives the spec chunk boundary: a swept nested path, a smaller sibling" {
  conflict_repo m36
  blob() { printf '%s\n' "$2" | git hash-object -w --stdin; }
  # ~700-byte names: any two specs exceed one chunk together (see dump_postadd), so the
  # trio lands in three different chunks
  seg=$(printf '%170s' '' | tr ' ' x)
  A="g/$seg/$seg/$seg/$seg/a" # the ancestor, resolved as a deletion: its spec sweeps P's entry in
  P="$A/b" # the nested path, kept
  Q="$A-c" # the sibling: '-' sorts below '/', so Q sorts between A and P
  # hand-fed, as unpark's reopen would leave it: git renames colliding paths aside, so no
  # live merge parks a path nested under another (craft_hangar)
  {
    printf '100644 %s 2\te.txt\0' "$(blob x e-ours)" # record-less: deletion-resolved, ahead of f.txt
    printf '100644 %s 2\t%s\0' "$(blob x a-ours)" "$A"
    printf '100644 %s 3\t%s\0' "$(blob x p-theirs)" "$P"
    printf '100644 %s 2\t%s\0' "$(blob x q-ours)" "$Q"
  } | git update-index -z --index-info
  mkdir -p "$A"
  printf 'p-kept\n' >"$P"
  printf 'q-kept\n' >"$Q"
  # one spec per xargs invocation, so the old concatenation join would break at every boundary
  shimd=$CARRIER_WORK/xargs-one-spec
  mkdir -p "$shimd"
  printf '#!/bin/sh\nexec "%s" -n 1 "$@"\n' "$(command -v xargs)" >"$shimd/xargs"
  chmod +x "$shimd/xargs"
  PATH="$shimd:$PATH"
  run git park -b carrier
  assert_success
  assert_output --partial "park: 5 paths parked"
  git commit -qm parked
  # the pin: A's chunk sweeps P's record in ahead of Q's own, and Q's own chunk must read it
  [ "$(git rev-parse HEAD:.hangar/stages/$Q/w)" = "$(blob x q-kept)" ] ||
    fail "the sibling took no w at the chunk boundary"
  [ "$(git rev-parse HEAD:.hangar/stages/$P/w)" = "$(blob x p-kept)" ] ||
    fail "the nested path took no w"
  if git cat-file -e "HEAD:.hangar/stages/$A/w" 2>/dev/null; then
    fail "the deletion-resolved ancestor took a w"
  fi
  [ "$(git rev-parse HEAD:.hangar/stages/f.txt/w)" = "$(git rev-parse HEAD:f.txt)" ] ||
    fail "f.txt took no w"
  if git cat-file -e HEAD:.hangar/stages/e.txt/w 2>/dev/null; then
    fail "the deletion-resolved e.txt took a w"
  fi
  [ "$(git ls-tree -r --name-only HEAD -- .hangar/stages | wc -l)" -eq 10 ] ||
    fail "stage file count is $(git ls-tree -r --name-only HEAD -- .hangar/stages | wc -l), want 10"
}
