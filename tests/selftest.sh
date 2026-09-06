#!/bin/bash
# Self-test for mvclaude. Runs against a throw-away HOME so the real Claude
# context is never touched.
#
#   tests/selftest.sh                                   same-volume tests
#   MVCLAUDE_TEST_XDEV=/Volumes/Other tests/selftest.sh also cross-volume tests
#                                                       (needs a writable dir on
#                                                        another volume)
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
MVCLAUDE="$HERE/mvclaude"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mvclaude-test.XXXXXX")
trap 'rm -rf "$WORK"; [ -n "${XDEV_ROOT:-}" ] && rm -rf "$XDEV_ROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }
run()  { "$MVCLAUDE" "$@" > "$WORK/out.txt" 2>&1 < /dev/null; }   # non-interactive
enc()  { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

# Fake HOME with Claude Code context (+ optional Cowork data) for $1.
fake_home() {   # old [nocowork]
    local old="$1" e; e=$(enc "$old")
    export HOME="$WORK/home"; rm -rf "$HOME"; mkdir -p "$HOME/.claude/projects/$e" "$HOME/.claude/todos/$e"
    printf '{"cwd":"%s","x":1}\n{"cwd":"%s/sub"}\n' "$old" "$old" > "$HOME/.claude/projects/$e/s1.jsonl"
    printf '{"display":"hi","project":"%s"}\n{"display":"other","project":"%s2"}\n' "$old" "$old" > "$HOME/.claude/history.jsonl"
    printf '{"projects":{"%s":{"allowedTools":["Bash"]},"%s2":{"k":1}}}\n' "$old" "$old" > "$HOME/.claude.json"
    export MVCLAUDE_COWORK_DIR="$HOME/cowork"
    [ "${2:-}" = nocowork ] && return 0
    mkdir -p "$MVCLAUDE_COWORK_DIR/local-agent-mode-sessions/org/user"
    printf '{"userSelectedFolders":["%s"]}\n' "$old" > "$MVCLAUDE_COWORK_DIR/local-agent-mode-sessions/org/user/local_1.json"
    printf '{"grants":["%s2"]}\n' "$old" > "$MVCLAUDE_COWORK_DIR/claude_desktop_config.json"
}

# Source tree with a hard link, a symlink and a .DS_Store.
make_tree() {
    mkdir -p "$1/deep/deeper"; echo data > "$1/deep/deeper/file"; ln "$1/deep/deeper/file" "$1/deep/hardlink"
    ln -s deeper/file "$1/deep/symlink"; echo x > "$1/.DS_Store"; echo top > "$1/top.txt"
}

verify_moved() {   # old new
    local old="$1" new="$2" oe ne; oe=$(enc "$old"); ne=$(enc "$new")
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
    if [ -d "$MVCLAUDE_COWORK_DIR" ]; then
        check "cowork ref rewritten"    "grep -q '\"$new\"' '$MVCLAUDE_COWORK_DIR/local-agent-mode-sessions/org/user/local_1.json'"
        check "cowork sibling kept"     "grep -q '${old}2' '$MVCLAUDE_COWORK_DIR/claude_desktop_config.json'"
    fi
}

run_suite() {   # label src_root dst_root
    local label="$1" S="$2" D="$3" old new
    old="$S/proj"; new="$D/proj-moved"; mkdir -p "$S" "$D"

    echo "== $label: plain move (claude + cowork detected)"
    make_tree "$old"; fake_home "$old"
    run "$old" "$new" || { fail "exit"; cat "$WORK/out.txt"; }
    check "plan shows cowork refs"   "grep -q 'cowork       1 file(s)' '$WORK/out.txt'"
    verify_moved "$old" "$new"
    run "$old" "$new" || { fail "re-run exit"; cat "$WORK/out.txt"; }
    check "re-run: nothing to do"    "grep -q 'Nothing to do' '$WORK/out.txt'"
    rm -rf "$old" "$new"

    echo "== $label: plain move, cowork not installed"
    make_tree "$old"; fake_home "$old" nocowork
    run "$old" "$new" || { fail "exit"; cat "$WORK/out.txt"; }
    check "plan: cowork not installed" "grep -q 'cowork       not installed' '$WORK/out.txt'"
    verify_moved "$old" "$new"
    rm -rf "$old" "$new"

    echo "== $label: auto-resume after failed cross-volume mv (junk left in source)"
    make_tree "$old"; fake_home "$old"
    cp -a "$old" "$new"; find "$old" -type f -not -name .DS_Store -delete; find "$old" -type l -delete
    touch "$old/deep/.DS_Store" "$old/deep/deeper/.DS_Store"
    run "$old" "$new" || { fail "resume exit"; cat "$WORK/out.txt"; }
    check "plan: partial move"       "grep -q 'finish partial move' '$WORK/out.txt'"
    check "no -y needed"             "! grep -q 'Re-run with -y' '$WORK/out.txt'"
    check "old dir swept"            "[ ! -e '$old' ]"
    check "new intact"               "[ -f '$new/deep/deeper/file' ]"
    check "ctx moved on resume"      "[ -d '$HOME/.claude/projects/$(enc "$new")' ]"
    check "refs rewritten"           "grep -q '\"project\":\"$new\"' '$HOME/.claude/history.jsonl'"
    rm -rf "$old" "$new"

    echo "== $label: resume picks up a file added to the source after the copy"
    make_tree "$old"; fake_home "$old"
    cp -a "$old" "$new"; find "$old" -type f -delete; find "$old" -type l -delete; echo late > "$old/deep/late.txt"
    run "$old" "$new" || { fail "exit"; cat "$WORK/out.txt"; }
    check "late file moved, source swept"  "[ -f '$new/deep/late.txt' ] && [ ! -e '$old' ]"
    rm -rf "$old" "$new"

    echo "== $label: destination is an unrelated dir -> needs -y"
    make_tree "$old"; fake_home "$old"; mkdir -p "$new"; echo other > "$new/unrelated.txt"
    check "refuses non-interactively"  "! run '$old' '$new' && grep -q 'Re-run with -y' '$WORK/out.txt'"
    check "nothing touched"            "[ -f '$old/top.txt' ] && [ -d '$HOME/.claude/projects/$(enc "$old")' ]"
    run -y "$old" "$new" || { fail "-y exit"; cat "$WORK/out.txt"; }
    check "-y merges"                  "[ ! -e '$old' ] && [ -f '$new/top.txt' ] && [ -f '$new/unrelated.txt' ]"
    rm -rf "$old" "$new"

    echo "== $label: refs only (dir already moved)"
    make_tree "$new"; fake_home "$old"
    run "$old" "$new" || { fail "exit"; cat "$WORK/out.txt"; }
    check "plan: already moved"      "grep -q 'folder       already moved' '$WORK/out.txt'"
    verify_moved "$old" "$new"
    rm -rf "$new"

    echo "== $label: refs only, old path typed with wrong case"
    make_tree "$new"; fake_home "$old"
    run "$(echo "$old" | tr 'a-z' 'A-Z' | sed "s|^$(echo "$S" | tr 'a-z' 'A-Z')|$S|")" "$new" || { fail "exit"; cat "$WORK/out.txt"; }
    check "recovered recorded path"  "grep -q 'as recorded by Claude' '$WORK/out.txt' && grep -q '\"project\":\"$new\"' '$HOME/.claude/history.jsonl'"
    rm -rf "$new"

    echo "== $label: context conflict at destination"
    make_tree "$old"; fake_home "$old"; mkdir -p "$HOME/.claude/projects/$(enc "$new")"; echo '{}' > "$HOME/.claude/projects/$(enc "$new")/s0.jsonl"
    check "refuses non-interactively"  "! run '$old' '$new' && grep -q 'Aborted' '$WORK/out.txt'"
    check "folder untouched"           "[ -f '$old/top.txt' ]"
    run -y "$old" "$new" || { fail "-y exit"; cat "$WORK/out.txt"; }
    check "-y merges context"          "[ -f '$HOME/.claude/projects/$(enc "$new")/s0.jsonl' ] && [ -f '$HOME/.claude/projects/$(enc "$new")/s1.jsonl' ]"
    rm -rf "$old" "$new"
}

echo "== guards"
fake_home "$WORK/x"; mkdir -p "$WORK/g/a/inner"
check "dest inside source rejected"  "! run '$WORK/g/a' '$WORK/g/a/inner/b'"
check "same dir rejected"            "! run '$WORK/g/a' '$WORK/g/a'"
check "neither exists rejected"      "! run '$WORK/nope' '$WORK/nope2'"
check "bad flag rejected"            "! run --bogus a b"
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
