#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# git-carrier: work a conflicted merge as ordinary commits.
#
# One file, three applets: park, unpark, land. Git finds a subcommand by exact name on
# PATH, so git-park, git-unpark, and git-land are symlinks to this file.
#
# What a command does is in its -h text, printed by print_help below. How it does its work is in
# the comment block above the applet's main function.
#
# Rules for the whole file (each applet's header adds its own):
# - Exit codes: 0 success, 1 error, 2 refusal over state the user can change, 129 usage.
# - Applets never commit; the user's own `git commit` is the approval.
# - Every refusal names its recovery. Reports go to stdout, refusals to stderr, both prefixed
#   with the applet name; a warning goes to stderr the same way, marked "warning:", and the
#   run continues. Plain ASCII, lowercase and imperative like git's own messages.
# - The hangar directory is specified in docs/hangar-format.txt (format 1).
# - Paths are parsed NUL-delimited, through temp files, never piped into loops. All temp files
#   live under one mktemp -d, removed by an EXIT trap. MERGE_HEAD and friends are found with
#   `git rev-parse --git-path`, never a literal .git/ path.
# - Git runs as `git -C "$top"`; applets never cd, so the user's cwd survives and unpark paths
#   honor it.
# - Bash 3.2 floor (macOS /bin/bash): no declare -A, mapfile/readarray, ${var,,}, negative array
#   indices, or other post-3.2 features.
# - LC_ALL=C keeps grep and friends on raw bytes.

set -euo pipefail
export LC_ALL=C

CARRIER_VERSION='0.1.0'
# Minimum Git version required for `git add --sparse` and `for-each-ref %(worktreepath)`.
CARRIER_GIT_FLOOR='2.34'
FORMAT_LINE='hangar-format: 1'
HANGAR='.hangar'
ATTRS_LINE='* -text -filter -ident -working-tree-encoding'

# Globals set at dispatch.
APPLET=carrier
USAGE='git-carrier'
top=
td=

# The short help text. Git routes `git <verb> --help` to a man page this project does not
# ship, so -h is the argument that works through git.
# --help, reached by the symlinks directly, prints to stdout, exit 0.
print_help() {
  case $APPLET in
  park)
    cat <<'EOF'
usage: git park [--branch <carrier-branch>]

Move a merge that stopped at conflicts onto a carrier branch, so the work can
be committed, pushed, and handed around like any other branch. The conflicted
paths are stored under .hangar, the merge state is cleared, and the hangar is
staged; then run 'git commit' to record the merge as an ordinary commit. The
branch the merge started on stays untouched. Park never commits.

    --branch <name>       the carrier branch to create; required on the first
                          park, refused on a re-park and when the name is
                          already a branch; a remote branch with the same name
                          draws a warning

Without a merge in progress, park re-parks unmerged paths onto the parked
merge at HEAD.

See also: git unpark takes held paths back out of the hangar; git land <dst>
lands the parked merge.
EOF
    ;;
  unpark)
    cat <<'EOF'
usage: git unpark [<path>...]

Take held paths back out of the hangar. A path unchanged since park, in
content, mode, and type, reopens as a conflict; a path you have changed in
content, mode, or type, or deleted, is your resolution, left unstaged for
review. Either way, the path is released from the hangar.

With no paths, every held path is taken. A directory takes every held path under
it. Paths resolve from your current directory, and a path naming nothing in the
hangar is an error. No globs, no pathspec magic.

See also: git land <dst> lands the parked merge once every path is released.
EOF
    ;;
  land)
    cat <<'EOF'
usage: git land [--amend] [--check] <dst>

Prepare the parked merge at HEAD for landing on <dst>. Each path still held in
the hangar is reported, and land refuses until every one is released. A merge
that already landed on <dst> is a no-op. Once every held path is released, land
switches to <dst>, stages the resolutions, and writes MERGE_HEAD; then run
'git commit' to finish the merge with both parents. Land never commits.

    <dst>                an existing local branch to merge into; never the
                         carrier branch (the one the parked merge is on)
    --amend              land over this carrier's earlier merge at <dst>'s
                         tip, replacing it
    --check              report merge readiness without changing anything:
                         which paths are still held, whether the merge already
                         landed, or that it is ready to land

Land reads local refs only. A landing behind upstream is allowed, like any git
commit, but will raise a warning. Update both branches from their upstreams
before checking or landing.
EOF
    ;;
  esac
}

help() {
  print_help
  exit 0
}

show_version() {
  printf 'git-carrier %s (hangar format %s)\n' "$CARRIER_VERSION" "${FORMAT_LINE#*: }"
  exit 0
}

die() {
  printf '%s: %s\n' "$APPLET" "$*" >&2
  exit 1
}

refuse() {
  printf '%s: %s\n' "$APPLET" "$*" >&2
  exit 2
}

# die and refuse, with a recovery hint on a line of its own.
die_recovery() {
  printf '%s: %s\n' "$APPLET" "$1" >&2
  printf '%s: recover: %s\n' "$APPLET" "$2" >&2
  exit 1
}

refuse_recovery() {
  printf '%s: %s\n' "$APPLET" "$1" >&2
  printf '%s: recover: %s\n' "$APPLET" "$2" >&2
  exit 2
}

warn() {
  printf '%s: warning: %s\n' "$APPLET" "$*" >&2
}

usage() {
  printf '%s: %s\n' "$APPLET" "$1" >&2
  printf 'usage: %s\n' "$USAGE" >&2
  exit 129
}

# ------------------------------------------------------------------- helpers

# Applets call this once their arguments are parsed: resolves the toplevel and creates the temp
# directory.
begin_applet() {
  top=$(git rev-parse --show-toplevel 2>/dev/null) ||
    die "not a git repository (or any parent directory)"
  git_floor_check
  td=$(mktemp -d) || die "mktemp -d failed"
  trap 'rm -rf "$td"' EXIT
}

# Require git at or above the minimum version.
git_floor_check() {
  local v major minor fmajor fminor
  v=$(git --version 2>/dev/null) || die "git --version failed"
  v=${v#git version }
  major=${v%%.*}
  minor=${v#*.}
  minor=${minor%%.*}
  case $major in '' | *[!0-9]*) die "cannot parse git version: $v" ;; esac
  case $minor in '' | *[!0-9]*) die "cannot parse git version: $v" ;; esac
  fmajor=${CARRIER_GIT_FLOOR%%.*}
  fminor=${CARRIER_GIT_FLOOR#*.}
  if [ "$major" -lt "$fmajor" ] || { [ "$major" -eq "$fmajor" ] && [ "$minor" -lt "$fminor" ]; }; then
    die "git $CARRIER_GIT_FLOOR or newer is required (found $major.$minor)"
  fi
}

# Absolute path of a git-dir file, via --git-path.
gitpath() {
  local p
  p=$(git -C "$top" rev-parse --git-path "$1") || die "rev-parse --git-path $1 failed"
  case $p in
  /*) printf '%s\n' "$p" ;;
  *) printf '%s/%s\n' "$top" "$p" ;;
  esac
}

peel() {
  git -C "$top" rev-parse -q --verify "$1^{commit}" 2>/dev/null
}

short() {
  git -C "$top" rev-parse --short "$1"
}

counted() {
  local n=$1 singular=$2 plural
  plural=${3:-${2}s}
  if [ "$n" -eq 1 ]; then
    printf '%d %s' "$n" "$singular"
  else
    printf '%d %s' "$n" "$plural"
  fi
}

# %q keeps spaces, control bytes, and non-ASCII unambiguous. Repo paths cannot contain NUL.
quote_path() {
  printf '%q' "$1"
}

# Comma-join quoted paths, capped at $1 items plus "... (N total)". Keeps a refusal to one line.
cap_list() {
  local limit=$1 shown='' total i=0 q
  shift
  total=$#
  while [ $# -gt 0 ] && [ "$i" -lt "$limit" ]; do
    if [ -n "$shown" ]; then shown="$shown, "; fi
    q=$(quote_path "$1")
    shown="$shown$q"
    shift
    i=$((i + 1))
  done
  if [ "$total" -gt "$limit" ]; then
    printf '%s, ... (%d total)' "$shown" "$total"
  else
    printf '%s' "$shown"
  fi
}

valid_id() {
  case $1 in
  '' | *[!0-9a-f]*) return 1 ;;
  esac
  case ${#1} in
  40 | 64) return 0 ;;
  *) return 1 ;;
  esac
}

# Refuse to move $1 when it is checked out in another worktree. git branch -f and git switch -C
# refuse this only on newer git (2.36 / 2.45), so check here: %(worktreepath) names the worktree
# the branch is checked out in, and is empty when it is checked out nowhere. The current
# toplevel is fine: that is us. Any other non-empty path is a collision.
refuse_dst_checked_out_elsewhere() {
  local wtpath
  wtpath=$(git -C "$top" for-each-ref --format='%(worktreepath)' "refs/heads/$1") ||
    die "for-each-ref failed for $1"
  [ -n "$wtpath" ] || return 0       # checked out nowhere
  [ "$wtpath" = "$top" ] && return 0 # the worktree I am standing in
  refuse_recovery \
    "$1 is checked out in another worktree ($wtpath)." \
    "finish there or remove that worktree (git worktree remove)"
}

# First line of <commit>:.hangar/manifest, the format line; fails when absent.
manifest_first_line() {
  local line
  git -C "$top" cat-file blob "$1:$HANGAR/manifest" >"$td/mfirst" 2>/dev/null || return 1
  line=
  IFS= read -r line <"$td/mfirst" || true
  printf '%s\n' "$line"
}

# Classify a manifest first line: 0 = ours (format 1), 1 = a newer major, 2 = not ours
hangar_line_status() {
  local major
  if [ "$1" = "$FORMAT_LINE" ]; then return 0; fi
  case $1 in
  'hangar-format: '*) ;;
  *) return 2 ;;
  esac
  major=${1#'hangar-format: '}
  case $major in
  '' | *[!0-9]*) return 2 ;; # not digits
  0*) return 2 ;;            # no leading zeros: a padded number or zero is not ours
  esac
  return 1
}

# Stop on a manifest first line that is not ours: a greater major refuses with the upgrade hint,
# anything else is not this tool's hangar and dies. $2 names where the hangar was read.
require_hangar_line() {
  local st=0
  hangar_line_status "$1" || st=$?
  [ "$st" = 0 ] && return 0
  if [ "$st" = 1 ]; then
    refuse "a newer hangar format is at $2 ($1): upgrade git-carrier and re-run"
  fi
  die "cannot verify the $HANGAR at $2: manifest does not begin with a hangar-format id"
}

# Same check for HEAD's .hangar. No-op when HEAD carries no manifest; the caller reports its own
# not-a-chain error.
head_hangar_version() {
  if ! git -C "$top" cat-file -e "HEAD:$HANGAR/manifest" 2>/dev/null; then return 0; fi
  require_hangar_line "$(manifest_first_line HEAD)" HEAD
}

# True when the tree's .hangar/manifest first line is the format line. Two tree lookups are the
# whole chain membership test.
tree_has_hangar() {
  [ "$(manifest_first_line "$1")" = "$FORMAT_LINE" ]
}

# After park stages the hangar and before the user's own `git commit`, the chain exists only in
# the index: HEAD's tree carries no hangar yet, and every chain lookup would misreport (park:
# "no stopped merge"; unpark and land: "not a parked merge"). refuse_park_window names both ways
# out instead.
#
# True when the index holds the hangar's manifest and HEAD does not. `:0:<path>` is the index's
# stage-0 entry, the same cat-file spelling tree_has_hangar reads.
park_staged_uncommitted() {
  if git -C "$top" cat-file -e "HEAD:$HANGAR/manifest" 2>/dev/null; then return 1; fi
  tree_has_hangar ':0'
}

# Refuse after park and before its commit, naming both ways out: finish the park or unwind it.
refuse_park_window() {
  printf '%s: %s\n' "$APPLET" "the hangar is staged but not committed; park never commits." >&2
  printf '%s: recover: %s\n' "$APPLET" "continue with 'git commit' (--no-verify if a hook rejects conflict markers)" >&2
  printf '%s: or unwind: %s\n' "$APPLET" "'git reset --merge && rm -rf $HANGAR', then 'git switch <branch> && git branch -D <carrier>'" >&2
  exit 2
}

# The worktree .hangar manifest's first line, empty when unreadable.
worktree_manifest_line() {
  local f line
  f="$top/$HANGAR/manifest"
  line=
  if [ -f "$f" ]; then
    IFS= read -r line <"$f" || true
  fi
  printf '%s\n' "$line"
}

mangled_manifest() {
  refuse_recovery \
    "the manifest at $1 is mangled: $2." \
    "fix it by hand using git-carrier's docs/hangar-format.txt, then re-run"
}

incomplete_manifest() {
  refuse_recovery \
    "the hangar at $1 is incomplete: $2." \
    "fix the manifest by hand using git-carrier's docs/hangar-format.txt, then re-run"
}

# Parse <commit>:$HANGAR/manifest, setting MSRC and MSRCDESC, the fields of format 1, and verify the
# first line, so no caller reads a field before classifying it. <label> names where the hangar
# was read, for refusal messages. MSRC/MSRCDESC reach the caller through dynamic scoping; declare
# them local or let them drop.
read_manifest() {
  local c=$1 label=$2 line name value n=0 chunks=0 chunk seen_src=0 seen_desc=0
  MSRC=
  MSRCDESC=
  git -C "$top" cat-file blob "$c:$HANGAR/manifest" >"$td/manifest" 2>/dev/null ||
    incomplete_manifest "$label" "it has no manifest"
  # A NUL byte cannot pass through a bash variable, so count chunks instead: read splits the file on
  # NULs, and a manifest with none reads as exactly one chunk.
  while IFS= read -r -d '' chunk || [ -n "$chunk" ]; do
    chunks=$((chunks + 1))
  done <"$td/manifest"
  [ "$chunks" -le 1 ] || mangled_manifest "$label" "it holds a NUL byte"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$n" = 1 ]; then
      require_hangar_line "$line" "$label"
      continue
    fi
    # One pattern covers the whole field shape, so any malformed line hits the same refusal.
    case $line in
    [a-z0-9][a-z0-9-]*:*) ;;
    *)
      mangled_manifest "$label" "line $n is not a field"
      ;;
    esac
    name=${line%%:*}
    value=${line#*:}
    case $value in
    ' '*) value=${value# } ;;
    esac
    case $name in
    hangar-format)
      mangled_manifest "$label" "line $n names hangar-format, reserved for the format line"
      ;;
    source)
      [ "$seen_src" = 0 ] || mangled_manifest "$label" "source appears twice"
      seen_src=1
      valid_id "$value" ||
        mangled_manifest "$label" "source's value is not an object id"
      MSRC=$value
      ;;
    source-desc)
      [ "$seen_desc" = 0 ] || mangled_manifest "$label" "source-desc appears twice"
      seen_desc=1
      case $value in
      '' | ' '* | *$'\r'*)
        mangled_manifest "$label" "source-desc's value is empty, begins with a space, or holds a CR"
        ;;
      esac
      MSRCDESC=$value
      ;;
    esac
  done <"$td/manifest"
  [ "$seen_src" = 1 ] || incomplete_manifest "$label" "the manifest has no source"
  [ "$seen_desc" = 1 ] || incomplete_manifest "$label" "the manifest has no source-desc"
}

# Accept at HEAD only what park itself writes: a manifest that parses, a message present
# or absent (a re-park trusts the checked-out copy), stages absent or a directory.
require_hangar_shape() {
  local t MSRC MSRCDESC
  read_manifest "$1" "$2"
  t=$(git -C "$top" cat-file -t "$1:$HANGAR/stages" 2>/dev/null) || return 0
  [ "$t" = tree ] ||
    refuse_recovery \
      "mangled hangar at $2: $HANGAR/stages is a $t, not a directory." \
      "fix the hangar by hand using git-carrier's docs/hangar-format.txt, then re-run"
}

# The worktree .hangar must be the hangar's own before park or unpark touches it; the manifest's
# first line is the identity check.
worktree_hangar_magic() {
  if [ -L "$top/$HANGAR" ] || [ ! -d "$top/$HANGAR" ]; then return 1; fi
  [ "$(worktree_manifest_line)" = "$FORMAT_LINE" ]
}

# True while a sparse checkout is active (core.sparseCheckout): out-of-pattern paths are hidden
# from the worktree, and plain `git checkout -- <path>` restores only paths the patterns keep.
sparse_checkout_on() {
  [ "$(git -C "$top" config --bool core.sparseCheckout)" = true ]
}

# The worktree .hangar must be ours before park or unpark touches it; the manifest's first line
# is the identity check. A readable line that is not ours ends the run in require_hangar_line.
# A file or symlink in the hangar's place, or a manifest that is absent, unreadable, or empty,
# is refused below; the recovery is a restore from the index, so a staged release survives it.
# Under a sparse checkout the recovery names `git sparse-checkout add $HANGAR` too: plain
# checkout restores only in-pattern paths.
require_worktree_hangar() {
  local wl
  if worktree_hangar_magic; then return 0; fi
  # A file or a symlink in the hangar's place cannot be restored onto (checkout dies on the
  # file and writes through the link), so the recovery moves it away first. An absent path
  # falls to the refusal below.
  if [ -L "$top/$HANGAR" ] || { [ -e "$top/$HANGAR" ] && [ ! -d "$top/$HANGAR" ]; }; then
    refuse "the working tree's $HANGAR is not a directory: move it away and restore it (git checkout -- $HANGAR), then re-run"
  fi
  wl=$(worktree_manifest_line)
  if [ -n "$wl" ]; then require_hangar_line "$wl" "the working tree"; fi
  if sparse_checkout_on; then
    refuse "the working tree's $HANGAR is missing or unreadable: restore it (git sparse-checkout add $HANGAR && git checkout -- $HANGAR), then re-run"
  fi
  refuse "the working tree's $HANGAR is missing or unreadable: restore it (git checkout -- $HANGAR), then re-run"
}

# The first symlink (or non-directory) on the worktree path of $HANGAR/stages/$1, into
# STAGES_LINK as a worktree-relative path, empty when the path is safe to write or remove:
# park writes the hangar and unpark's release removes it by that worktree path, and a link
# anywhere on it would carry the write or the removal outside the repository.
stages_link_component() {
  local p=$1 d rest comp
  STAGES_LINK=
  d="$top/$HANGAR/stages"
  rest=$p
  while :; do
    if [ -e "$d" ] || [ -L "$d" ]; then
      if [ -L "$d" ] || [ ! -d "$d" ]; then
        STAGES_LINK=${d#"$top"/}
        return 0
      fi
    else
      # an absent component is safe, and nothing can exist below it
      return 0
    fi
    [ -n "$rest" ] || return 0
    comp=${rest%%/*}
    d="$d/$comp"
    case $rest in
    */*) rest=${rest#*/} ;;
    *) rest= ;;
    esac
  done
}

