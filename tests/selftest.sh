#!/bin/bash
# Self-test for mvclaude / mvcowork. Runs against a throw-away HOME so the real
# Claude context is never touched.
#
#   tests/selftest.sh                         same-volume tests only
#   MVCLAUDE_TEST_XDEV=/Volumes/Other tests/selftest.sh
#                                             also run cross-volume tests
#                                             (needs a writable dir on
#                                             another volume)
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
MVCLAUDE="$HERE/mvclaude"
MVCOWORK="$HERE/mvcowork"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mvclaude-test.XXXXXX")
trap 'rm -rf "$WORK"; [ -n "${XDEV_ROOT:-}" ] && rm -rf "$XDEV_ROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

enc() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

# Build a fake HOME with Claude context for $1 (absolute path).
fake_home() {
    local old="$1" e
    e=$(enc "$old")
    export HOME="$WORK/home"; rm -rf "$HOME"; mkdir -p "$HOME/.claude/projects/$e" "$HOME/.claude/todos/$e"
    printf '{"cwd":"%s","x":1}\n{"cwd":"%s/sub"}\n' "$old" "$old" > "$HOME/.claude/projects/$e/s1.jsonl"
    printf '{"display":"hi","project":"%s"}\n{"display":"other","project":"%s2"}\n' "$old" "$old" > "$HOME/.claude/history.jsonl"
    printf '{"projects":{"%s":{"allowedTools":["Bash"]},"%s2":{"k":1}}}\n' "$old" "$old" > "$HOME/.claude.json"
    # Cowork data
    export MVCOWORK_APP_DIR="$HOME/cowork"; mkdir -p "$MVCOWORK_APP_DIR/local-agent-mode-sessions/org/user"
    printf '{"userSelectedFolders":["%s"]}\n' "$old" > "$MVCOWORK_APP_DIR/local-agent-mode-sessions/org/user/local_1.json"
    printf '{"grants":["%s2"]}\n' "$old" > "$MVCOWORK_APP_DIR/claude_desktop_config.json"
}

# Build a source tree at $1 with a hard link, a symlink and a .DS_Store.
make_tree() {
    mkdir -p "$1/deep/deeper"; echo data > "$1/deep/deeper/file"; ln "$1/deep/deeper/file" "$1/deep/hardlink"
    ln -s deeper/file "$1/deep/symlink"; echo x > "$1/.DS_Store"; echo top > "$1/top.txt"
}

verify_moved() {   # old new
    local old="$1" new="$2" oe ne
    oe=$(enc "$old"); ne=$(enc "$new")
    check "old dir gone"            "[ ! -e '$old' ]"
    check "files at new"            "[ -f '$new/deep/deeper/file' ] && [ -f '$new/top.txt' ]"
    check "hard link kept"          "[ \$(stat -f %l '$new/deep/hardlink') -eq 2 ]"
    check "symlink kept"            "[ \$(readlink '$new/deep/symlink') = deeper/file ]"
    check "projects ctx moved"      "[ -d '$HOME/.claude/projects/$ne' ] && [ ! -e '$HOME/.claude/projects/$oe' ]"
    check "todos ctx moved"         "[ -d '$HOME/.claude/todos/$ne' ]"
    check "session rewritten"       "grep -q '\"cwd\":\"$new/sub\"' '$HOME/.claude/projects/$ne/s1.jsonl' && ! grep -q '$old' '$HOME/.claude/projects/$ne/s1.jsonl'"
    check "history rewritten"       "grep -q '\"project\":\"$new\"' '$HOME/.claude/history.jsonl'"
    check "history sibling kept"    "grep -q '\"project\":\"${old}2\"' '$HOME/.claude/history.jsonl'"
    check "claude.json key moved"   "python3 -c \"import json,sys;p=json.load(open('$HOME/.claude.json'))['projects'];sys.exit(0 if '$new' in p and '$old' not in p and '${old}2' in p else 1)\""
}

