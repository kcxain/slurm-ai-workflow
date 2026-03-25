# Local-Remote Development with Claude Code

A guide to developing on a local machine (e.g. Mac) while running Claude Code on a remote GPU machine (e.g. Linux). You edit code locally, Unison syncs files in real time, and Claude Code runs on the remote machine where it has access to GPUs for testing.

## Overview

```
Local (Mac)                          Remote (Linux GPU)
+-----------+    Unison (files)      +------------------+
|  Editor   | <===================> |  Claude Code     |
|           |    git push (history)  |  (under tmux)    |
+-----------+ ---------------------> +------------------+
              <---------------------
                git pull (commits)
```

Two sync layers:
- **Unison**: syncs working tree files in real time (ignores `.git`)
- **git push/pull**: syncs git history on demand

## Prerequisites

- SSH access to the remote machine (ideally with key-based auth and an SSH config alias)
- [Unison](https://github.com/bcpierce00/unison) installed on both machines (**versions must match exactly**)
- Git on both machines
- Claude Code installed on the remote machine

## Part 1: Unison File Sync

### Install Unison

```bash
# Mac (local)
brew install unison

# Linux (remote) — pick one:
sudo apt install unison        # if you have sudo
conda install -c conda-forge unison  # no sudo needed
# Or download a static binary from GitHub releases
```

Check versions match:

```bash
# Both machines
unison -version
```

### Create a Unison Profile

Create `~/.unison/<project>.prf` on your **local** machine:

```ini
# Roots: local path and remote path
root = /path/to/local/project
root = ssh://remote-host//path/to/remote/project

# Ignore dotfiles (including .git — important!)
ignore = Name .*

# Optionally allow specific dotfiles through:
# ignorenot = Name .github

# Ignore build artifacts, caches, etc.
ignore = Name __pycache__
ignore = Name *.pyc
ignore = Name node_modules

# Don't sync permissions (avoids issues between Mac/Linux)
perms = 0

# Prefer newer files on conflict
prefer = newer

# Propagate modification times
times = true

# Poll every 1 second for changes
repeat = 1

# Follow symlinks
follow = Name *
```

### Run Unison

```bash
# Start sync (runs continuously with repeat = 1)
unison <project>

# First run will ask about each file — press Enter to accept defaults
```

### Multiple Remotes

Copy the profile for each remote:

```bash
cp ~/.unison/myproject.prf ~/.unison/myproject-gpu2.prf
```

Edit the second root to point to the other machine.

## Part 2: Git History Sync

Unison syncs file contents but ignores `.git`. You need a separate mechanism to sync git history so that commits made by Claude Code on the remote can be pulled back locally.

### Setup (one-time)

**On local — add remote as a git remote:**

```bash
git remote add gpu ssh://remote-host/path/to/remote/project
```

**On remote — allow pushes to the checked-out branch:**

```bash
cd ~/project
git config receive.denyCurrentBranch warn
```

**On remote — create a post-receive hook:**

Create `~/project/.git/hooks/post-receive`:

```bash
#!/bin/sh
GIT_DIR=/path/to/remote/project/.git git reset HEAD 2>/dev/null
```

```bash
chmod +x ~/project/.git/hooks/post-receive
```

The `git reset HEAD` updates the index to match the new commits without touching working tree files (which Unison manages). Without this, the remote would show all Unison-synced files as unstaged changes.

### Workflow

```bash
# Push your local commits to the remote
git push gpu main

# Pull Claude's commits from the remote
git pull gpu main
```

`git push` only syncs commits — uncommitted file changes are handled by Unison.

## Part 3: Running Claude Code on the Remote

SSH into the remote machine, start a tmux session, then run Claude Code:

```bash
cd ~/project
claude --dangerously-skip-permissions
```

The tmux session keeps Claude alive even if your SSH connection drops. Reattach anytime to check on it.

## Git Worktrees (Optional)

If you work on multiple branches simultaneously, use git worktrees inside the project directory so Unison syncs them automatically.

### Setup

```bash
# Ignore worktrees in git
echo 'worktrees/' >> .gitignore

# Create a git alias that makes worktrees on all machines
git config alias.wa '!f() { git worktree add "$@" && ssh gpu "cd ~/project && git worktree add $@"; }; f'
```

### Usage

```bash
# Create a new branch in a worktree
git wa -b my-feature worktrees/feat main

# Push the branch to remote
git push gpu my-feature
```

Each worktree has its own branch. Commits go to that branch, not main. Merge back with `git merge` from the main worktree.

## Quick Reference

| Action | Command |
|--------|---------|
| Start Unison sync | `unison myproject` |
| Push commits to remote | `git push gpu main` |
| Pull Claude's commits | `git pull gpu main` |
| Start remote Claude (tmux) | `ssh gpu 'tmux new -s claude "cd ~/project && claude"'` |
| Attach to remote Claude | `ssh -t gpu 'tmux attach -t claude'` |