# Refuse when a symlink (or a non-directory) stands on the worktree path of any of the
# NUL-delimited paths in $1.
refuse_stages_links() {
  local p j seen STAGES_LINK bad nbad
  bad=()
  nbad=0
  while IFS= read -r -d '' p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    stages_link_component "$p"
    [ -n "$STAGES_LINK" ] || continue
    seen=0
    for ((j = 0; j < nbad; j++)); do
      if [ "${bad[$j]}" = "$STAGES_LINK" ]; then
        seen=1
        break
      fi
    done
    [ "$seen" = 1 ] && continue
    bad[nbad]=$STAGES_LINK
    nbad=$((nbad + 1))
  done <"$1"
  [ "$nbad" -gt 0 ] || return 0
  refuse_recovery \
    "a symlink or a non-directory stands where the hangar holds a stage directory: $(cap_list 10 "${bad[@]}")" \
    "move it away and restore it (git checkout -- $HANGAR/stages), then re-run"
}

# Refuse while a rebase, cherry-pick, revert, or am is unfinished.
in_progress_check() {
  local state p op
  for state in REBASE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    p=$(gitpath "$state")
    if [ -e "$p" ]; then
      case $state in
      REBASE_HEAD) op=rebase ;;
      CHERRY_PICK_HEAD) op=cherry-pick ;;
      REVERT_HEAD) op=revert ;;
      esac
      refuse "cannot proceed while git $op is in progress ($state); finish or abort it, then re-run"
    fi
  done
  p=$(gitpath rebase-merge)
  if [ -d "$p" ]; then
    refuse "cannot proceed while git rebase is in progress; finish or abort it, then re-run"
  fi
  p=$(gitpath rebase-apply)
  if [ -d "$p" ]; then
    if [ -e "$p/rebasing" ]; then
      refuse "cannot proceed while git rebase is in progress; finish or abort it, then re-run"
    fi
    refuse "cannot proceed while git am is in progress; finish or abort it, then re-run"
  fi
}

