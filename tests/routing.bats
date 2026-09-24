# routing.bats: dispatch, help/version anywhere, the bare run's 129.

load helpers

setup() {
  setup_scratch
}

teardown() {
  teardown_scratch
}

@test "scratch bin: one file, three relative symlinks, on PATH" {
  ls -l "$CARRIER_BIN" | grep -q 'git-carrier.bash'
  for n in park unpark land; do
    [ "$(readlink "$CARRIER_BIN/git-$n")" = "git-carrier.bash" ] ||
      fail "git-$n is not a relative symlink to git-carrier.bash"
  done
}

@test "--version answers through git; --help answers by direct name" {
  cd "$CARRIER_WORK" # no .git anywhere above
  for verb in park unpark land; do
    # --version passes through git to the applet
    run git "$verb" --version
    [ "$status" -eq 0 ]
    assert_output "git-carrier 0.1.0 (hangar format 1)"
    # git intercepts `git <verb> --help` for man pages; the applets' --help is reached by the
    # invoked name directly
    run "git-$verb" --help
    [ "$status" -eq 0 ]
    assert_output --partial "usage: git $verb"
  done
}

@test "-h follows git's own convention: usage to stderr, exit 129" {
  cd "$CARRIER_WORK"
  run git park -h
  [ "$status" -eq 129 ]
  assert_output --partial "usage: git park"
  # -h is the help spelling that works through git, so it prints the full short help, not a pointer
  # to --help (git routes `git <verb> --help` to a man page this project does not ship)
  assert_output --partial -- "--branch <carrier-branch>"
  assert_output --partial "git land <dst>"
  case $output in
  *"see --help"*) fail "-h still points at --help" ;;
  esac
  run git-land -h
  [ "$status" -eq 129 ]
  assert_output --partial "usage: git land [--check] <dst>"
}

@test "a direct run prints the applet list and the install hint, exit 129" {
  run bash "$CARRIER_BIN/git-carrier.bash"
  [ "$status" -eq 129 ]
  assert_output --partial "git park"
  assert_output --partial "git unpark"
  assert_output --partial "git land"
  assert_output --partial "git-park, git-unpark, git-land"
}

@test "any other invoked basename is the same 129 bare run" {
  ln -s git-carrier.bash "$CARRIER_BIN/git-carrier"
  run "$CARRIER_BIN/git-carrier"
  [ "$status" -eq 129 ]
  assert_output --partial "dispatches on the name"
}

@test "git carrier is git's own unknown command, not ours" {
  mkrepo r2
  run git carrier
  [ "$status" -ne 0 ]
  assert_output --partial "is not a git command"
}