run_suite() {   # label src_root dst_root
    local label="$1" S="$2" D="$3" old new
    echo "== $label: plain move"
    old="$S/proj"; new="$D/proj-moved"; mkdir -p "$S" "$D"; make_tree "$old"; fake_home "$old"
    "$MVCLAUDE" "$old" "$new" > "$WORK/out.txt" 2>&1 || { fail "mvclaude exit"; cat "$WORK/out.txt"; }
    verify_moved "$old" "$new"
    check "idempotent re-run (--resume)" "'$MVCLAUDE' --resume '$old' '$new' >/dev/null 2>&1"
    rm -rf "$old" "$new"

    echo "== $label: resume after failed cross-volume mv (junk left in source)"
    old="$S/proj"; new="$D/proj-moved"; make_tree "$old"; fake_home "$old"
    # simulate: copy done, source emptied except .DS_Store files
    cp -a "$old" "$new"; find "$old" -type f -not -name .DS_Store -delete; find "$old" -type l -delete
    touch "$old/deep/.DS_Store" "$old/deep/deeper/.DS_Store"
    check "refuses without --resume" "! '$MVCLAUDE' '$old' '$new' >/dev/null 2>&1"
    check "old context untouched"  "[ -d '$HOME/.claude/projects/$(enc "$old")' ]"
    "$MVCLAUDE" --resume "$old" "$new" > "$WORK/out.txt" 2>&1 || { fail "resume exit"; cat "$WORK/out.txt"; }
    check "old dir swept"          "[ ! -e '$old' ]"
    check "new intact"             "[ -f '$new/deep/deeper/file' ]"
    check "ctx moved on resume"    "[ -d '$HOME/.claude/projects/$(enc "$new")' ]"
    check "refs rewritten"         "grep -q '\"project\":\"$new\"' '$HOME/.claude/history.jsonl'"
    rm -rf "$old" "$new"

    echo "== $label: resume picks up a file added to the source after the copy"
    old="$S/proj"; new="$D/proj-moved"; make_tree "$old"; fake_home "$old"
    cp -a "$old" "$new"; find "$old" -type f -delete; find "$old" -type l -delete; echo late > "$old/deep/late.txt"
    "$MVCLAUDE" --resume "$old" "$new" > "$WORK/out.txt" 2>&1
    check "late file moved, source swept"  "[ -f '$new/deep/late.txt' ] && [ ! -e '$old' ]"
    rm -rf "$old" "$new"

    echo "== $label: refs only (dir already moved)"
    old="$S/proj"; new="$D/proj-moved"; make_tree "$new"; fake_home "$old"
    "$MVCLAUDE" --resume "$old" "$new" > "$WORK/out.txt" 2>&1 || { fail "refs-only exit"; cat "$WORK/out.txt"; }
    verify_moved "$old" "$new"
    rm -rf "$new"

    echo "== $label: refs only, old path typed with wrong case"
    old="$S/proj"; new="$D/proj-moved"; make_tree "$new"; fake_home "$old"
    "$MVCLAUDE" --resume "$(echo "$old" | tr 'a-z' 'A-Z' | sed "s|^$(echo "$S" | tr 'a-z' 'A-Z')|$S|")" "$new" > "$WORK/out.txt" 2>&1 || { fail "wrong-case exit"; cat "$WORK/out.txt"; }
    check "recovered recorded path"  "grep -q 'as recorded by Claude' '$WORK/out.txt' && grep -q '\"project\":\"$new\"' '$HOME/.claude/history.jsonl'"
    rm -rf "$new"

    echo "== $label: mvcowork move + resume"
    old="$S/proj"; new="$D/proj-moved"; make_tree "$old"; fake_home "$old"
    "$MVCOWORK" "$old" "$new" > "$WORK/out.txt" 2>&1 || { fail "mvcowork exit"; cat "$WORK/out.txt"; }
    check "cowork: dir moved"        "[ ! -e '$old' ] && [ -f '$new/deep/deeper/file' ]"
    check "cowork: ref rewritten"    "grep -q '\"$new\"' '$MVCOWORK_APP_DIR/local-agent-mode-sessions/org/user/local_1.json'"
    check "cowork: sibling kept"     "grep -q '${old}2' '$MVCOWORK_APP_DIR/claude_desktop_config.json'"
    check "cowork: --refs-only alias" "'$MVCOWORK' --refs-only '$old' '$new' >/dev/null 2>&1"
    rm -rf "$old" "$new"
}

echo "== guards"
fake_home "$WORK/x"; mkdir -p "$WORK/g/a/inner"
check "dest inside source rejected"  "! '$MVCLAUDE' '$WORK/g/a' '$WORK/g/a/inner/b' >/dev/null 2>&1"
check "same dir rejected"            "! '$MVCLAUDE' '$WORK/g/a' '$WORK/g/a' >/dev/null 2>&1"
check "missing old rejected"         "! '$MVCLAUDE' '$WORK/nope' '$WORK/g/b' >/dev/null 2>&1"
check "resume with nothing rejected" "! '$MVCLAUDE' --resume '$WORK/nope' '$WORK/nope2' >/dev/null 2>&1"
check "bad flag rejected"            "! '$MVCLAUDE' --bogus a b >/dev/null 2>&1"
check "source tree untouched"        "[ -d '$WORK/g/a/inner' ]"

run_suite "same-volume" "$WORK/src" "$WORK/dst"

if [ -n "${MVCLAUDE_TEST_XDEV:-}" ]; then
    XDEV_ROOT=$(mktemp -d "$MVCLAUDE_TEST_XDEV/mvclaude-test.XXXXXX")
    if [ "$(stat -f %d "$XDEV_ROOT")" = "$(stat -f %d "$WORK")" ]; then
        echo "MVCLAUDE_TEST_XDEV is on the same volume as TMPDIR; cross-volume tests skipped"
    else
        run_suite "cross-volume" "$XDEV_ROOT/src" "$WORK/dst"
    fi
else
    echo "(set MVCLAUDE_TEST_XDEV=/Volumes/Other to run cross-volume tests)"
fi

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