# Read NUL-delimited `<mode> <sha> <stage>\t<path>` records into the I* arrays, and the unique
# paths (in index order) into PPATHS. ls-files -s and --unmerged share the record shape, and a
# path's entries are adjacent in its output, so one pass suffices.
read_stage_records() {
  local rec prev path meta rest
  IPATHS=()
  IMODES=()
  ISHAS=()
  ISTAGES=()
  PPATHS=()
  NREC=0
  NUNIQ=0
  prev=
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    path=${rec#*$'\t'}
    meta=${rec%%$'\t'*}
    IPATHS[NREC]="$path"
    IMODES[NREC]=${meta%% *}
    rest=${meta#* }
    ISHAS[NREC]=${rest%% *}
    ISTAGES[NREC]=${rest##* }
    NREC=$((NREC + 1))
    if [ "$path" != "$prev" ]; then
      PPATHS[NUNIQ]="$path"
      NUNIQ=$((NUNIQ + 1))
      prev=$path
    fi
  done <"$1"
}

# Unmerged entries of the current index, into the I* arrays.
dump_unmerged() {
  git -C "$top" ls-files --unmerged -z >"$td/unmerged" || die "ls-files --unmerged failed"
  read_stage_records "$td/unmerged"
}

# The stage-0 entry of every dumped path after the add, into S0MODES/S0SHAS at the path's own
# PPATHS position. A plain-rm'd conflict stages as a deletion, so a path may have no entry,
# and its file w is then legitimately absent.
#
# argv cannot hold every spec at once, so ls-files runs once per contiguous run of PPATHS, and
# each chunk's records join against exactly that run, both in sort order. A concatenation of
# the chunks would not do: it is sorted only per chunk. A pathspec sweeps in the paths under
# it, so the spec for 'a' prints 'a/zz' as well; concatenated, that record comes ahead of
# 'a-b's own record ('-' sorts below '/'), and a join over the concatenation, expecting
# sorted records, concludes 'a-b' has no record and moves on: 'a-b' silently takes no w.
dump_postadd() {
  local bytes m n i rec meta rest stg path chunk
  # Each spec's bytes: its path, plus ':(literal)' and the NUL that ends the argv string. The
  # cap of 1024 keeps one invocation's argv well under the POSIX floor of 4096, command
  # included; a spec too long to fit gets a chunk of its own.
  local overhead=11 budget=1024
  S0MODES=()
  S0SHAS=()
  for ((i = 0; i < NUNIQ; i++)); do
    S0MODES[i]=
    S0SHAS[i]=
  done
  [ "$NUNIQ" -gt 0 ] || return 0
  m=0
  while [ "$m" -lt "$NUNIQ" ]; do
    chunk=()
    bytes=0
    n=$m
    while [ "$n" -lt "$NUNIQ" ] &&
      { [ "$bytes" -eq 0 ] || [ "$((bytes + ${#PPATHS[n]} + overhead))" -le "$budget" ]; }; do
      chunk[n - m]=":(literal)${PPATHS[n]}"
      bytes=$((bytes + ${#PPATHS[n]} + overhead))
      n=$((n + 1))
    done
    git -C "$top" ls-files -s -z -- ${chunk[@]+"${chunk[@]}"} >"$td/chunkrecs" ||
      die "ls-files -s failed after the add"
    i=$m
    while IFS= read -r -d '' rec || [ -n "$rec" ]; do
      [ -n "$rec" ] || continue
      meta=${rec%%$'\t'*}
      rest=${meta#* }
      stg=${rest##* }
      [ "$stg" = 0 ] || continue
      path=${rec#*$'\t'}
      # a record is one of this chunk's specs or sits under one, so it sorts at or above
      # the run's first path
      while [ "$i" -lt "$n" ] && [ "${PPATHS[$i]}" \< "$path" ]; do
        i=$((i + 1))
      done
      # a record past the run sorts above the run's last path, and so does the rest of
      # this output; a swept nested path is read by its own chunk
      [ "$i" -lt "$n" ] || break
      if [ "${PPATHS[$i]}" = "$path" ]; then
        S0MODES[i]=${meta%% *}
        S0SHAS[i]=${rest%% *}
        i=$((i + 1))
      fi
    done <"$td/chunkrecs"
    m=$n
  done
}

# Parse `ls-tree -r` of <commit>:.hangar/stages into the SPAR/SSTAGE/SMODE/SSHA arrays (nstage
# records) in ls-tree order; the caller declares the whole set local, and walk_stage_blocks
# consumes it. With $2 = strict, a malformed record is refused on sight: unpark feeds these
# records back into the index, so a mangled hangar is refused before the walk classifies
# anything. Land reads leniently.
dump_stage_tree() {
  local c=$1 strict=${2:-} rec r sfile p mode q
  git -C "$top" ls-tree -r -z "$c" -- "$HANGAR/stages" >"$td/stagetree" ||
    die "ls-tree of $c failed"
  SPAR=()
  SSTAGE=()
  SMODE=()
  SSHA=()
  nstage=0
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    # record: <mode> <type> <sha>\t<hangar/stages/<path>/<1-3 or w>>
    r=${rec#*$'\t'}
    r=${r#"$HANGAR/stages/"}
    sfile=${r##*/}
    p=${r%/*}
    if [ "$strict" = strict ]; then
      if [ "$p" = "$r" ]; then
        q=$(quote_path "$HANGAR/stages/$sfile")
        refuse_recovery \
          "mangled hangar: $q is a file, not a path directory." \
          "fix the hangar by hand using git-carrier's docs/hangar-format.txt, then re-run"
      fi
      case $sfile in
      w | 1 | 2 | 3) ;;
      *)
        q=$(quote_path "$HANGAR/stages/$p/$sfile")
        refuse_recovery \
          "mangled hangar: $q is not a stage file (1-3) or w." \
          "fix the hangar by hand using git-carrier's docs/hangar-format.txt, then re-run"
        ;;
      esac
    fi
    SPAR[nstage]=$p
    SSTAGE[nstage]=$sfile
    mode=${rec%%$'\t'*}
    SMODE[nstage]=${mode%% *}
    mode=${mode#* }
    SSHA[nstage]=${mode##* }
    nstage=$((nstage + 1))
  done <"$td/stagetree"
}

# Walk the parsed hangar records as per-path blocks. Sets PARKED (every path once, in
# first-appearance order), nparked, the per-path aggregates PHAVE123[i], PWSHA[i], and
# PWMODE[i] (file w's blob and mode), and a block list chained per path. A block is one run
# of adjacent records of one path, spanning
# SPAR[BLOCKSTART[b]] .. SPAR[BLOCKEND[b]]; BLOCKHEAD[i] is path i's first block and
# BLOCKNEXT[b] the next block of its path, so a path's records read in record order by
# starting at BLOCKHEAD[i] and following BLOCKNEXT.
#
# ls-tree -r orders records by the whole path string, so one path's records stay adjacent only
# while no other held path nests under it: 'b' sorts between '3' and 'w', so a nested
# .hangar/stages/a/b/3 sorts between a's 3 and its w and splits a's records. An ancestor stack
# tracks the still-held paths (ls-tree -r is depth-first, so they are exactly the ancestors of
# the record at hand): a path is pushed as the walk descends into a nested path's stages and
# popped once the walk leaves it, so the stack never holds more than the nesting chain.
#
# The record order is git's own contract (fsck.c enforces it; git refuses an unordered tree),
# so the records need no regrouping. Every name here is the caller's through dynamic scoping;
# both callers declare them local.
walk_stage_blocks() {
  local r p t prev previ
  PARKED=()
  PHAVE123=()
  PWSHA=()
  PWMODE=()
  nparked=0
  BLOCKHEAD=()
  BLOCKNEXT=()
  BLOCKTAIL=()
  BLOCKSTART=()
  BLOCKEND=()
  nb=0
  PSTACK=()
  nsp=0
  prev=
  for ((r = 0; r < nstage; r++)); do
    p=${SPAR[$r]}
    if [ "$p" != "$prev" ]; then
      if [ -n "$prev" ]; then
        BLOCKEND[nb - 1]=$((r - 1))
        # descending into a nested path: prev stays held, its later stage files sort after this
        case $p in
        "$prev"/*)
          PSTACK[nsp]=$previ
          nsp=$((nsp + 1))
          ;;
        esac
      fi
      while [ "$nsp" -gt 0 ]; do
        t=${PARKED[PSTACK[nsp - 1]]}
        if [ "$t" = "$p" ]; then break; fi
        case $p in
        "$t"/*) break ;; # t is an ancestor of p: the walk is still inside it
        esac
        nsp=$((nsp - 1))
      done
      if [ "$nsp" -gt 0 ] && [ "${PARKED[PSTACK[nsp - 1]]}" = "$p" ]; then
        nsp=$((nsp - 1))
        previ=${PSTACK[$nsp]}
      else
        PARKED[nparked]=$p
        PHAVE123[nparked]=0
        PWSHA[nparked]=
        PWMODE[nparked]=
        BLOCKHEAD[nparked]=-1
        BLOCKTAIL[nparked]=-1
        previ=$nparked
        nparked=$((nparked + 1))
      fi
      BLOCKSTART[nb]=$r
      BLOCKNEXT[nb]=-1
      if [ "${BLOCKHEAD[previ]}" -lt 0 ]; then
        BLOCKHEAD[previ]=$nb
      else
        BLOCKNEXT[BLOCKTAIL[previ]]=$nb
      fi
      BLOCKTAIL[previ]=$nb
      nb=$((nb + 1))
      prev=$p
    fi
    if [ "${SSTAGE[$r]}" = w ]; then
      PWSHA[previ]=${SSHA[$r]}
      PWMODE[previ]=${SMODE[$r]}
    else
      PHAVE123[previ]=1
    fi
  done
  if [ -n "$prev" ]; then
    BLOCKEND[nb - 1]=$((nstage - 1))
  fi
}

# Write one stage file so `git add -f` records the entry's mode: blobs via cat-file, 100755
# with chmod, 120000 as a symlink of the blob content, so exec-bit and symlink conflicts
# round-trip. The -d and -e tests handle the directory and any stale file in place of an
# unconditional mkdir -p and rm -rf; park calls this once per stage file.
write_stage_file() {
  local mode sha path q target
  mode=$1
  sha=$2
  path=$3
  q=$(quote_path "$path")
  [ -d "${path%/*}" ] || mkdir -p -- "${path%/*}"
  # -L catches a broken symlink too: redirecting onto one would write through it
  { [ ! -e "$path" ] && [ ! -L "$path" ]; } || rm -rf -- "$path"
  case $mode in
  100644)
    git -C "$top" cat-file blob "$sha" >"$path" || die "cat-file blob $sha failed"
    ;;
  100755)
    git -C "$top" cat-file blob "$sha" >"$path" || die "cat-file blob $sha failed"
    chmod 755 -- "$path"
    ;;
  120000)
    # Command substitution strips trailing newlines, so append a sentinel byte and strip it
    # with ${target%x}: a target ending in LF would park corrupted.
    target=$(git -C "$top" cat-file blob "$sha" && printf x) || die "cat-file blob $sha failed"
    ln -s -- "${target%x}" "$path" || die "ln -s failed for $q"
    ;;
  *)
    die "cannot park stage mode $mode at $q (only blobs and symlinks park)"
    ;;
  esac
}

# The README prose, written by park alone.
write_hangar_readme() {
  cat >"$top/$HANGAR/README" <<'HANGAR_README_EOF'
This directory is a hangar: the storage of a merge that stopped at conflicts,
carried by every commit on this branch until the merge resolves.
It never lands: the merge commit without conflicts omits this directory.
Generated by git-carrier: https://github.com/git-carrier/git-carrier
HANGAR_README_EOF
}

# Derive FETCH_HEAD description of $1, the merge's verbatim source id. Park derives it once,
# from the refs of the merge that actually happened, and freezes it in the hangar.
# The label is interpolated into a message, never resolved.
#
# First match wins:
#   1. tag whose object id is exactly $1.
#   2. a tag on the commit (if several match, use refname order).
#   3. a remote-tracking branch at the commit.
# No tier matches a local-branch merge ("Merge commit '<sha>'") and draw a warning.
# If the displayed label differs from the merge's real spelling, the original subject is
# written to .hangar/message's comment block at landing time.
# Sets SRC_DESC.
derive_src_desc() {
  local vid sc rec ref oid peeled tagexact tagpeel
  vid=$1
  sc=$(peel "$vid") ||
    die "the merge's source $(short "$vid") is not present as a commit here"
  SRC_DESC="commit '$vid'"
  git -C "$top" for-each-ref --format='%(refname) %(objectname) %(*objectname)' refs/tags >"$td/tags" ||
    die "for-each-ref failed over the tags"
  tagexact=
  tagpeel=
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    ref=${rec%% *}
    oid=${rec#* }
    oid=${oid%% *}
    peeled=${rec##* }
    if [ "$oid" = "$vid" ]; then
      tagexact=${ref#refs/tags/}
      break
    fi
    if [ -z "$tagpeel" ] && { [ "$oid" = "$sc" ] || [ "$peeled" = "$sc" ]; }; then
      tagpeel=${ref#refs/tags/}
    fi
  done <"$td/tags"
  if [ -n "$tagexact" ]; then
    SRC_DESC="tag '$tagexact'"
    return
  fi
  if [ -n "$tagpeel" ]; then
    SRC_DESC="tag '$tagpeel'"
    return
  fi
  git -C "$top" for-each-ref --format='%(refname) %(objectname)' refs/remotes >"$td/remotes" ||
    die "for-each-ref failed over the remote-tracking refs"
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    ref=${rec%% *}
    oid=${rec#* }
    if [ "$oid" = "$sc" ]; then
      SRC_DESC="remote-tracking branch '${ref#refs/remotes/}'"
      return
    fi
  done <"$td/remotes"
  # No tier matched: the source has no name here that a landing in another clone can fetch by.
  # The label above is still right for the landing message, so park continues.
  warn "the merge's source $(short "$vid") has no tag or remote-tracking branch here; a landing in another clone will need it fetched by name"
}

# ====================================================================== park
#
# git park [--branch <carrier-branch>]: park the merge stopped at conflicts onto the carrier branch
# you name, into .hangar.
#
# Subject : a merge stopped by conflict (MERGE_HEAD present, one head), or a re-park (unmerged
#           entries, no MERGE_HEAD, HEAD a parked chain tip). A parked tip with nothing unmerged
#           is a no-op. A stopped merge with nothing unmerged (a hook rejected the auto-commit)
#           parks an empty chain like any other.
# Branch  : --branch names the carrier once, on the first park; required there, refused on a
#           re-park and on the no-op. The name must be valid and must not exist as a branch
#           here; a remote-tracking branch by the same name draws a warning, never a refusal.
#           Park creates the carrier mid-merge through plumbing
#           (git branch + git symbolic-ref HEAD): `git switch -c` refuses mid-merge, and
#           `git checkout -b` silently clears MERGE_HEAD, so the merge would stop being
#           abortable. The plumbing keeps the merge state and the unmerged index intact, moves
#           nothing but HEAD, and works from a detached HEAD too. Every hangar write happens on
#           the carrier, so a half-failed park leaves the merge standing on the carrier, mid-merge
#           and abortable; the branch the merge started on stays untouched.
# Refuses : an unfinished rebase/cherry-pick/revert/am; octopus merges (one source id is all the
#           hangar holds); a .hangar of the user's in the worktree (a re-park accepts only the
#           hangar's own, checked by format line and shape); gitlink conflicts (a stage file is
#           blob content, a submodule pointer is not); a symlink or a non-directory standing
#           on a stages path (a write or a removal never traverses a link); a staged,
#           uncommitted park; nothing to park (no stopped merge, no parked chain). A manifest
#           first line that is not ours dies: the hangar is not this tool's. Every refusal
#           runs before the branch creation, park's first mutation.
# Effect  : dump the unmerged entries before any add; stage the conflicted paths' worktree
#           content, scoped to those paths only, so untracked, ignored, and unrelated changes
#           never enter the chain (git add a path beforehand to include it deliberately);
#           write file w from the index after the add (absent means no w file); record the
#           merge message (stripspace --strip-comments) as advisory context; write the manifest
#           (format line; source: the MERGE_HEAD id verbatim, a tag id stays a tag id; source-desc:
#           derived once by derive_src_desc, an id-only desc drawing the park warning); clear
#           MERGE_HEAD/MERGE_MSG/MERGE_MODE/MERGE_RR via --git-path; stage the hangar with
#           `git add -f`. A re-park trusts the checked-out manifest and message verbatim, unknown
#           fields preserved, and unions its stage files into the existing stages/; released
#           paths stay released, and stages/ is never rm -rf'd. Park never commits: the user's
#           own `git commit` creates the parked commit, one parent, squashable. The report names
#           the branch the merge started on and the exact `git land <dst>` to run later.

park_main() {
  local name endopts dstname
  local cur heads mode i ngl last glpaths msgf src wl rtref
  name=
  endopts=0
  while [ $# -gt 0 ]; do
    if [ "$endopts" = 0 ]; then
      case $1 in
      --help) help ;;
      -h)
        print_help >&2
        exit 129
        ;;
      --version) show_version ;;
      --)
        endopts=1
        shift
        continue
        ;;
      -b | --branch)
        if [ $# -lt 2 ]; then usage "$1 needs a name"; fi
        name=$2
        shift 2
        continue
        ;;
      --branch=*)
        name=${1#--branch=}
        shift
        continue
        ;;
      -*) usage "unknown flag: $1" ;;
      *) usage "git park takes no arguments (got: $1)" ;;
      esac
    fi
    usage "git park takes no arguments (got: $1)"
  done

  begin_applet

  # Unfinished rebase/cherry-pick/revert/am first: a rebase stop is always detached, and its own
  # recovery is the one that matters. A detached HEAD is fine here; the plumbing below works
  # mid-merge and detached alike.
  in_progress_check
  cur=$(git -C "$top" symbolic-ref -q --short HEAD || true)

  mode=fresh
  if [ ! -f "$(gitpath MERGE_HEAD)" ]; then
    # No live merge: a re-park is unmerged entries over a parked chain tip, the merge state
    # already cleared; nothing unmerged is the no-op. The chain test comes first, so a damaged
    # chain gets the shape refusal instead of "no stopped merge".
    dump_unmerged
    if tree_has_hangar HEAD; then
      if [ -n "$name" ]; then
        refuse "the merge work already lives on ${cur:-a detached HEAD}: --branch names the carrier once, on the first park; re-run without it"
      fi
      if [ "$NREC" -eq 0 ]; then
        echo "$APPLET: already parked at $(short HEAD): nothing to do"
        exit 0
      fi
      require_hangar_shape HEAD HEAD
      mode=repark
    else
      head_hangar_version
      if park_staged_uncommitted; then refuse_park_window; fi
      refuse_recovery \
        "no stopped merge here (no MERGE_HEAD; HEAD is not a parked merge)." \
        "start a merge (git merge <source>), or fetch and switch to the carrier branch, then re-run"
    fi
  else
    heads=$(grep -c . "$(gitpath MERGE_HEAD)" || true)
    if [ "$heads" -gt 1 ]; then
      refuse_recovery \
        "cannot proceed while an octopus merge is in progress (MERGE_HEAD lists $heads heads): park holds one source." \
        "finish or abort it, then re-run"
    fi
    dump_unmerged
  fi

  if [ "$mode" = repark ]; then
    require_worktree_hangar
  elif [ -e "$top/$HANGAR" ] || [ -L "$top/$HANGAR" ]; then
    if tree_has_hangar HEAD; then
      refuse "a parked merge is checked out here: land it first (git land <dst>) or switch away before parking another merge"
    fi
    # A previous park's hangar, staged and never committed: park wrote this one, so the generic
    # refusal below would be wrong.
    if park_staged_uncommitted; then refuse_park_window; fi
    wl=$(worktree_manifest_line)
    if [ -n "$wl" ]; then require_hangar_line "$wl" "the working tree"; fi
    refuse "a $HANGAR already exists in this worktree: park refuses to touch what it did not write; move it away and re-run"
  fi

  # gitlink conflicts: a stage file is blob content, a submodule pointer is not. A path's records
  # are adjacent in the dump, so one `last` lists each path once.
  glpaths=()
  ngl=0
  last=
  for ((i = 0; i < NREC; i++)); do
    [ "${IMODES[$i]}" = 160000 ] || continue
    [ "${IPATHS[$i]}" != "$last" ] || continue
    last=${IPATHS[$i]}
    glpaths[ngl]=$last
    ngl=$((ngl + 1))
  done
  if [ "$ngl" -gt 0 ]; then
    refuse_recovery \
      "gitlink (submodule) conflicts at: $(cap_list 10 "${glpaths[@]}"); a stage file cannot carry a commit id." \
      "resolve the submodule pointers in the live merge, then re-run park"
  fi

  # park writes the hangar by the worktree path .hangar/stages/<path>, and a link anywhere
  # on it would carry the writes outside. In fresh mode no .hangar exists (every existing
  # one was refused above), so the walk finds nothing.
  : >"$td/linkpaths"
  if [ "$NUNIQ" -gt 0 ]; then
    printf '%s\0' "${PPATHS[@]}" >>"$td/linkpaths"
  fi
  refuse_stages_links "$td/linkpaths"

  # --- the carrier branch: created here ---

  # Every refusal above runs before this first mutation, and every hangar write happens on the
  # carrier, so a failed park leaves the merge abortable where it was.
  if [ "$mode" = fresh ]; then
    if [ -z "$name" ]; then
      usage "the first park names the carrier branch (the merge is stopped mid-flight; name where the merge work will live): git park --branch <name>"
    fi
    git -C "$top" check-ref-format --branch "$name" >/dev/null 2>&1 ||
      die "the carrier branch name '$name' is not a valid branch name"
    if git -C "$top" show-ref --verify --quiet "refs/heads/$name"; then
      # One refusal whatever the taken name holds: the checks read refnames only, never the
      # objects behind them, so a taken branch's content never steers the advice; any new
      # name parks the same work.
      refuse "a branch named '$name' already exists; choose another carrier name"
    fi
    # Warn if a remote already tracks a branch of this name (local and remote-tracking refs
    # coexist fine, so this is no reason to refuse).
    rtref=$(git -C "$top" for-each-ref --format='%(refname)' "refs/remotes/*/$name") ||
      die "for-each-ref failed over the remote-tracking refs"
    if [ -n "$rtref" ]; then
      rtref=${rtref%%$'\n'*}
      rtref=${rtref#refs/remotes/}
      warn "$name already exists as the remote-tracking branch $rtref"
    fi
    git -C "$top" branch "$name" || die "git branch $name failed"
    git -C "$top" symbolic-ref HEAD "refs/heads/$name" ||
      die "git symbolic-ref HEAD refs/heads/$name failed"
    dstname=$cur
  fi

  # --- the park itself: the index and worktree change from here ---

  # Stage the conflicted paths' worktree content, scoped to the dumped paths: a bare `git add -u`
  # would sweep unrelated unstaged changes into the chain. To include a path deliberately, git
  # add it before git park. The literal pathspecs pass through one NUL-delimited file into
  # --pathspec-from-file (add took that flag in 2.25, under the floor).
  if [ "$NUNIQ" -gt 0 ]; then
    printf ':(literal)%s\0' "${PPATHS[@]}" >"$td/addspecs"
    git -C "$top" add -u --pathspec-from-file="$td/addspecs" --pathspec-file-nul ||
      die "git add -u failed"
  fi

  if [ "$mode" = fresh ]; then
    src=$(cat "$(gitpath MERGE_HEAD)")
    valid_id "$src" || die "MERGE_HEAD does not hold a single object id"
    derive_src_desc "$src"
    msgf=$(gitpath MERGE_MSG)
    if [ -f "$msgf" ]; then
      git -C "$top" stripspace --strip-comments <"$msgf" >"$td/msg" ||
        die "git stripspace failed on MERGE_MSG"
    else
      : >"$td/msg"
    fi
  fi

  mkdir -p "$top/$HANGAR/stages"
  # Every path's stages directory up front, over one NUL-delimited list through xargs -0.
  # write_stage_file's own mkdir is then a -d test per stage file instead of a fork per stage file.
  if [ "$NUNIQ" -gt 0 ]; then
    : >"$td/stagedirs"
    for ((i = 0; i < NUNIQ; i++)); do
      printf '%s\0' "$top/$HANGAR/stages/${PPATHS[$i]}" >>"$td/stagedirs"
    done
    xargs -0 mkdir -p -- <"$td/stagedirs" || die "mkdir of the stages directories failed"
  fi
  printf '%s\n' "$ATTRS_LINE" >"$top/$HANGAR/.gitattributes"
  if [ "$mode" = fresh ]; then
    printf '%s\nsource: %s\nsource-desc: %s\n' "$FORMAT_LINE" "$src" "$SRC_DESC" >"$top/$HANGAR/manifest"
    if [ -s "$td/msg" ]; then
      cp "$td/msg" "$top/$HANGAR/message"
    fi
    write_hangar_readme
  fi

  # Stage files 1/2/3 from the unmerged entries read before the add; union, never rm -rf stages/.
  for ((i = 0; i < NREC; i++)); do
    write_stage_file "${IMODES[$i]}" "${ISHAS[$i]}" "$top/$HANGAR/stages/${IPATHS[$i]}/${ISTAGES[$i]}"
  done

  # File w: the stage-0 blob after the add (absent means no w file), at the path's own PPATHS
  # position; dump_postadd resolves every path in place, so the loop depends on no list's order.
  dump_postadd
  for ((i = 0; i < NUNIQ; i++)); do
    if [ -n "${S0SHAS[$i]}" ]; then
      write_stage_file "${S0MODES[$i]}" "${S0SHAS[$i]}" "$top/$HANGAR/stages/${PPATHS[$i]}/w"
    fi
  done

  git -C "$top" add -f --sparse -- "$HANGAR" || die "git add -f $HANGAR failed"

  # Clear the merge state last: it is the point of no return, and every fallible step above runs
  # while the merge is still recoverable with git merge --abort.
  rm -f "$(gitpath MERGE_HEAD)" "$(gitpath MERGE_MSG)" "$(gitpath MERGE_MODE)" "$(gitpath MERGE_RR)"

  if [ "$mode" = repark ] && git -C "$top" diff --cached --quiet --no-ext-diff --; then
    echo "$APPLET: $(counted "$NUNIQ" path) re-parked; the restored state matches HEAD: no commit needed"
    exit 0
  fi

  if [ "$mode" = fresh ]; then
    echo "$APPLET: $(counted "$NUNIQ" path) parked into $HANGAR on $name; the hangar is staged"
    # Report the branch the merge started on while it is known, including the exact
    # landing command.
    if [ -n "$dstname" ]; then
      echo "$APPLET: $dstname stays at $(short "$dstname"); land there later with: git land $dstname"
    else
      echo "$APPLET: the merge started from a detached HEAD; land it later with: git land <dst> (an existing branch)"
    fi
  else
    echo "$APPLET: $(counted "$NUNIQ" path) re-parked into $HANGAR; the hangar is staged"
  fi
  echo "$APPLET: run 'git commit' to create the parked commit (--no-verify if a pre-commit hook rejects the conflict-marker content)"
}

# The index entry's mode at exactly <path>, into IDX_ENTRY_MODE, empty when the index holds
# no entry there: the spec of a directory sweeps the paths under it, so the record's path is
# matched exactly. A gitlink (160000) reaches the caller like any other mode; ce_mode_from_stat
# keeps no mode of it.
index_entry_mode() {
  local p=$1 rec m
  IDX_ENTRY_MODE=
  git -C "$top" ls-files -s -z -- ":(literal)$p" >"$td/idxmode" ||
    die "ls-files failed reading the index entry of $(quote_path "$p")"
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    [ "${rec#*$'\t'}" = "$p" ] || continue
    m=${rec%%$'\t'*}
    IDX_ENTRY_MODE=${m%% *}
    break
  done <"$td/idxmode"
}

# The mode git's own add records for the regular worktree file at <path>, into
# RECORDED_MODE, ce_mode_from_stat's rules: core.symlinks false keeps a symlink index entry's
# mode (a link checks out as a regular file holding the target), core.fileMode false keeps a
# regular entry's mode and cannot read the exec bit at all (any other entry, or none, records
# 100644), and otherwise the worktree file's own exec bit decides. Reads $smfalse and
# $fmfalse, the caller's locals, so the configs are read once per run, not once per path.
recorded_reg_mode() {
  local p=$1 IDX_ENTRY_MODE
  RECORDED_MODE=100644
  if [ "$smfalse" = 1 ]; then
    index_entry_mode "$p"
    if [ "$IDX_ENTRY_MODE" = 120000 ]; then
      RECORDED_MODE=120000
      return
    fi
  fi
  if [ "$fmfalse" = 1 ]; then
    index_entry_mode "$p"
    case $IDX_ENTRY_MODE in
    100644 | 100755) RECORDED_MODE=$IDX_ENTRY_MODE ;;
    *) RECORDED_MODE=100644 ;;
    esac
    return
  fi
  if [ -x "$top/$p" ]; then
    RECORDED_MODE=100755
  fi
}

# ==================================================================== unpark
#
# git unpark [<path>...]: take paths out of the hangar.
#
# One rule: unpark always takes the path out of the hangar. The stopped merge is restored into
# the index only when the working directory still shows the unchanged state, that is, only when
# there is nothing to preserve.
#
# Subject : every path whose .hangar/stages/<path>/ directory exists at HEAD, conflicts and
#           w-only (incomplete) directories alike. No argument means every path. An argument is
#           a real path resolved from the user's cwd ('.' and '..' included, a resolved top
#           meaning every held path) that selects every held path equal to it or nested under
#           it, byte-exact: no globs, no pathspec magic. A path naming no held path is an error.
#           Dirty checkouts are fine: the outcome compares the working directory by design.
# Outcomes: the working file (clean-filtered, git hash-object, and the mode git would
#           record for it) against file w's stored blob and mode, and absent on both sides
#           is a match. On a match, reopen: force-remove the path's stage-0 first (a stray
#           stage-0 beside stages 1-3 makes git add fail to clear the entry), then feed
#           1/2/3 back with mode and sha from the hangar's tree entries. On a mismatch, no
#           index state: the working directory is the resolution, left unstaged for
#           review. The mode is part of the file: a mode-only change (a chmod) or a
#           type-only change (a regular/symlink swap holding the same bytes) is a change,
#           not an unchanged state, and the verdict names the kind as the porcelain does
#           (diff's old mode/new mode, status's T); the staged and committed doors name the
#           kind too.
#           core.fileMode false and core.symlinks false are read the way git's own add
#           reads them (ce_mode_from_stat), or a change git itself ignores would misreport.
#           Either way the stages directory is deleted from index and worktree; the removal
#           is the record of release.
#
# Refuses : HEAD not a parked chain (a staged, uncommitted park has its own refusal); any
#           merge, rebase, cherry-pick, revert, or am in progress here; detached HEAD; a
#           worktree .hangar that is missing or unreadable; a matched path hidden by a sparse
#           checkout; a symlink or a non-directory standing on a matched path's stages
#           directory (the release's rm -rf never traverses a link); no held paths (run land
#           instead). A manifest first line that is not ours, at HEAD or in the worktree,
#           dies: the hangar is not this tool's.

unpark_main() {
  local cur i p rec r b reopened resolved incomplete review staged recorded
  local arg comp found j prefix w present worktree_sha frozen_sha outcome literal q summary delta
  local worktree_mode frozen_mode fmfalse smfalse RECORDED_MODE
  local npspecs nstage nparked nmatch nhid nleft
  local nb nsp
  # The stage-tree records and the walk's outputs are local to this call through bash dynamic
  # scoping; the walk's header asks every caller to declare them local.
  local SPAR SSTAGE SMODE SSHA PARKED PHAVE123 PWSHA PWMODE
  local BLOCKHEAD BLOCKNEXT BLOCKTAIL BLOCKSTART BLOCKEND PSTACK
  local MATCHED M_OF_M MHAVE123 MWSHA MWMODE NARGS REOPEN hidden RELSPEC LEFT

  PSPECS=()
  npspecs=0
  while [ $# -gt 0 ]; do
    case $1 in
    --help) help ;;
    -h)
      print_help >&2
      exit 129
      ;;
    --version) show_version ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        PSPECS[npspecs]=$1
        npspecs=$((npspecs + 1))
        shift
      done
      ;;
    -*) usage "unknown flag: $1 (a path starting with '-' needs '--' first)" ;;
    *)
      PSPECS[npspecs]=$1
      npspecs=$((npspecs + 1))
      shift
      ;;
    esac
  done

  begin_applet

  if [ -f "$(gitpath MERGE_HEAD)" ]; then
    if tree_has_hangar HEAD; then
      refuse "cannot proceed while a merge is in progress; finish or abort it, then re-run"
    fi
    refuse "cannot proceed while a merge is in progress; finish or abort it, or park it with 'git park --branch <name>'"
  fi
  in_progress_check
  if ! git -C "$top" cat-file -e "HEAD:$HANGAR/manifest" 2>/dev/null; then
    if park_staged_uncommitted; then refuse_park_window; fi
    refuse_recovery \
      "HEAD is not a parked merge (its tree carries no $HANGAR/manifest)." \
      "fetch and switch to the carrier branch; for a handoff, run 'git fetch <remote>' and 'git switch --track <remote>/<carrier>', then re-run"
  fi
  require_hangar_line "$(manifest_first_line HEAD)" HEAD
  cur=$(git -C "$top" symbolic-ref -q --short HEAD || true)
  if [ -z "$cur" ]; then
    refuse "detached HEAD: the merge work must live on a branch; git switch -c <name> first, then re-run"
  fi
  require_worktree_hangar

  # --- the held paths: from the hangar's tree ---
  # strict: these records feed back into the index, so a mangled hangar is refused at read time,
  # before the walk classifies anything.
  dump_stage_tree HEAD strict

  # One walk classifies every path once and fills the per-path aggregates for the outcome loop
  # (a path's records may span blocks when a nested held path sorts between them).
  walk_stage_blocks
  if [ "$nparked" -eq 0 ]; then
    refuse "nothing to reopen: every path is already released; run 'git land <dst>' to land the merge"
  fi

  # --- path matching: real paths, a directory takes its subtree ---
  # An argument names a real path, resolved from the user's cwd exactly as any git command
  # resolves it, and selects every held path equal to it or nested under it: a directory
  # argument takes the whole subtree of held paths beneath it, the same scope a release
  # takes, so a selected parent releases its nested records together. No globs, no magic:
  # the match is a byte-exact comparison over the walk's PARKED list. A synthetic index
  # would not do: it silently drops one of two held paths nested inside each other, and
  # the match would run over the diminished list.
  if [ "$npspecs" -gt 0 ]; then
    prefix=
    prefix=$(git rev-parse --show-prefix 2>/dev/null) || die "rev-parse --show-prefix failed"
    # --show-prefix ends one level deep in and is empty at the top, so strip its
    # trailing '/': a '..' pop must take a whole component off it
    while [ "$prefix" != "${prefix%/}" ]; do prefix=${prefix%/}; done
    # Resolve every argument to a top-relative path ('.' and '..' resolved, empty
    # components dropped) and refuse it unless it names a held path or a directory
    # holding one, git add's own rule: a misspelling or a pathspec-magic spelling is
    # refused, never silently ignored.
    NARGS=()
    for ((j = 0; j < npspecs; j++)); do
      arg=${PSPECS[$j]}
      case $arg in
      /*) die "an absolute path is not taken ($(quote_path "$arg")): name the path from your current directory" ;;
      esac
      # a non-empty argument is required, git add's own rule, checked before
      # resolution: an empty one joined to the prefix would silently name the cwd's
      # whole subtree
      [ -n "$arg" ] || usage "an empty path argument"
      # resolve '.' and '..' component-wise against the prefix, as any git command
      # resolves them: '.' is dropped, '..' pops one component, an empty component is
      # dropped; a pop past the top is outside the repository, and an empty result is
      # the top itself
      r=$prefix
      w=$arg
      while :; do
        comp=${w%%/*}
        if [ "$comp" = .. ]; then
          case $r in
          ?*/*) r=${r%/*} ;;
          ?*) r= ;;
          *) die "$(quote_path "$arg") resolves above the repository root; name the path from the repository root" ;;
          esac
        elif [ -n "$comp" ] && [ "$comp" != . ]; then
          r=${r:+$r/}$comp
        fi
        [ "$w" = "$comp" ] && break
        w=${w#*/}
      done
      # every argument must select at least one held path, git add's own rule; the
      # resolved top always does (the walk has already refused an empty hangar)
      found=0
      if [ -z "$r" ]; then
        found=1
      else
        for ((i = 0; i < nparked; i++)); do
          case ${PARKED[$i]} in
          "$r" | "$r"/*)
            found=1
            break
            ;;
          esac
        done
      fi
      [ "$found" = 1 ] || die "$(quote_path "$r") is not a held path, and no held path is under it: name a held path or a directory holding one"
      NARGS[j]=$r
    done
    # A path is selected once, by its first matching argument. Taking a directory takes
    # every held path under it, and the resolved top takes them all, exactly as no
    # argument does.
    MATCHED=()
    M_OF_M=()
    MHAVE123=()
    MWSHA=()
    nmatch=0
    for ((i = 0; i < nparked; i++)); do
      for ((j = 0; j < npspecs; j++)); do
        # an empty NARGS entry is the resolved top: every held path is under it, so it
        # selects like no argument does
        if [ -n "${NARGS[$j]}" ]; then
          case ${PARKED[$i]} in
          "${NARGS[$j]}" | "${NARGS[$j]}"/*) ;;
          *) continue ;;
          esac
        fi
        MATCHED[nmatch]=${PARKED[$i]}
        M_OF_M[nmatch]=$i
        MHAVE123[nmatch]=${PHAVE123[i]}
        MWSHA[nmatch]=${PWSHA[i]}
        MWMODE[nmatch]=${PWMODE[i]}
        nmatch=$((nmatch + 1))
        break
      done
    done
  else
    MATCHED=(${PARKED[@]+"${PARKED[@]}"})
    nmatch=$nparked
    # No argument: every path matches, at its own park index.
    M_OF_M=()
    MHAVE123=(${PHAVE123[@]+"${PHAVE123[@]}"})
    MWSHA=(${PWSHA[@]+"${PWSHA[@]}"})
    MWMODE=(${PWMODE[@]+"${PWMODE[@]}"})
    for ((i = 0; i < nmatch; i++)); do
      M_OF_M[i]=$i
    done
  fi

  # --- a sparse checkout must not hide a matched path's working file ---
  # The outcome compares the working file, and a skip-worktree entry (tag S) puts the path
  # outside that comparison, file present or not: such a path is refused, not judged.
  # Record shape: <tag> <path>, NUL-delimited.
  hidden=()
  nhid=0
  if sparse_checkout_on; then
    for ((i = 0; i < nmatch; i++)); do
      p=${MATCHED[$i]}
      git -C "$top" ls-files -t -z -- ":(literal)$p" >"$td/pathtags" ||
        die "ls-files failed on a matched path"
      while IFS= read -r -d '' rec || [ -n "$rec" ]; do
        [ -n "$rec" ] || continue
        if [ "${rec%% *}" = S ]; then
          hidden[nhid]=$p
          nhid=$((nhid + 1))
          break
        fi
      done <"$td/pathtags"
    done
    if [ "$nhid" -gt 0 ]; then
      refuse_recovery \
        "the sparse checkout hides the working file of $(counted "$nhid" "held path"): $(cap_list 10 "${hidden[@]}"); a hidden file cannot be compared with the parked copy." \
        "bring each hidden path into the sparse checkout (cone mode: git sparse-checkout add its directory), then re-run"
    fi
  fi

  # --- a symlink on a matched path's stages directory would carry the release outside ---
  # The release removes the stages directories by their worktree paths, and the hangar's
  # directories are real directories: a link (or a non-directory) standing on one is
  # refused before anything is taken out, or the release's rm -rf would follow it out of
  # the repository.
  : >"$td/linkpaths"
  if [ "$nmatch" -gt 0 ]; then
    printf '%s\0' "${MATCHED[@]}" >>"$td/linkpaths"
  fi
  refuse_stages_links "$td/linkpaths"

  # --- outcomes ---
  # The mode of a regular worktree file is read the way git's own add reads it
  # (ce_mode_from_stat): core.fileMode false keeps the index entry's mode and cannot read
  # the exec bit, and core.symlinks false keeps a symlink entry's mode for the regular
  # file a link checks out as. Both configs are read once here; recorded_reg_mode reads
  # the locals.
  fmfalse=0
  smfalse=0
  if [ "$(git -C "$top" config --bool core.fileMode 2>/dev/null || true)" = false ]; then
    fmfalse=1
  fi
  if [ "$(git -C "$top" config --bool core.symlinks 2>/dev/null || true)" = false ]; then
    smfalse=1
  fi
  : >"$td/feed"
  : >"$td/rmfeed"
  reopened=0
  resolved=0
  incomplete=0
  review=0
  staged=0
  recorded=0
  REOPEN=()
  for ((i = 0; i < nmatch; i++)); do
    p=${MATCHED[$i]}
    literal=":(literal)$p"
    REOPEN[i]=0
    # the kind of a mode- or type-only resolution, set by the outcome chain below and read by
    # the staged and committed doors; reset per path, or a door would read the last path's kind
    delta=
    if [ "${MHAVE123[$i]}" = 0 ]; then
      outcome='no stage files, only the parked copy (releasing)'
      incomplete=$((incomplete + 1))
    else
      frozen_sha=${MWSHA[$i]}
      frozen_mode=${MWMODE[$i]}
      present=0
      if [ -e "$top/$p" ] || [ -L "$top/$p" ]; then present=1; fi
      worktree_sha=
      worktree_mode=
      if [ "$present" = 1 ]; then
        if [ -L "$top/$p" ]; then
          # Symlinks take no filters: hash the readlink target verbatim (hash-object would follow
          # the link; -n drops readlink's own trailing newline). The link's own mode is the
          # recorded one whatever the parked file was: the type is structural, under every
          # config.
          worktree_sha=$(readlink -n "$top/$p" | git -C "$top" hash-object --stdin)
          worktree_mode=120000
        elif [ -f "$top/$p" ]; then
          worktree_sha=$(git -C "$top" hash-object -- "$p")
          recorded_reg_mode "$p"
          worktree_mode=$RECORDED_MODE
        fi
      fi
      if [ "$present" = 0 ]; then
        if [ -z "$frozen_sha" ]; then
          outcome='no file (reopened)'
        else
          outcome='no file (resolved as a deletion)'
        fi
      else
        # The blob alone is not the file: the mode is part of it, and a mode-only or type-only
        # change is a change, the working file, mode included, being the resolution. A blob-equal
        # mode difference is named by its kind, the words the porcelain uses for it (diff's old
        # mode/new mode lines, status's T), so the reader recognizes the event in the next
        # command run; a blob difference names the content alone, the change the reader has
        # already seen. delta carries the kind to the staged and committed doors below, where
        # the worktree is held equal to the index (and to HEAD at the committed door), so the
        # recorded resolution is named by the same kind.
        if [ -z "$worktree_sha" ]; then
          # Present but neither file nor symlink (a directory): the working tree is the resolution.
          outcome='differs (that content is the resolution)'
        elif [ -z "$frozen_sha" ]; then
          outcome='restored (that content is the resolution)'
        elif [ "$worktree_sha" = "$frozen_sha" ] && [ "$worktree_mode" = "$frozen_mode" ]; then
          outcome='unchanged (reopened)'
        elif [ "$worktree_sha" = "$frozen_sha" ]; then
          # The blob matches, the mode does not: one side a symlink is a type change, an
          # exec-bit difference a mode change
          if [ "$worktree_mode" = 120000 ] || [ "$frozen_mode" = 120000 ]; then
            delta='type'
            outcome='differs only in type (that type is the resolution)'
          else
            delta='mode'
            outcome='differs only in mode (that mode is the resolution)'
          fi
        else
          outcome='differs (that content is the resolution)'
        fi
      fi
      case $outcome in
      'unchanged (reopened)' | 'no file (reopened)')
        reopened=$((reopened + 1))
        REOPEN[i]=1
        # Force-remove the stray stage-0 first, via --stdin: an index-info removal line names a
        # zero object id, which sha256 repositories reject. The 1/2/3 feed is written after the
        # loop.
        printf '%s\0' "$p" >>"$td/rmfeed"
        ;;
      *)
        resolved=$((resolved + 1))
        # A differing worktree can be an unstaged resolution, one already staged in the index, or
        # one already committed in the chain with only its hangar release forgotten.
        if ! git -C "$top" diff --quiet --no-ext-diff -- "$literal"; then
          review=$((review + 1))
        elif [ "$present" = 1 ] &&
          ! git -C "$top" ls-files --error-unmatch -- "$literal" >/dev/null 2>&1; then
          review=$((review + 1))
        elif ! git -C "$top" diff --cached --quiet --no-ext-diff HEAD -- "$literal"; then
          staged=$((staged + 1))
          outcome='already staged (releasing)'
          [ -z "$delta" ] || outcome="already staged (releasing; differs only in $delta)"
        else
          recorded=$((recorded + 1))
          outcome='already committed (releasing)'
          [ -z "$delta" ] || outcome="already committed (releasing; differs only in $delta)"
        fi
        ;;
      esac
    fi

    q=$(quote_path "$p")
    printf '%s: %s: %s\n' "$APPLET" "$outcome" "$q"
  done

  # The reopen feed: one update-index line per stage 1/2/3 record of every reopened path, read
  # through each path's block chain instead of a rescan per path. update-index takes entries in any
  # order, but git resolves a file path and a directory path under it by insertion order, and a
  # hand-built hangar can hold such a pair, so the record order is kept.
  for ((i = 0; i < nmatch; i++)); do
    [ "${REOPEN[$i]}" = 1 ] || continue
    b=${BLOCKHEAD[${M_OF_M[$i]}]}
    while [ "$b" -ge 0 ]; do
      for ((r = BLOCKSTART[b]; r <= BLOCKEND[b]; r++)); do
        if [ "${SSTAGE[$r]}" = w ]; then continue; fi
        printf '%s %s %s\t%s\0' "${SMODE[$r]}" "${SSHA[$r]}" "${SSTAGE[$r]}" "${SPAR[$r]}" >>"$td/feed"
      done
      b=${BLOCKNEXT[$b]}
    done
  done

  if [ -s "$td/rmfeed" ]; then
    git -C "$top" update-index -z --force-remove --stdin <"$td/rmfeed" ||
      die "update-index --force-remove failed while reopening"
  fi
  if [ -s "$td/feed" ]; then
    git -C "$top" update-index -z --index-info <"$td/feed" ||
      die "update-index failed while reopening"
  fi

  # --- release: the stages directory's removal is the record ---
  # Index plumbing, not git rm: under a sparse checkout git rm skips out-of-pattern paths and
  # still exits 0 with --ignore-unmatch (-q hides even the advice), while update-index
  # --force-remove takes the entries whatever the patterns say. ls-files with the same literal
  # specs enumerates them, because it matches over the index, not the patterns. The worktree
  # half is rm -rf over every matched stages directory, so nothing below can bring the entries
  # back.
  RELSPEC=()
  for ((i = 0; i < nmatch; i++)); do
    RELSPEC[i]=":(literal)$HANGAR/stages/${MATCHED[$i]}"
  done
  git -C "$top" ls-files -z -- ${RELSPEC[@]+"${RELSPEC[@]}"} >"$td/rmlist" ||
    die "ls-files failed over the stages directories"
  if [ -s "$td/rmlist" ]; then
    git -C "$top" update-index -z --force-remove --stdin <"$td/rmlist" ||
      die "update-index --force-remove failed while releasing the stages directories"
  fi
  : >"$td/rmdirs"
  for ((i = 0; i < nmatch; i++)); do
    printf '%s\0' "$top/$HANGAR/stages/${MATCHED[$i]}" >>"$td/rmdirs"
  done
  if [ -s "$td/rmdirs" ]; then
    xargs -0 rm -rf -- <"$td/rmdirs" || die "rm -rf of the stages directories failed"
  fi
  prune_stages_dirs
  git -C "$top" add -f -A --sparse -- "$HANGAR" || die "git add -f -A $HANGAR failed"

  # --- the release is the record, so it is verified before it is reported ---
  # Nothing under the specs may remain in the index, and no stages directory in the worktree.
  git -C "$top" ls-files -z -- ${RELSPEC[@]+"${RELSPEC[@]}"} >"$td/rmleft" ||
    die "ls-files failed over the released stages directories"
  LEFT=()
  nleft=0
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    LEFT[nleft]=$rec
    nleft=$((nleft + 1))
  done <"$td/rmleft"
  for ((i = 0; i < nmatch; i++)); do
    if [ -e "$top/$HANGAR/stages/${MATCHED[$i]}" ] || [ -L "$top/$HANGAR/stages/${MATCHED[$i]}" ]; then
      LEFT[nleft]="$HANGAR/stages/${MATCHED[$i]} (worktree)"
      nleft=$((nleft + 1))
    fi
  done
  if [ "$nleft" -gt 0 ]; then
    die_recovery \
      "the stages release did not complete: $(counted "$nleft" "stage entry" "stage entries") remain in the index or the worktree: $(cap_list 10 "${LEFT[@]}")." \
      "the paths stay parked at HEAD, so nothing is lost: inspect git status, remove the leftovers by hand if they persist, then re-run"
  fi

  summary="$APPLET: $(counted "$nmatch" path) taken out of the hangar; $(counted "$reopened" path) reopened; $(counted "$resolved" resolution) released"
  if [ "$incomplete" -gt 0 ]; then
    summary="$summary; $(counted "$incomplete" "incomplete path" "incomplete paths") released"
  fi
  echo "$summary"
  if [ "$review" -eq 1 ]; then
    echo "$APPLET: 1 resolution is unstaged for review: git add it, then commit"
  elif [ "$review" -gt 1 ]; then
    echo "$APPLET: $review resolutions are unstaged for review: git add them, then commit"
  fi
  if [ "$staged" -gt 0 ]; then
    echo "$APPLET: $(counted "$staged" resolution) already staged: review and commit when ready"
  fi
  if [ "$recorded" -gt 0 ]; then
    echo "$APPLET: $(counted "$recorded" resolution) already committed: commit the hangar release"
  fi
}

# Remove the now-empty stages directories of the released paths.
# Git never tracks directories, so this is cosmetic. Ancestor chains are listed bottom-up.
# Relies on unpark_main's locals through dynamic scoping.
prune_stages_dirs() {
  local i d
  : >"$td/prunedirs"
  for ((i = 0; i < nmatch; i++)); do
    d="$top/$HANGAR/stages/${MATCHED[$i]}"
    while [ "$d" != "$top/$HANGAR" ]; do
      printf '%s\0' "$d" >>"$td/prunedirs"
      d=${d%/*}
    done
  done
  [ -s "$td/prunedirs" ] || return 0
  xargs -0 rmdir -- <"$td/prunedirs" 2>/dev/null || true
}

# ====================================================================== land
#
# git land [--amend] [--check] <dst>: check or land the chain at HEAD onto <dst>.
#
# The chain comes from HEAD; the destination is always named and never recorded: at landing time
# it may not exist in that clone, may point elsewhere, or may have been renamed. Nothing in the
# hangar is a ref name that is ever resolved (source-desc is a label, rendered into prose), so the
# hangar means the same thing in every clone. The source is recorded as an id for the same reason
# ("a branch can move; the source must be immutable").
#
# Every landing works from two records read out of the chain. The base is the first-parent walk
# from the chain tip to the first tree without the format line, the commit every landing starts
# from. The resolved tree is a chain commit's tree minus .hangar (ls-tree into mktree), built per
# chain commit; a landing stages the resolved tree of the chain commit that was the tip at
# landing time. The resolved trees are the only content inspected: a released path still carrying
# its conflict markers lands verbatim, because plain git commits such content.
#
# Subject : a parked chain at HEAD, and <dst>, an existing local branch, never the carrier
#           branch (the one the parked merge is on). The landing always runs from the chain's own
#           branch, never from the destination: after a landing, the destination is no parked
#           chain, and land's "not a parked merge" refusal there is the correct answer.
# Refuses : in the order checked: a live MERGE_HEAD here, always the user's own (land never
#           starts one before returning), leaving the final `git commit` / `git merge --continue`
#           to the user; an unfinished rebase/cherry-pick/revert/am, and a staged, uncommitted
#           park (local-state guards, before any case below can move a ref: no case below is
#           safe over them, and they are the user's to finish either way); HEAD not a parked
#           chain (the refusal names the switch onto the chain branch; a manifest first line
#           that is not ours dies first: the hangar is not this tool's); paths still held,
#           reported per path with the recovery that fits (still unchanged: the git unpark
#           hint; resolution already in the chain: only the release), exit 2; w-only
#           directories, an incomplete hangar, exit 2; a worktree file, untracked or ignored,
#           standing on a path the resolved tree tracks; tracked changes in the checkout where
#           the landing starts; and <dst> at any position but at or behind the base, at the
#           chain tip, or, with --amend, at this chain's own earlier landing: every other
#           position holds work a landing may not keep (another merge of the recorded source
#           that is not one of this chain's landings included: which merge stands is not the
#           landing's to guess), and any rebase or deliberate history rewrite is the user's own
#           move, never the landing's.
# No-op   : this chain already landed in <dst>, a merge whose second parent is the recorded
#           source and whose tree is the resolved tree of the chain commit that was the tip at
#           landing time; a match is exit 0 wherever <dst> has gone since. (Ancestry was the
#           wrong question: it survives a revert, so a release reaching <dst> another way
#           would strand an unfinished chain at exit 0 forever; the tree is the chain's own
#           answer.)
# --amend : lands over this carrier's previous merge at <dst>'s tip, replacing it. The earlier
#           landing is recognized like the no-op, but against the whole chain: <dst>'s tip is
#           a merge whose second parent is the recorded source and whose tree is one of the
#           chain's own resolved trees, a state the chain has moved past. The landing amends
#           the earlier one, a forced update that names the range and warns where the earlier
#           landing went.
# --check : runs every readiness check but exits before a ref, index, or worktree change. It
#           is also the status query for a carrier: every not-ready refusal is the per-path
#           what-remains report, and the ready line names the landing's positions.
# Effect  : the move onto <dst> is git switch -C, porcelain on purpose; a branch checked out
#           in another worktree is checked by the tool itself first, because the porcelain
#           refusals for it are version-dependent. The sequence leaves the state an ordinary
#           resolved merge leaves: on <dst> at the base commit, resolutions staged, MERGE_HEAD
#           written, "All conflicts fixed but you are still merging". Land never commits:
#           the user's plain `git commit` records [base, source] with editor, hooks, signing,
#           and mergetag all their own. The escape is `git merge --abort` or `git reset
#           --hard`. An editor quit or hook failure stays in the prepared state; plain
#           `git commit` finishes later.

land_main() {
  local dst check amend endopts
  local cur mh live heads i
  local chain_tip srcv scc srcdesc
  local MSRC MSRCDESC
  dst=
  check=0
  amend=0
  endopts=0
  while [ $# -gt 0 ]; do
    if [ "$endopts" = 0 ]; then
      case $1 in
      --help) help ;;
      -h)
        print_help >&2
        exit 129
        ;;
      --version) show_version ;;
      --)
        endopts=1
        shift
        continue
        ;;
      --amend)
        amend=1
        shift
        continue
        ;;
      --check)
        check=1
        shift
        continue
        ;;
      -*) usage "unknown flag: $1" ;;
      esac
    fi
    if [ -z "$dst" ]; then
      dst=$1
    else
      usage "too many arguments (git land takes <dst>)"
    fi
    shift
  done
  if [ -z "$dst" ]; then
    # The destination is never recorded in the hangar, so a bare run cannot guess it.
    usage "git land takes <dst> (e.g. main)"
  fi

  begin_applet

  # --- <dst>: an existing local branch, never created here ---
  git -C "$top" show-ref --verify --quiet "refs/heads/$dst" ||
    die "no such local branch: $dst (the destination must exist; it is never created here)"
  cur=$(git -C "$top" symbolic-ref -q --short HEAD || true)

  # --- 1. a live MERGE_HEAD here: never finish it ---
  # A live merge is the user's own, including one prepared by an earlier land: a re-run never
  # turns into an implicit `git merge --continue`.
  mh=$(gitpath MERGE_HEAD)
  if [ -f "$mh" ]; then
    live=$(cat "$mh")
    if ! valid_id "$live"; then
      case $live in
      *$'\n'*)
        # mirror park's octopus refusal: the head count names the stop
        heads=$(grep -c . "$mh" || true)
        refuse_recovery \
          "cannot proceed while an octopus merge is in progress (MERGE_HEAD lists $heads heads): land never finishes a live merge." \
          "finish or abort it, then re-run"
        ;;
      *)
        die "MERGE_HEAD does not hold a single object id"
        ;;
      esac
    fi
    dump_unmerged
    if [ "$NUNIQ" -gt 0 ]; then
      for ((i = 0; i < NUNIQ; i++)); do
        printf '%s: unmerged path: %s\n' "$APPLET" "$(quote_path "${PPATHS[$i]}")" >&2
      done
      refuse_recovery \
        "a merge is already in progress with $(counted "$NUNIQ" path) still unmerged; land never finishes a live merge." \
        "resolve it and finish it yourself, abort it, or park it with 'git park --branch <name>'"
    fi
    refuse_recovery \
      "a merge is already prepared with no unmerged paths; land never finishes a live merge." \
      "review the staged result and run 'git commit' yourself, or abort it"
  fi
  in_progress_check
  # A staged, uncommitted park is checked here with in_progress_check for the same reason:
  # "not a parked merge" would misreport park's own uncommitted work.
  if park_staged_uncommitted; then refuse_park_window; fi

  # --- 2. HEAD is not a chain: the landing always runs from the chain ---
  if ! tree_has_hangar HEAD; then
    head_hangar_version
    refuse_recovery \
      "HEAD is not a parked merge; landing runs from the carrier, not the destination or a third branch." \
      "fetch and switch to the carrier branch, then re-run"
  fi

  # --- 3. the chain at HEAD ---
  chain_tip=$(git -C "$top" rev-parse HEAD)
  # read_manifest verifies the classification too: a damaged manifest is refused with its hand
  # fix, never misread as a landing problem elsewhere.
  read_manifest "$chain_tip" "$(short "$chain_tip")"
  srcv=$MSRC
  srcdesc=$MSRCDESC
  if ! scc=$(peel "$srcv"); then
    case $srcdesc in
    "commit '"*)
      refuse_recovery \
        "the merge's recorded source $(short "$srcv") is not present here." \
        "the source is recorded by id, not by name; fetch it from a remote that has it (a branch or tag at $(short "$srcv")), then re-run"
      ;;
    *)
      refuse_recovery \
        "the merge's recorded source $(short "$srcv") is not present here." \
        "fetch it ($srcdesc), then re-run"
      ;;
    esac
  fi
  land_chain
}

# Warn when a branch is behind its upstream.
warn_stale_branch() {
  local branch=$1 up upname btip n
  up=$(peel "$branch@{upstream}") || return 0
  btip=$(git -C "$top" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null) || return 0
  [ "$up" != "$btip" ] || return 0
  git -C "$top" merge-base --is-ancestor "$btip" "$up" || return 0
  n=$(git -C "$top" rev-list --count "$btip..$up")
  upname=$(git -C "$top" rev-parse --abbrev-ref "$branch@{upstream}")
  warn "$branch is behind '$upname' by $(counted "$n" commit), and can be fast-forwarded"
}

# A complete chain at HEAD: land it onto <dst>. land_main's locals are in scope here through
# bash dynamic scoping: chain_tip (the chain's tip commit), srcv (its recorded source id), scc
# (the source's peel), srcdesc (its recorded description), cur (the chain's branch), dst,
# check, and amend.
land_chain() {
  local rec rest dirty extra
  local base resolved_tree dst_tip p2 amended where
  local i FROZEN RESOLVED NFRO NRES

  # --- held-paths check ---
  held_paths_of "$chain_tip"
  if [ "$NHELD" -gt 0 ]; then
    # Report each held path with the recovery that fits it: the hangar still holds it, but the
    # chain tip may already carry the resolution (the usual forgetting point: fixed, added,
    # committed, never released), and then only the release is missing.
    classify_held_paths "$chain_tip"
    # One report line per group, capped: the classification is the new information. An unchanged-only
    # state prints no line; its refusal already lists the paths.
    if [ "$NRES" -gt 0 ]; then
      if [ "$NFRO" -gt 0 ]; then
        echo "$APPLET: still unchanged: $(cap_list 10 "${FROZEN[@]}")" >&2
      fi
      echo "$APPLET: already resolved but not released: $(cap_list 10 "${RESOLVED[@]}")" >&2
    fi
    if [ "$NRES" -eq 0 ]; then
      refuse_recovery \
        "conflicts are still held: $(cap_list 10 "${HELD_PATHS[@]}")." \
        "for each path, run 'git unpark -- <path>', fix it, git add it, and commit; unpark records the release"
    elif [ "$NFRO" -eq 0 ]; then
      refuse_recovery \
        "$(counted "$NRES" resolution) already committed but not released." \
        "run 'git unpark -- <path>' for each listed path (or git rm its $HANGAR/stages/<path>), then commit the releases"
    else
      refuse_recovery \
        "$(counted "$NFRO" conflict) still unchanged and $(counted "$NRES" resolution) committed but not released." \
        "unpark, fix, add, and commit unchanged paths; unpark already-resolved paths and commit their releases"
    fi
  fi
  if [ "$NWONLY" -gt 0 ]; then
    refuse_recovery \
      "incomplete hangar: $HANGAR/stages/ holds only file w at: $(cap_list 10 "${WONLY_PATHS[@]}")." \
      "release each with 'git unpark -- <path>' or 'git rm -r $HANGAR/stages/<path>', commit, then re-run"
  fi

  # --- the base commit: the first-parent walk out of the chain ---
  base=$chain_tip
  while tree_has_hangar "$base"; do
    base=$(git -C "$top" rev-parse -q --verify "$base^1" 2>/dev/null) ||
      die "the merge work's history reaches past the repository root: every commit here carries the hangar; it cannot land"
  done

  # --- the resolved tree: the tip tree minus .hangar ---
  resolved_tree_of "$chain_tip"
  resolved_tree=$RTREE

  # --- did this chain already land in <dst>? ---
  # This chain's landing is a merge in <dst> whose second parent is the recorded source and
  # whose tree is this chain's resolved tree. The search reads <dst>'s history after the source,
  # so it finds the landing wherever <dst> has gone since; a different chain's landing of the
  # same source (a different tree) is no match.
  git -C "$top" rev-list --parents --min-parents=2 --max-parents=2 "refs/heads/$dst" --not "$scc" >"$td/landings" ||
    die "rev-list of $dst failed"
  while IFS= read -r rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    rest=${rec#* }
    [ "${rest##* }" = "$scc" ] || continue
    if [ "$(git -C "$top" rev-parse -q --verify "${rec%% *}^{tree}" 2>/dev/null || true)" = "$resolved_tree" ]; then
      echo "$APPLET: this merge already landed in $dst: nothing to do"
      exit 0
    fi
  done <"$td/landings"

  # --- the chain's branch: the landing always starts from it ---
  # A detached tip of an already-landed chain is the no-op above. Standing on <dst> means <dst>
  # is the chain's branch (HEAD is a chain, and <dst> is the branch you stand on), and the
  # refusal below fires.
  if [ -z "$cur" ]; then
    refuse "detached HEAD: the merge work must live on a branch; git switch -c <name> first, then re-run"
  fi
  if [ "$cur" = "$dst" ]; then
    refuse_recovery \
      "$dst is the carrier branch; a merge cannot land onto its own carrier branch." \
      "choose another existing destination (usually 'git land main'); to reuse this name as the destination, first preserve the merge work with 'git switch -c <new-carrier>'"
  fi

  # --- worktree-collision check (before the first move, every path) ---
  worktree_collision_check "$resolved_tree"

  # --- clean-checkout check: tracked content clean where the landing starts ---
  # --ignore-submodules=dirty: dirt inside a submodule cannot be committed or stashed from here, so
  # it must not block. Only a moved pointer still shows.
  git -C "$top" status --porcelain -z --ignore-submodules=dirty >"$td/status" || die "git status failed"
  dirty=0
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    extra=${rec:0:2}
    case $extra in
    '??') ;;
    R? | C?)
      dirty=1
      # a rename/copy record carries a second NUL-delimited path
      IFS= read -r -d '' extra || [ -n "$extra" ] || true
      ;;
    *) dirty=1 ;;
    esac
  done <"$td/status"
  if [ "$dirty" = 1 ]; then
    refuse "the checkout has tracked changes: commit or stash them, then re-run"
  fi

  # --- landing behind upstream warnings ---
  warn_stale_branch "$cur"
  warn_stale_branch "$dst"

  # --- dst-position check ---
  dst_tip=$(git -C "$top" rev-parse "refs/heads/$dst")
  p2=$(git -C "$top" rev-parse -q --verify "$dst_tip^2" 2>/dev/null || true)
  amended=0
  if ! git -C "$top" merge-base --is-ancestor "$dst_tip" "$base" &&
    [ "$dst_tip" != "$chain_tip" ]; then
    if [ "$p2" = "$scc" ] && is_our_landing "$dst_tip"; then
      if [ "$amend" = 1 ]; then
        amended=1
      else
        refuse_recovery \
          "$dst's tip is this carrier's earlier landing ($(short "$dst_tip") \"$(git -C "$top" log -1 --format=%s "$dst_tip")\"); landing would amend it" \
          "re-run with --amend"
      fi
    elif [ "$p2" = "$scc" ]; then
      refuse_recovery \
        "$dst's tip is a merge of $srcdesc ($(short "$dst_tip") \"$(git -C "$top" log -1 --format=%s "$dst_tip")\"); landing would replace it" \
        "keep $dst's merge and do not land, or reset $dst and re-run"
    else
      refuse_recovery \
        "$dst cannot fast-forward to the merge's base commit $(short "$base")" \
        "rebase the carrier onto $dst, or reset $dst to $(short "$base"); then re-run"
    fi
  elif [ "$amend" = 1 ]; then
    refuse "--amend: $dst's tip is not this carrier's earlier landing"
  fi

  # --- the landing ---
  # The sequence ends in git switch -C $dst, so refuse the move while $dst is checked out in
  # another worktree.
  refuse_dst_checked_out_elsewhere "$dst"
  if [ "$amended" = 1 ]; then
    where="(forced update $(short "$dst_tip")...$(short "$base"))"
  elif [ "$dst_tip" != "$base" ] && git -C "$top" merge-base --is-ancestor "$dst_tip" "$base"; then
    where="(fast-forward $(short "$dst_tip")..$(short "$base"))"
  else
    where="($(short "$base"))"
  fi
  if [ "$check" = 1 ]; then
    echo "$APPLET: check: ready to land merge from $cur onto $dst $where"
    exit 0
  fi
  # Capture the switches' output and discard it on success: land's report is the only output.
  # switch -C to a branch with an upstream prints a tracking hint to stdout that would come
  # ahead of the report. The failure path prints both captures.
  if ! git -C "$top" switch --detach "$base" >"$td/out" 2>"$td/err"; then
    cat "$td/err" "$td/out" >&2
    refuse "git switch --detach failed (message above): resolve what it names, then re-run"
  fi
  git -C "$top" read-tree -u --reset "$resolved_tree" ||
    die "git read-tree failed while preparing the landing"
  if ! git -C "$top" switch -C "$dst" >"$td/out" 2>"$td/err"; then
    cat "$td/err" "$td/out" >&2
    # Unwind to the chain tip: the landing is reproducible from the chain, so nothing is lost by
    # going back.
    git -C "$top" reset -q --hard "$chain_tip" || :
    git -C "$top" switch -q "$cur" || :
    refuse "git switch -C $dst was refused (message above); the checkout is back where it started; resolve what it names, then re-run"
  fi
  write_merge_state "$chain_tip" "$srcv" "$srcdesc"
  echo "$APPLET: prepared the landing on $dst $where: resolutions staged, MERGE_HEAD written ($(short "$srcv"))"
  if [ "$amended" = 1 ]; then
    warn "$(short "$dst_tip") is an earlier landing of this parked merge; now recorded in the reflog as $dst@{1}"
  fi
  echo "$APPLET: the merge work stays on $cur; run 'git commit' to finish the merge"
  exit 0
}

# The resolved tree of $1: its tree minus the hangar, the tree a landing stages. Sets RTREE.
resolved_tree_of() {
  local c=$1 rec epath
  git -C "$top" ls-tree -z "$c" >"$td/entries" || die "ls-tree of $(short "$c") failed"
  : >"$td/resolved"
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    epath=${rec#*$'\t'}
    if [ "$epath" = "$HANGAR" ]; then continue; fi
    printf '%s\0' "$rec" >>"$td/resolved"
  done <"$td/entries"
  RTREE=$(git -C "$top" mktree -z <"$td/resolved") ||
    die "mktree failed building the resolved tree of $(short "$c")"
}

# Is $1 this chain's own landing? A landing stages the chain's resolved tree, so its commit
# tree equals the resolved tree of the chain commit that was the tip at landing time. Walks
# the chain's commits, tip to park, matching $1's tree against each one's resolved tree; the
# tip itself cannot match here (its match is the already-landed no-op before any of this), so
# a match is a landing the chain has moved past. Content is the proof, not commit identity.
# Returns 0 on a match, 1 on none. chain_tip is the caller's, through dynamic scoping.
is_our_landing() {
  local c want
  want=$(git -C "$top" rev-parse -q --verify "$1^{tree}" 2>/dev/null) ||
    die "cannot read the tree of $(short "$1")"
  c=$chain_tip
  while tree_has_hangar "$c"; do
    resolved_tree_of "$c"
    [ "$RTREE" = "$want" ] && return 0
    c=$(git -C "$top" rev-parse -q --verify "$c^1" 2>/dev/null) ||
      die "the merge work's history reaches past the repository root: every commit here carries the hangar; it cannot land"
  done
  return 1
}

# Held paths of a commit (stages directories holding 1/2/3) into HELD_PATHS, with each path's
# file w blob and mode in HELD_W and HELD_WM, and w-only directories into WONLY_PATHS, in
# first-appearance order. The read is lenient, for land only reports these records; unpark,
# which feeds them back into the index, refuses a mangled hangar. The shared block walk
# classifies them: one pass, each path once.
held_paths_of() {
  local c i
  local SPAR SSTAGE SMODE SSHA nstage PARKED PHAVE123 PWSHA PWMODE nparked
  local BLOCKHEAD BLOCKNEXT BLOCKTAIL BLOCKSTART BLOCKEND nb PSTACK nsp
  c=$1
  HELD_PATHS=()
  HELD_W=()
  HELD_WM=()
  WONLY_PATHS=()
  NHELD=0
  NWONLY=0
  dump_stage_tree "$c"
  walk_stage_blocks
  for ((i = 0; i < nparked; i++)); do
    if [ "${PHAVE123[$i]}" = 1 ]; then
      HELD_PATHS[NHELD]=${PARKED[$i]}
      HELD_W[NHELD]=${PWSHA[$i]}
      HELD_WM[NHELD]=${PWMODE[$i]}
      NHELD=$((NHELD + 1))
    else
      WONLY_PATHS[NWONLY]=${PARKED[$i]}
      NWONLY=$((NWONLY + 1))
    fi
  done
}

# Classify the held paths (set by held_paths_of) by what the chain tip carries, into FROZEN/NFRO
# and RESOLVED/NRES, the caller's through dynamic scoping. This is unpark's outcome comparison
# against the committed chain: the tip's entry at the path, its blob and its mode, vs the stored
# file w's blob and mode, and absent == absent is a match. A match is still unchanged. A
# difference is a resolution already committed, missing only its release; a mode-only
# resolution (a chmod, a type change on the same bytes) included, or it would be told to reopen
# work it already carries. The worktree is never consulted: land works from the chain.
#
# ls-tree answers the entry in one call per held path: the literal prefix is the one magic
# its mask accepts (it clears the wildcard flags besides, so a path holding glob bytes is
# still a literal name), and a directory spec shows the directory's own entry, so the
# record's path is matched exactly. Anything the file became instead of the blob w (a
# directory 040000, a gitlink 160000) and an absent path both fall to RESOLVED, as no blob
# w ever equaled their ids before them either.
classify_held_paths() {
  local tip=$1 i p rec tmode tsha path
  FROZEN=()
  RESOLVED=()
  NFRO=0
  NRES=0
  for ((i = 0; i < NHELD; i++)); do
    p=${HELD_PATHS[$i]}
    tmode=
    tsha=
    git -C "$top" ls-tree -z "$tip" -- ":(literal)$p" >"$td/tipentry" ||
      die "ls-tree of $tip failed reading the entry of $(quote_path "$p")"
    while IFS= read -r -d '' rec || [ -n "$rec" ]; do
      [ -n "$rec" ] || continue
      path=${rec#*$'\t'}
      [ "$path" = "$p" ] || continue
      tmode=${rec%%$'\t'*}
      tsha=${tmode#* }
      tsha=${tsha##* }
      tmode=${tmode%% *}
      break
    done <"$td/tipentry"
    if [ "$tsha" = "${HELD_W[$i]}" ] && [ "$tmode" = "${HELD_WM[$i]}" ]; then
      FROZEN[NFRO]=$p
      NFRO=$((NFRO + 1))
    else
      RESOLVED[NRES]=$p
      NRES=$((NRES + 1))
    fi
  done
}

# Refuse when an untracked or ignored worktree file sits at a path the resolved tree tracks.
# The untracked half is git merge's own rule; the ignored half is deliberately stricter,
# because land's read-tree -u --reset would otherwise remove it.
worktree_collision_check() {
  local sidx p rec
  : >"$td/collide"
  git -C "$top" ls-files -o --exclude-standard -z >"$td/collide" || die "ls-files -o failed"
  git -C "$top" ls-files -o -i --exclude-standard -z >>"$td/collide" || die "ls-files -o -i failed"
  [ -s "$td/collide" ] || return 0
  sidx="$td/idx"
  GIT_INDEX_FILE="$sidx" git -C "$top" read-tree "$1" || die "read-tree of the resolved tree failed"
  # Literal pathspecs of the untracked and ignored paths, NUL-delimited; ls-files takes no
  # --pathspec-from-file, so the list runs through xargs -0, which splits it at the argv limit
  # (GIT_INDEX_FILE passes through xargs' own environment to every ls-files it spawns).
  : >"$td/collidespecs"
  while IFS= read -r -d '' p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    printf ':(literal)%s\0' "$p" >>"$td/collidespecs"
  done <"$td/collide"
  : >"$td/hits"
  if [ -s "$td/collidespecs" ]; then
    GIT_INDEX_FILE="$sidx" xargs -0 git -C "$top" ls-files -z -- <"$td/collidespecs" >>"$td/hits" ||
      die "ls-files failed during the worktree-collision check"
  fi
  if [ ! -s "$td/hits" ]; then
    return 0
  fi
  p=
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    printf '%s: untracked or ignored file at a tracked path of the resolved tree: %s\n' "$APPLET" "$(quote_path "$rec")" >&2
    if [ -z "$p" ]; then p=$rec; fi
  done <"$td/hits"
  refuse "the resolved tree tracks $(quote_path "$p"), which is untracked or ignored in this checkout: move it, remove it, or track it, then re-run"
}

# Write the prepared merge state. MERGE_HEAD gets the hangar's verbatim id, so a signed tag's
# mergetag survives the finishing commit. MERGE_MSG is rendered fresh by fmt-merge-msg over a
# synthesized FETCH_HEAD line: the verbatim source id plus the recorded source-desc, in
# FETCH_HEAD's grammar. The message belongs to the git that creates the commit (the
# 'into <dst>' clause, merge.suppressDest, merge.log), so the hangar records the label and
# this git renders it. The message recorded at park time, when there is one, is appended as a
# comment block when it differs from the fresh render: advisory context in the editor,
# stripped like any comment (a --no-edit commit keeps it, as it keeps git's own comments).
# HEAD is on <dst> at the call, so that clause names <dst>.
write_merge_state() {
  local tip srcv srcdesc mh mf char line
  tip=$1
  srcv=$2
  srcdesc=$3
  mh=$(gitpath MERGE_HEAD)
  mf=$(gitpath MERGE_MSG)
  rm -f "$mh" "$mf"
  printf '%s\n' "$srcv" >"$mh"
  printf '%s\t\t%s\n' "$srcv" "$srcdesc" >"$td/fetchhead"
  git -C "$top" fmt-merge-msg <"$td/fetchhead" >"$td/rendered" ||
    die "git fmt-merge-msg failed rendering the merge message"
  git -C "$top" stripspace <"$td/rendered" >"$mf" || die "git stripspace failed"
  # The recorded message is advisory: absent means none, and the fresh render is the message.
  if git -C "$top" cat-file blob "$tip:$HANGAR/message" >"$td/recorded" 2>/dev/null; then
    git -C "$top" stripspace <"$td/recorded" >"$td/recorded-s" || die "git stripspace failed"
    if [ -s "$td/recorded-s" ] && ! cmp -s "$td/recorded-s" "$mf"; then
      char=$(git -C "$top" config core.commentChar 2>/dev/null || true)
      case $char in
      '' | auto) char='#' ;;
      esac
      {
        printf '\n%s Message recorded at park:\n' "$char"
        while IFS= read -r line || [ -n "$line" ]; do
          if [ -n "$line" ]; then
            printf '%s %s\n' "$char" "$line"
          else
            printf '%s\n' "$char"
          fi
        done <"$td/recorded-s"
      } >>"$mf"
    fi
  fi
}

# ------------------------------------------------------------------ dispatch

prog=$(basename "$0")
case $prog in
git-park)
  APPLET=park
  USAGE='git park [--branch <carrier-branch>]'
  park_main "$@"
  ;;
git-unpark)
  APPLET=unpark
  USAGE='git unpark [<path>...]'
  unpark_main "$@"
  ;;
git-land)
  APPLET=land
  USAGE='git land [--amend] [--check] <dst>'
  land_main "$@"
  ;;
*)
  cat >&2 <<'GIT_CARRIER_EOF'
git-carrier: this file dispatches on the name it is invoked as.

The commands are:

  git park    park a merge stopped at conflicts onto a carrier branch
  git unpark  take held paths back out of the hangar
  git land    land the parked merge at HEAD

There is no "git carrier" command: git finds a git-<verb> command by exact
name on PATH, and the .bash suffix keeps this file from being one.

Install: link git-carrier.bash onto PATH as git-park, git-unpark, git-land.
GIT_CARRIER_EOF
  exit 129
  ;;
esac
