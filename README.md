# git-carrier

Park a merge that stopped at conflicts. Land it later as a real merge.

A merge stopped at conflicts is state git cannot commit, push, or hand to anyone. The options git offers are resolve it now or drop it. git-carrier turns the stopped merge into ordinary history: the conflict state travels as commits on a carrier branch, so you can push the work, review it, hand it to a colleague or an agent, or simply sleep on it. When the work is done, `git land` prepares the landing and your own `git commit` records the real merge with two parents.

Three git extensions in one bash script, with no dependencies beyond git and standard Unix utilities:

- **git park** moves the stopped merge onto a carrier branch, storing the conflicted paths under a `.hangar` directory that travels as ordinary commits. The branch you were on stays untouched at its pre-merge commit.
- **git unpark** takes a parked path back out of the hangar. Unchanged, it reopens as the conflict git left, so `git mergetool` and your favorite IDE work as usual. Edited or deleted by hand, the working file is your resolution.
- **git land** stages the finished work from the carrier onto the destination and writes `MERGE_HEAD`. Your `git commit` finishes the merge.

## Why we built it

We maintain [Molly](https://github.com/mollyim/mollyim-android), a Signal client fork of Signal-Android, so upstream releases arrive as large merges into our tree. Those merges stop at conflicts, and upstream moves on while we work. git has no way to set a merge like that aside, push it, and resume it later, let alone split its resolution across the team. So we wrote a tool to fill the gap: the conflict resolution travels as ordinary history, so you can share, review, log, and diff it like any other branch.

## Requirements

- bash 3.2 or newer
- git 2.34 or newer

## Install

Clone the repository and symlink `git-carrier.bash` as `git-park`, `git-unpark`, and `git-land` on your `PATH`:

```sh
git clone https://github.com/git-carrier/git-carrier
cd git-carrier
mkdir -p ~/.local/bin
ln -s "$PWD/git-carrier.bash" ~/.local/bin/git-park
ln -s "$PWD/git-carrier.bash" ~/.local/bin/git-unpark
ln -s "$PWD/git-carrier.bash" ~/.local/bin/git-land

git park --version
```

Any `git-<name>` on `PATH` works as `git <name>`. If symlinks are unusable on the destination filesystem, copy the script to the three names instead. To upgrade later, run `git pull` in the clone. There is no `git carrier` command: only the three link names are commands.

## The workflow

A clean merge doesn't need this tool at all. Park the stopped one:

```sh
$ git switch main
$ git merge --no-ff v1.2.3
Auto-merging f.txt
CONFLICT (content): Merge conflict in f.txt
Automatic merge failed; fix conflicts and then commit the result.

$ git park --branch carrier/v1.2.3
park: 1 path parked into .hangar on carrier/v1.2.3; the hangar is staged
park: main stays at 69a1f2c; land there later with: git land main
park: run 'git commit' to create the parked commit (--no-verify if a pre-commit hook rejects the conflict-marker content)

$ git commit -m 'park(main): merge v1.2.3'  # the parked merge begins; noting the destination in the message is optional
$ git push origin v1.2.3                    # publish the recorded source too
$ git push -u origin carrier/v1.2.3         # ordinary history: review, hand off
```

- Park moves the stopped merge onto the carrier without recreating it, and `main` stays untouched at its pre-merge commit.
- Park never commits. Your next `git commit` creates the parked commit.
- The hangar never records the destination, so say it where people will read it: the park commit's message, the handoff, or both.
- Push the ref the merge came from (the tag, the branch) along with the carrier.
- Park warns when the merge's source has no tag or remote-tracking branch: "a landing in another clone will need it fetched by name". Push a branch or a tag at the source before handing the carrier over.

Later, anywhere (a colleague's or an agent's fresh clone included):

```sh
$ git fetch origin
$ git switch --track origin/carrier/v1.2.3
$ git unpark -- f.txt
unpark: unchanged (reopened): f.txt
unpark: 1 path taken out of the hangar; 1 path reopened; 0 resolutions released

$ $EDITOR f.txt                     # or git mergetool
$ git add -- f.txt
$ git commit -m 'resolve: f.txt'
$ git push
```

- Unpark compares the working file with the stored one, content and mode both.
- Unchanged: the conflict is restored into the index, as git left it.
- Changed in content or mode, or deleted: no conflict is recreated. The working file is your resolution, left unstaged for review.
- Either way the path is released from the hangar.
- You can also work the hangar by hand: fix the file, `git add -- <path>`, release it with `git rm -r .hangar/stages/<path>`, and commit.

Once every path is released, check that the merge is ready, then land and commit:

```sh
$ git land --check main
land: check: ready to land MERGE_HEAD (4c8e07b) from carrier/v1.2.3 onto main (69a1f2c); nothing changed

$ git land main
land: prepared the landing on main (69a1f2c): resolutions staged, MERGE_HEAD written (4c8e07b)
land: the merge work stays on carrier/v1.2.3; run 'git commit' to finish the merge

$ git commit                # the real merge: two parents
```

- The hangar itself never lands: the final tree is the work tree minus `.hangar`, so no hangar content leaks into the destination's history.
- Re-running `git land main` once the merge has landed reports `this merge already landed` and exits 0.
- Run land from the carrier branch. Standing on the destination, land refuses (`HEAD is not a parked merge`).

Use `-h` with any command to see its help text and available flags.

## The hangar format

The hangar is host-independent: it holds blobs and bytes, resolves no reference name, and records no destination, so every byte of a hangar means the same thing in every clone. A path is released by deleting its `stages/<path>/` directory, and that deletion is the resolution record, so an ordinary diff review shows the work. The format is specified in [docs/hangar-format.txt](docs/hangar-format.txt).

## Handing the work to an agent

The tool is useful for agent workflows: an agent resolves the assigned paths with plain git, and the human who approves the merge keeps `git land`. The agent does not need git-carrier installed: the hangar format description is all it needs beyond plain git. The agent does not need push access to the destination branch and should not be authorized to land the parked merge. Give each agent a clean clone or worktree and this protocol:

1. Fetch and switch to the assigned carrier branch.
2. List the remaining work at HEAD with `git ls-tree -r --name-only HEAD -- .hangar/stages`. The paths still to resolve are the `stages/<path>/` directories.
3. Read the files present for the assigned path: `1` is the base, `2` is ours, `3` is theirs, and `w` is the working file where the merge stopped.
4. Write the resolution at the path, remove the `stages/<path>/` directory (the removal is the resolution record), and `git add` both.
5. Commit (`resolve: <path>`) and push the carrier. Never merge the carrier directly.
6. The approver runs `git land --check <dst>`, reviews the parked merge, runs `git land <dst>`, and finishes with their own `git commit`.

For parallel agents, branch each one from the same parked commit and assign disjoint paths, then merge the reviewed resolution branches back into the carrier. Carrier commits may not build, because conflict markers are carried by design, so exclude carrier branches from auto-merge and adjust CI where necessary.

## Caveats

- Park never commits. Until your `git commit`, the parked state lives only in the index and worktree. Commit right after parking.
- Parked commits carry conflict markers by design. Pre-commit hooks, push hooks, and hosting checks may reject them. Commit with `--no-verify` and configure the policies for carrier branches.
- The carrier is a handoff, never a contribution. Nobody merges `carrier/v1.2.3` into anything. The work arrives through `git land`.
- Unrelated unstaged changes stay out of the parked merge. `git add` a path before parking if it belongs in the merge.

## Related tools

- jj makes conflicts first-class committable state. If every team member runs jj, it is a good alternative. But a git collaborator cannot open a jj conflict.
- git-imerge records an incremental merge under `refs/imerge/<name>` and restructures it commit-pair by commit-pair.
- rerere remembers resolutions and replays them on the next merge. It is orthogonal to this tool, not an alternative: use them together.

## Background

In June 2020 the git mailing list discussed collaborative conflict resolution for a large merge. Junio C Hamano's [answer][junio] was that the real work is the data format "used for that task of passing from you to the other person", and Chris Torek [wrote out][torek] what that data holds: the unmerged stages per path, the working file, the merge's own context. The real fix, first-class conflicts in git itself (the way jj already does it), was [asked for][jj-conflicts] on the list in 2023 and discussed at the [2025 contributor summit][2025-summit]. At the summit Elijah Newren named the need this tool fills: to "divide and conquer when dealing with a massive merge conflict" and to "hand off conflict resolution to collaborators".

We designed this tool before we found that discussion, and the hangar format holds exactly those things. It was a happy convergence. Regardless, this tool is the meantime. When first-class conflicts land in git, we will write the deprecation notice gladly.

[junio]: https://lore.kernel.org/git/xmqq1rmgxo67.fsf@gitster.c.googlers.com/
[torek]: https://lore.kernel.org/git/CAPx1GvdT6sZRtu8q1R9=fA-mE9pi1Ag-gKEzQfwbGap+KqSoSg@mail.gmail.com/
[jj-conflicts]: https://lore.kernel.org/git/87cywmintp.fsf@ellen.idiomdrottning.org/
[2025-summit]: https://lore.kernel.org/git/aOQV%2Fja9Ltw%2FbTP3@nand.local/
