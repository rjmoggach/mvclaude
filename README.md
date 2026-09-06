# mvclaude

Move a project folder on macOS and take its Claude context with it.

| Script     | Moves the folder and updates                                   |
|------------|----------------------------------------------------------------|
| `mvclaude` | Claude Code (CLI): `~/.claude/projects/<encoded>`, `~/.claude.json`, `~/.claude/history.jsonl` |
| `mvcowork` | Cowork (Claude desktop app): folder consents, spaces, session folder lists |

## Usage

```sh
mvclaude <old_dir> <new_dir>
mvcowork <old_dir> <new_dir>        # quit the Claude desktop app first
```

## If a move stops part way

Re-run with `--resume`. It is safe to run as many times as needed.

```sh
mvclaude --resume <old_dir> <new_dir>
mvcowork --resume <old_dir> <new_dir>
```

`--resume` handles all three states:

- **old and new both exist**: copies what is still in old into new, removes old, then moves context and rewrites references.
- **only new exists**: the folder is already moved. Only context and references are updated.
- **old typed with the wrong case**: the exact path Claude recorded is recovered from `~/.claude.json`.

## Why moves across volumes used to fail

BSD `mv` between volumes copies the tree, then runs `rm -rf` on the source.
If Finder or Spotlight writes a `.DS_Store` into the source while the copy
runs, `rm` reports `Directory not empty`, `mv` exits 1, and the script stops
before any references are updated.

Both scripts now use `rsync -aH --remove-source-files` for cross-volume
moves, then delete `.DS_Store` files and empty directories. Anything else
left behind is listed and the script exits 1 so you can fix it and `--resume`.
Same-volume moves are still a single atomic rename. Hard links are kept.
Extended attributes are not copied across volumes (macOS ships openrsync,
whose xattr support is unreliable).

Backups: `~/.claude/history.jsonl.bak-<stamp>`, `~/.claude.json.bak-<stamp>`,
`~/.mvcowork-backups/<stamp>/`.

## Tests

```sh
tests/selftest.sh                                   # same-volume
MVCLAUDE_TEST_XDEV=/Volumes/Thunder1 tests/selftest.sh   # plus cross-volume
```

Tests run against a throw-away `HOME`; your real Claude context is never touched.
