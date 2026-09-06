# mvclaude

Move a project folder on macOS and take everything Claude knows about it along.
One command. It looks at what exists and does only what is needed.

```sh
mvclaude [-y] <old_dir> <new_dir>
```

## What it detects and fixes

| Area | What is checked | What is done |
|------|-----------------|--------------|
| folder | old exists? new exists? same volume? | rename, cross-volume copy, finish a partial move, or nothing |
| Claude Code | `~/.claude/{projects,file-history,todos,shell-snapshots,debug}/<encoded>`, `~/.claude.json` entry, `~/.claude/history.jsonl` | move context dirs, rewrite paths |
| Cowork | Claude desktop app folder consents, spaces, session folder lists | rewrite paths (only if data exists and references the old path) |

It prints a plan first:

```
mvclaude: /Volumes/Thunder1/studio/code/studio-app
       -> /Users/rob/Library/CloudStorage/Dropbox-Dashing/Code/studio-app
  folder       move (different volume, rsync copy then remove)
  claude code  context: projects; ~/.claude.json entry: yes; history lines: 220
  cowork       nothing references the old path
```

Every step is idempotent. If anything fails, run the same command again.
It picks up where it stopped. Once everything is done it says `Nothing to do.`

## When it asks

- **Destination exists and does not look like a partial copy of the source.**
  A partial copy is one where the old folder holds only `.DS_Store` files, or
  every top-level entry of old already exists in new. Anything else needs a
  `y`, or `-y` on the command line.
- **Claude context already exists at the new path.** Choose clean, merge, or
  abort. Non-interactive runs abort unless `-y` (merge) is given.
- **Cowork references need updating and the Claude desktop app is running.**
  Quit the app, then re-run.

## Why moves across volumes used to fail

BSD `mv` between volumes copies the tree, then runs `rm -rf` on the source.
If Finder or Spotlight writes a `.DS_Store` into the source while the copy
runs, `rm` reports `Directory not empty`, `mv` exits 1, and nothing after it
happens. `mvclaude` uses `rsync -aH --remove-source-files` for cross-volume
moves, then deletes `.DS_Store` files and empty directories. Anything else
left behind is listed and the script exits 1 so you can fix it and re-run.
Same-volume moves are a single atomic rename. Hard links are kept. Extended
attributes are not copied across volumes (macOS ships openrsync, whose xattr
support is unreliable).

## Backups

`~/.claude/history.jsonl.bak-<stamp>`, `~/.claude.json.bak-<stamp>`,
`~/.mvclaude-backups/<stamp>/` (Cowork files).

## Tests

```sh
tests/selftest.sh                                        # same-volume
MVCLAUDE_TEST_XDEV=/Volumes/Thunder1 tests/selftest.sh   # plus cross-volume
```

Tests run against a throw-away `HOME`; your real Claude context is never touched.
