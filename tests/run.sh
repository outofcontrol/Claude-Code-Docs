#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 OutofControl
# SPDX-License-Identifier: Apache-2.0 OR MIT
#
# Test suite for claude-docs-watch. No network access and no dependencies
# beyond bash, git and curl. The script under test runs with the same bash
# that runs this file, so "/bin/bash tests/run.sh" covers bash 3.2 on macOS.
#
# Usage: tests/run.sh [test_name ...]

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
SCRIPT="$ROOT/bin/claude-docs-watch"
ORIGINAL_PATH=$PATH
REAL_CURL=$(command -v curl)
export REAL_CURL

SUITE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cdw-tests.XXXXXX")
trap 'rm -rf -- "$SUITE_DIR"' EXIT

T=""
STATUS=0
CURRENT_FAILED=0
TESTS_RUN=0
TESTS_FAILED=0

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

fail() {
    CURRENT_FAILED=1
    printf '    FAIL: %s\n' "$*"
}

assert_eq() {
    [[ $1 == "$2" ]] || fail "${3:-values differ}: expected [$1], got [$2]"
}

assert_status() {
    [[ $STATUS == "$1" ]] || fail "expected exit status $1, got $STATUS (stderr: $(cat "$T/err"))"
}

assert_file_contains() {
    grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 does not contain [$2]: $(cat "$1" 2>&1)"
}

assert_file_lacks() {
    ! grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 contains [$2]"
}

assert_exists() {
    [[ -e $1 ]] || fail "missing: $1"
}

assert_missing() {
    [[ ! -e $1 ]] || fail "unexpected: $1"
}

# Number of recorded invocations of a stubbed command.
calls() {
    find "$STUB_LOG" -name "$1.*.args" | wc -l | tr -d ' '
}

commits() {
    git -C "$CDW_REPO_DIR" rev-list --count HEAD
}

run_cdw() {
    "$BASH" "$SCRIPT" "$@" >"$T/out" 2>"$T/err" </dev/null
    STATUS=$?
}

write_stub() {
    cat >"$STUB_DIR/$1" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$0")
if [[ $name == curl ]]; then
    for arg in "$@"; do
        case $arg in file://*) exec "$REAL_CURL" "$@" ;; esac
    done
fi
n=$(($(find "$STUB_LOG" -name "$name.*.args" | wc -l) + 1))
printf '%s\n' "$@" >"$STUB_LOG/$name.$n.args"
cat >"$STUB_LOG/$name.$n.stdin"
previous=""
for arg in "$@"; do
    case $previous in
        --data-binary | --upload-file) cp "${arg#@}" "$STUB_LOG/$name.$n.data" ;;
    esac
    previous=$arg
done
if [[ -n ${STUB_FAIL_MATCH:-} ]] && grep -qF -- "$STUB_FAIL_MATCH" "$STUB_LOG/$name.$n.stdin"; then
    echo "$name: stub failure" >&2
    exit 22
fi
exit 0
EOF
    chmod +x "$STUB_DIR/$1"
}

write_doc() {
    cat >"$T/src/llms-full.txt"
}

base_doc() {
    write_doc <<'EOF'
# Alpha
Source: https://example.test/docs/alpha

Alpha line one.
Alpha line two.


# Beta
Source: https://example.test/docs/beta

Beta line one.


# Gamma
Source: https://example.test/docs/gamma

Gamma line one.
EOF
}

# Replace text in the source document: edit_doc 's/old/new/'
edit_doc() {
    sed "$1" "$T/src/llms-full.txt" >"$T/src/edited"
    mv "$T/src/edited" "$T/src/llms-full.txt"
}

setup() {
    local name
    T="$SUITE_DIR/$1"
    mkdir -p "$T/home" "$T/src" "$T/stubs" "$T/log"
    for name in ${!CDW_@} ${!XDG_@} STUB_FAIL_MATCH; do
        unset "$name"
    done
    export HOME="$T/home"
    export STUB_DIR="$T/stubs" STUB_LOG="$T/log"
    export PATH="$STUB_DIR:$ORIGINAL_PATH"
    export CDW_REPO_DIR="$T/repo"
    export CDW_URL="file://$T/src/llms-full.txt"
    export CDW_MIN_BYTES=1
    for name in curl sendmail terminal-notifier osascript notify-send; do
        write_stub "$name"
    done
    base_doc
}

use_ntfy() {
    export CDW_NOTIFY=ntfy CDW_NTFY_URL=https://ntfy.example.test/ CDW_NTFY_TOPIC=docs CDW_NTFY_ATTACH=0
}

# ---------------------------------------------------------------------------
# Tracking
# ---------------------------------------------------------------------------

test_first_run_records_baseline_without_notifying() {
    use_ntfy
    run_cdw
    assert_status 0
    assert_eq 1 "$(commits)" "commit count"
    assert_eq 0 "$(calls curl)" "notifications"
    assert_file_contains "$T/out" "Baseline recorded"
    assert_eq main "$(git -C "$CDW_REPO_DIR" symbolic-ref --short HEAD)" "branch"
}

test_unchanged_document_creates_no_commit() {
    use_ntfy
    run_cdw
    run_cdw
    assert_status 0
    assert_eq 1 "$(commits)" "commit count"
    assert_eq 0 "$(calls curl)" "notifications"
    assert_file_contains "$T/out" "No change."
}

test_change_is_committed() {
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_eq 2 "$(commits)" "commit count"
    assert_file_contains "$CDW_REPO_DIR/llms-full.txt" "Alpha line 1."
    assert_eq "" "$(git -C "$CDW_REPO_DIR" status --porcelain)" "work tree"
}

test_quiet_prints_nothing_on_success() {
    run_cdw --quiet
    assert_status 0
    assert_eq "" "$(cat "$T/out" "$T/err")" "output"
}

test_user_git_config_does_not_apply() {
    git config --file "$HOME/.gitconfig" commit.gpgsign true
    git config --file "$HOME/.gitconfig" user.signingkey nonexistent
    git config --file "$HOME/.gitconfig" core.hooksPath "$T/hooks"
    mkdir -p "$T/hooks"
    printf '#!/bin/sh\nexit 1\n' >"$T/hooks/pre-commit"
    chmod +x "$T/hooks/pre-commit"
    run_cdw
    assert_status 0
    assert_eq 1 "$(commits)" "commit count"
    assert_eq claude-docs-watch "$(git -C "$CDW_REPO_DIR" log -1 --format=%an)" "author"
}

test_history_is_packed() {
    local i
    run_cdw
    for i in 1 2 3 4 5 6 7 8; do
        edit_doc "s/^Gamma line.*/Gamma line $i./"
        run_cdw
    done
    assert_status 0
    assert_eq 9 "$(commits)" "commit count"
    assert_eq 1 "$(find "$CDW_REPO_DIR/.git/objects/pack" -name '*.pack' | wc -l | tr -d ' ')" "pack files"
}

test_fetch_failure_exits_1_and_keeps_history() {
    use_ntfy
    run_cdw
    rm "$T/src/llms-full.txt"
    run_cdw
    assert_status 1
    assert_file_contains "$T/err" "fetch failed"
    assert_eq 1 "$(commits)" "commit count"
    assert_eq 0 "$(calls curl)" "notifications"
    assert_missing "$CDW_REPO_DIR/.git/claude-docs-watch.lock"
}

test_short_response_is_rejected() {
    run_cdw
    printf 'oops\n' | write_doc
    export CDW_MIN_BYTES=100
    run_cdw
    assert_status 1
    assert_file_contains "$T/err" "below CDW_MIN_BYTES"
    assert_eq 1 "$(commits)" "commit count"
}

test_live_lock_blocks_run() {
    run_cdw
    mkdir "$CDW_REPO_DIR/.git/claude-docs-watch.lock"
    echo $$ >"$CDW_REPO_DIR/.git/claude-docs-watch.lock/pid"
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 1
    assert_file_contains "$T/err" "another run is in progress"
    assert_eq 1 "$(commits)" "commit count"
    assert_exists "$CDW_REPO_DIR/.git/claude-docs-watch.lock"
}

test_stale_lock_is_replaced() {
    local dead_pid
    run_cdw
    (exit 0) &
    dead_pid=$!
    wait "$dead_pid"
    mkdir "$CDW_REPO_DIR/.git/claude-docs-watch.lock"
    echo "$dead_pid" >"$CDW_REPO_DIR/.git/claude-docs-watch.lock/pid"
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_eq 2 "$(commits)" "commit count"
    assert_missing "$CDW_REPO_DIR/.git/claude-docs-watch.lock"
}

# ---------------------------------------------------------------------------
# Change summary
# ---------------------------------------------------------------------------

test_summary_lists_changed_added_removed_pages() {
    use_ntfy
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    edit_doc '/^# Beta/,/^Beta line one/d'
    printf '\n\n# Delta\nSource: https://example.test/docs/delta\n\nDelta line one.\n' >>"$T/src/llms-full.txt"
    run_cdw
    assert_status 0
    assert_eq "Pages: 1 changed, 1 added, 1 removed. Lines: +7 -5.
* docs/alpha
  + Alpha line 1.
  - Alpha line one.
+ docs/delta (new page)
- docs/beta (removed)" "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

test_title_line_belongs_to_the_page_below_it() {
    use_ntfy
    run_cdw
    edit_doc 's/^# Beta$/# Beta renamed/'
    run_cdw
    assert_eq "Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1.
* docs/beta
  + # Beta renamed" "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

test_deleted_lines_are_attributed_to_their_page() {
    use_ntfy
    run_cdw
    edit_doc '/^Alpha line two/d'
    run_cdw
    assert_eq "Pages: 1 changed, 0 added, 0 removed. Lines: +0 -1.
* docs/alpha
  - Alpha line two." "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

test_page_list_is_capped() {
    use_ntfy
    export CDW_MAX_PAGES=2
    run_cdw
    edit_doc 's/line one/line 1/'
    run_cdw
    assert_eq "Pages: 3 changed, 0 added, 0 removed. Lines: +3 -3.
* docs/alpha
  + Alpha line 1.
  - Alpha line one.
* docs/beta
  + Beta line 1.
  - Beta line one.
(and 1 more)" "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

test_empty_section_prefix_reports_lines_only() {
    use_ntfy
    export CDW_SECTION_PREFIX=""
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_eq "Lines: +1 -1." "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

# ---------------------------------------------------------------------------
# Page files
# ---------------------------------------------------------------------------

# A document whose page URLs sit below the directory of CDW_URL, with links
# between pages. SITE is the path part of those URLs.
linked_doc() {
    SITE="$T/src"
    write_doc <<EOF
# Alpha
Source: file://$SITE/en/alpha

Alpha text with [Beta]($SITE/en/beta#setup) and [missing]($SITE/en/missing).

\`\`\`sh
# not a page heading
echo hi
\`\`\`


# Beta [draft]
Source: file://$SITE/en/beta

<Card href="$SITE/en/sdk/deep">Deep</Card>
![logo](//cdn.example.test/logo.png) [external](https://example.test/x)


# Deep
Source: file://$SITE/en/sdk/deep

Back to [Alpha]($SITE/en/alpha/).
EOF
}

tracked_pages() {
    git -C "$CDW_REPO_DIR" ls-files -- "${1:-docs}"
}

test_pages_are_split_with_a_root_page() {
    linked_doc
    run_cdw
    assert_status 0
    assert_eq "docs/en/alpha.md
docs/en/beta.md
docs/en/sdk/deep.md
docs/index.md" "$(tracked_pages)" "tracked files"
    assert_eq "" "$(git -C "$CDW_REPO_DIR" status --porcelain)" "work tree"
    assert_eq "# Alpha
Source: file://$SITE/en/alpha

Alpha text with [Beta](../en/beta.md#setup) and [missing](file://$SITE/en/missing).

\`\`\`sh
# not a page heading
echo hi
\`\`\`" "$(cat "$CDW_REPO_DIR/docs/en/alpha.md")" "alpha page"
    assert_eq "# Documentation index

3 pages from <$CDW_URL>.

[Change history](../changes/index.html)

## en

* [Alpha](en/alpha.md)
* [Beta \\[draft\\]](en/beta.md)

## en/sdk

* [Deep](en/sdk/deep.md)" "$(cat "$CDW_REPO_DIR/docs/index.md")" "root page"
    assert_eq 9 "$(wc -l <"$CDW_REPO_DIR/docs/en/alpha.md" | tr -d ' ')" "alpha line count"
}

test_page_links_are_rewritten() {
    linked_doc
    run_cdw
    assert_file_contains "$CDW_REPO_DIR/docs/en/beta.md" '<Card href="../en/sdk/deep.md">Deep</Card>'
    assert_file_contains "$CDW_REPO_DIR/docs/en/beta.md" '![logo](//cdn.example.test/logo.png) [external](https://example.test/x)'
    assert_file_contains "$CDW_REPO_DIR/docs/en/sdk/deep.md" 'Back to [Alpha](../../en/alpha.md).'
    assert_file_contains "$CDW_REPO_DIR/llms-full.txt" "[Beta]($SITE/en/beta#setup)"
}

test_custom_pages_directory() {
    export CDW_DOCS_DIR=pages
    run_cdw
    assert_exists "$CDW_REPO_DIR/pages/index.md"
    assert_exists "$CDW_REPO_DIR/pages/docs/alpha.md"
    assert_missing "$CDW_REPO_DIR/docs"
}

test_pages_follow_added_and_removed_pages() {
    use_ntfy
    run_cdw
    assert_exists "$CDW_REPO_DIR/docs/docs/beta.md"
    edit_doc '/^# Beta/,/^Beta line one/d'
    printf '\n\n# Delta\nSource: https://example.test/docs/delta\n\nDelta line one.\n' >>"$T/src/llms-full.txt"
    run_cdw
    assert_status 0
    assert_eq "docs/docs/alpha.md
docs/docs/delta.md
docs/docs/gamma.md
docs/index.md" "$(tracked_pages)" "tracked files"
    assert_missing "$CDW_REPO_DIR/docs/docs/beta.md"
    assert_file_lacks "$CDW_REPO_DIR/docs/index.md" "Beta"
    assert_file_contains "$CDW_REPO_DIR/docs/index.md" "* [Delta](docs/delta.md)"
    assert_eq 2 "$(commits)" "commit count"
    assert_eq 1 "$(calls curl)" "notifications"
    assert_eq "" "$(git -C "$CDW_REPO_DIR" status --porcelain)" "work tree"
}

test_page_paths_are_sanitized_and_unique() {
    write_doc <<'EOF'
# Escape
Source: https://example.test/../../etc/passwd

One.

# Spaces
Source: https://example.test/a b/Page?x=1#frag

Two.

# Same name in another case
Source: https://example.test/a_b/page

Three.

# Index
Source: https://example.test/index

Four.

# Hidden
Source: https://example.test/.hidden/-x

Five.

# No path
Source: https://example.test/

Six.
EOF
    run_cdw
    assert_status 0
    assert_eq "docs/a_b/Page.md
docs/a_b/page-2.md
docs/etc/passwd.md
docs/hidden/x.md
docs/index-2.md
docs/index.md
docs/page.md" "$(tracked_pages | LC_ALL=C sort)" "tracked files"
    assert_eq "$CDW_REPO_DIR/docs/etc/passwd.md" "$(find "$T" -name 'passwd*')" "passwd files"
    assert_file_contains "$CDW_REPO_DIR/docs/a_b/page-2.md" "Three."
}

test_enabling_pages_on_an_existing_repository_sends_nothing() {
    use_ntfy
    export CDW_DOCS_DIR=""
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_eq 1 "$(calls curl)" "notifications before"
    assert_missing "$CDW_REPO_DIR/docs"

    unset CDW_DOCS_DIR
    run_cdw
    assert_status 0
    assert_eq 3 "$(commits)" "commit count"
    assert_file_contains "$T/out" "Pages rebuilt"
    assert_exists "$CDW_REPO_DIR/docs/index.md"
    assert_eq 1 "$(calls curl)" "notifications after rebuild"

    edit_doc 's/Beta line one/Beta line 1/'
    run_cdw
    assert_eq 2 "$(calls curl)" "notifications after change"
    assert_eq "Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1.
* docs/beta
  + Beta line 1.
  - Beta line one." "$(cat "$STUB_LOG/curl.2.data")" "summary"
}

test_empty_docs_dir_disables_pages() {
    export CDW_DOCS_DIR=""
    run_cdw
    assert_status 0
    assert_eq "llms-full.txt" "$(git -C "$CDW_REPO_DIR" ls-files)" "tracked files"
}

test_document_without_pages_keeps_existing_files() {
    run_cdw
    printf '# Only a heading\n\nNo section marker.\n' | write_doc
    run_cdw
    assert_status 0
    assert_file_contains "$T/err" "no pages found"
    assert_exists "$CDW_REPO_DIR/docs/docs/alpha.md"
    assert_eq 2 "$(commits)" "commit count"
}

test_deleted_page_file_is_restored() {
    run_cdw
    rm "$CDW_REPO_DIR/docs/docs/alpha.md" "$CDW_REPO_DIR/docs/index.md"
    run_cdw
    assert_status 0
    assert_exists "$CDW_REPO_DIR/docs/docs/alpha.md"
    assert_exists "$CDW_REPO_DIR/docs/index.md"
    assert_eq 1 "$(commits)" "commit count"
}

test_invalid_docs_dir_exits_2() {
    export CDW_DOCS_DIR=../outside
    run_cdw
    assert_status 2
    assert_file_contains "$T/err" "CDW_DOCS_DIR must be a plain directory name"
    export CDW_DOCS_DIR=llms-full.txt
    run_cdw
    assert_status 2
    assert_missing "$CDW_REPO_DIR"
}

# ---------------------------------------------------------------------------
# Channels
# ---------------------------------------------------------------------------

test_ntfy_request() {
    use_ntfy
    export CDW_NTFY_TOKEN=tk_secret CDW_NTFY_PRIORITY=high CDW_NTFY_TAGS=books,eyes
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_eq 1 "$(calls curl)" "notifications"
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'url = "https://ntfy.example.test/docs"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Title: Claude Code docs changed"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Priority: high"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Tags: books,eyes"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" "header = \"Click: $CDW_URL\""
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Authorization: Bearer tk_secret"'
    assert_file_contains "$STUB_LOG/curl.1.args" "--fail"
    assert_file_lacks "$STUB_LOG/curl.1.args" "tk_secret"
    assert_file_contains "$T/out" "Notified via ntfy."
}

test_ntfy_defaults_and_basic_auth() {
    export CDW_NOTIFY=ntfy CDW_NTFY_TOPIC=docs CDW_NTFY_USER=me CDW_NTFY_PASSWORD='p"w\d'
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'url = "https://ntfy.sh/docs"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Priority: default"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'user = "me:p\"w\\d"'
    assert_file_lacks "$STUB_LOG/curl.1.stdin" "Authorization"
}

test_non_ascii_title_is_rfc2047_encoded() {
    use_ntfy
    export CDW_NOTIFY=ntfy,email CDW_EMAIL_TO=a@example.test CDW_TITLE='Docs geändert'
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Title: =?UTF-8?B?RG9jcyBnZcOkbmRlcnQ=?="'
    assert_file_contains "$STUB_LOG/sendmail.1.stdin" 'Subject: =?UTF-8?B?RG9jcyBnZcOkbmRlcnQ=?='
}

test_slack_payload_is_valid_json() {
    export CDW_NOTIFY=slack CDW_SLACK_WEBHOOK_URL=https://hooks.slack.example.test/services/T/B/secret
    export CDW_TITLE='Docs "changed" <now> \ & then'
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'url = "https://hooks.slack.example.test/services/T/B/secret"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Content-Type: application/json"'
    assert_file_lacks "$STUB_LOG/curl.1.args" "secret"
    assert_eq '{"text":"*Docs \"changed\" &lt;now&gt; \\ &amp; then*\nPages: 1 changed, 0 added, 0 removed. Lines: +1 -1.\n* docs/alpha\n  + Alpha line 1.\n  - Alpha line one."}' \
        "$(cat "$STUB_LOG/curl.1.data")" "payload"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$STUB_LOG/curl.1.data" ||
            fail "payload is not valid JSON"
    fi
}

# Decode the text/plain part of message $1, or the part of subtype $2.
email_body() {
    awk -v type="Content-Type: text/${2:-plain}" '
        index($0, type) == 1 { found = 1; next }
        found && !body { if ($0 == "") body = 1; next }
        body && /^--/ { exit }
        body { print }
    ' "$1" | base64 --decode
}

# Print the dated diff pages in the changes directory, one per line.
diff_pages() {
    local page
    for page in "$CDW_REPO_DIR"/changes/*-claude-docs-changes*.html; do
        [[ ! -e $page ]] || printf '%s\n' "$page"
    done
}

test_email_via_sendmail() {
    export CDW_NOTIFY=email CDW_EMAIL_TO=a@example.test CDW_EMAIL_FROM=watch@example.test
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_eq 1 "$(calls sendmail)" "sendmail calls"
    assert_eq 0 "$(calls curl)" "curl calls"
    assert_eq "-t
-i" "$(cat "$STUB_LOG/sendmail.1.args")" "sendmail arguments"
    assert_file_contains "$STUB_LOG/sendmail.1.stdin" "From: watch@example.test"
    assert_file_contains "$STUB_LOG/sendmail.1.stdin" "To: a@example.test"
    assert_file_contains "$STUB_LOG/sendmail.1.stdin" "Subject: Claude Code docs changed"
    assert_file_contains "$STUB_LOG/sendmail.1.stdin" "Content-Transfer-Encoding: base64"
    email_body "$STUB_LOG/sendmail.1.stdin" >"$T/body"
    assert_file_contains "$T/body" "Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1."
    assert_file_contains "$T/body" "Repository: $CDW_REPO_DIR"
    assert_file_contains "$T/body" "-Alpha line one."
    assert_file_contains "$T/body" "+Alpha line 1."
    awk 'length($0) > 76 { exit 1 }' "$STUB_LOG/sendmail.1.stdin" || fail "message has a line over 76 characters"
}

test_email_via_sendmail_without_from_leaves_the_sender_to_the_mta() {
    export CDW_NOTIFY=email CDW_EMAIL_TO=a@example.test
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_file_lacks "$STUB_LOG/sendmail.1.stdin" "From:"
    assert_eq "To: a@example.test" "$(head -n 1 "$STUB_LOG/sendmail.1.stdin")" "first header"
}

test_email_diff_is_truncated() {
    export CDW_NOTIFY=email CDW_EMAIL_TO=a@example.test CDW_EMAIL_DIFF_LINES=5
    run_cdw
    edit_doc 's/line one/line 1/'
    run_cdw
    email_body "$STUB_LOG/sendmail.1.stdin" >"$T/body"
    assert_file_contains "$T/body" "[diff truncated: 5 of "
    assert_file_lacks "$T/body" "+Gamma line 1."
}

test_email_without_diff() {
    export CDW_NOTIFY=email CDW_EMAIL_TO=a@example.test CDW_EMAIL_DIFF_LINES=0
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    email_body "$STUB_LOG/sendmail.1.stdin" >"$T/body"
    assert_file_contains "$T/body" "Range: "
    assert_file_lacks "$T/body" "+Alpha line 1."
}

test_email_via_smtps() {
    export CDW_NOTIFY=email CDW_EMAIL_TO='a@example.test, b@example.test' CDW_EMAIL_FROM=watch@example.test
    export CDW_SMTP_URL=smtps://smtp.example.test:465 CDW_SMTP_USER=watch CDW_SMTP_PASSWORD=hunter2
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_eq 0 "$(calls sendmail)" "sendmail calls"
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'url = "smtps://smtp.example.test:465"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'mail-from = "watch@example.test"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'mail-rcpt = "a@example.test"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'mail-rcpt = "b@example.test"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'user = "watch:hunter2"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'crlf'
    assert_file_lacks "$STUB_LOG/curl.1.stdin" 'ssl-reqd'
    assert_file_lacks "$STUB_LOG/curl.1.args" "hunter2"
    assert_file_contains "$STUB_LOG/curl.1.data" "To: a@example.test, b@example.test"
}

test_email_via_smtp_requires_starttls_by_default() {
    export CDW_NOTIFY=email CDW_EMAIL_TO=a@example.test CDW_EMAIL_FROM=watch@example.test
    export CDW_SMTP_URL=smtp://smtp.example.test:587
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'ssl-reqd'
    edit_doc 's/Alpha line two/Alpha line 2/'
    export CDW_SMTP_STARTTLS=0
    run_cdw
    assert_file_lacks "$STUB_LOG/curl.2.stdin" 'ssl-reqd'
}

test_desktop_terminal_notifier() {
    export CDW_NOTIFY=desktop CDW_DESKTOP_CMD=terminal-notifier
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_eq "-title
Claude Code docs changed
-message
Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1.
* docs/alpha
  + Alpha line 1.
  - Alpha line one.
-group
claude-docs-watch
-open
file://$(diff_pages)" "$(cat "$STUB_LOG/terminal-notifier.1.args")" "arguments"
}

test_desktop_osascript() {
    export CDW_NOTIFY=desktop CDW_DESKTOP_CMD=osascript CDW_TITLE='Docs "changed"'
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_eq 1 "$(calls osascript)" "osascript calls"
    assert_file_contains "$STUB_LOG/osascript.1.args" 'display notification (item 2 of argv) with title (item 1 of argv)'
    assert_file_contains "$STUB_LOG/osascript.1.args" 'Docs "changed"'
    assert_file_contains "$STUB_LOG/osascript.1.args" "Pages: 1 changed"
}

test_desktop_notify_send() {
    export CDW_NOTIFY=desktop CDW_DESKTOP_CMD=notify-send
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_eq "--app-name=claude-docs-watch
--
Claude Code docs changed
Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1.
* docs/alpha
  + Alpha line 1.
  - Alpha line one." "$(cat "$STUB_LOG/notify-send.1.args")" "arguments"
}

test_desktop_auto_prefers_terminal_notifier() {
    export CDW_NOTIFY=desktop
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_eq 1 "$(calls terminal-notifier)" "terminal-notifier calls"
    assert_eq 0 "$(calls osascript)" "osascript calls"
}

test_all_channels_together() {
    use_ntfy
    export CDW_NOTIFY="ntfy,slack, email desktop"
    export CDW_SLACK_WEBHOOK_URL=https://hooks.slack.example.test/x CDW_EMAIL_TO=a@example.test
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_eq 2 "$(calls curl)" "curl calls"
    assert_eq 1 "$(calls sendmail)" "sendmail calls"
    assert_eq 1 "$(calls terminal-notifier)" "desktop calls"
}

# ---------------------------------------------------------------------------
# Excerpts
# ---------------------------------------------------------------------------

long_line_doc() {
    write_doc <<'EOF'
# Alpha
Source: https://example.test/docs/alpha

The quick brown fox jumps over the lazy dog while the cat sleeps on the warm windowsill near the garden gate.
EOF
}

test_excerpt_shows_the_change_with_leading_context() {
    use_ntfy
    export CDW_EXCERPT_CHARS=60
    long_line_doc
    run_cdw
    edit_doc 's/the cat sleeps/the kitten sleeps/'
    run_cdw
    assert_status 0
    assert_eq "Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1.
* docs/alpha
  + ...fox jumps over the lazy dog while the kitten sleeps on...
  - ...fox jumps over the lazy dog while the cat sleeps on the..." "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

test_excerpt_skips_the_side_without_changed_words() {
    use_ntfy
    long_line_doc
    run_cdw
    edit_doc 's/the cat sleeps/the old grey cat sleeps/'
    run_cdw
    assert_eq "Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1.
* docs/alpha
  + ...fox jumps over the lazy dog while the old grey cat sleeps on the warm windowsill near the garden gate." "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

test_excerpts_can_be_disabled() {
    use_ntfy
    export CDW_EXCERPT_CHARS=0
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_eq "Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1.
* docs/alpha" "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

test_excerpts_do_not_need_the_page_files() {
    use_ntfy
    export CDW_DOCS_DIR=""
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_eq "Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1.
* docs/alpha
  + Alpha line 1.
  - Alpha line one." "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

test_rewritten_links_do_not_count_as_changes() {
    local page
    use_ntfy
    linked_doc
    run_cdw
    assert_file_contains "$CDW_REPO_DIR/docs/en/beta.md" 'href="../en/sdk/deep.md"'
    edit_doc '/^# Deep/,/^Back to/d'
    run_cdw
    assert_status 0
    assert_file_contains "$CDW_REPO_DIR/docs/en/beta.md" "href=\"file://$SITE/en/sdk/deep\""
    assert_eq "Pages: 0 changed, 0 added, 1 removed. Lines: +0 -4.
- en/sdk/deep (removed)" "$(cat "$STUB_LOG/curl.1.data")" "summary"
    page=$(diff_pages)
    assert_file_contains "$page" '<li><a href="#p1">en/sdk/deep</a> <span class="meta">removed</span></li>'
    assert_file_lacks "$page" 'id="p2"'
}

test_body_stops_at_3000_bytes() {
    local i
    use_ntfy
    export CDW_MAX_PAGES=100
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        printf '# Page %s\nSource: https://example.test/docs/page-%s\n\n' "$i" "$i"
        printf 'Marker one. This sentence is long enough to fill an excerpt of one hundred and fifty characters with ordinary words that mean nothing in particular at all.\n\n\n'
    done | write_doc
    run_cdw
    edit_doc 's/Marker one/Marker two/'
    run_cdw
    assert_status 0
    assert_file_contains "$STUB_LOG/curl.1.data" "Pages: 30 changed"
    assert_file_contains "$STUB_LOG/curl.1.data" "* docs/page-1"
    assert_file_contains "$STUB_LOG/curl.1.data" "(and "
    (($(wc -c <"$STUB_LOG/curl.1.data") <= 3100)) || fail "body is $(wc -c <"$STUB_LOG/curl.1.data") bytes"
    (($(grep -c '^\* ' "$STUB_LOG/curl.1.data") >= 5)) || fail "fewer than 5 pages listed"
}

# ---------------------------------------------------------------------------
# Diff pages
# ---------------------------------------------------------------------------

test_diff_page_is_written_for_a_change() {
    local page
    run_cdw
    assert_eq "" "$(diff_pages)" "diff pages after the baseline"
    assert_file_contains "$CDW_REPO_DIR/changes/index.html" "No changes recorded yet."
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    page=$(diff_pages)
    [[ ${page##*/} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-claude-docs-changes\.html$ ]] || fail "unexpected name: $page"
    assert_file_contains "$T/out" "Diff page: $page"
    assert_file_contains "$page" '<tr class="hunk"><td class="g"></td><td>@@ # Alpha</td></tr>'
    assert_file_contains "$page" '<tr class="del"><td class="g">-</td><td>Alpha line <del>one.</del></td></tr>'
    assert_file_contains "$page" '<tr class="add"><td class="g">+</td><td>Alpha line <ins>1.</ins></td></tr>'
    assert_file_contains "$page" '<tr><td class="g"></td><td>Alpha line two.</td></tr>'
    assert_file_contains "$page" '<span class="tag">changed</span>Alpha <a href="../docs/docs/alpha.md">docs/alpha.md</a> <a href="https://example.test/docs/alpha">live page</a>'
    assert_file_contains "$page" 'Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1.'
    assert_file_lacks "$page" 'Beta'
    cmp -s "$page" "$CDW_REPO_DIR/changes/latest.html" || fail "latest.html differs from the diff page"
    assert_file_contains "$CDW_REPO_DIR/changes/index.html" "<a href=\"${page##*/}\">"
    assert_eq "" "$(git -C "$CDW_REPO_DIR" status --porcelain)" "work tree"
    assert_eq "" "$(tracked_pages changes)" "tracked diff pages"
}

test_diff_page_shows_whole_added_and_removed_lines() {
    local page
    run_cdw
    edit_doc '/^Alpha line two/d'
    printf 'Gamma line two.\n' >>"$T/src/llms-full.txt"
    run_cdw
    page=$(diff_pages)
    assert_file_contains "$page" '<tr class="del"><td class="g">-</td><td>Alpha line two.</td></tr>'
    assert_file_contains "$page" '<tr class="add"><td class="g">+</td><td>Gamma line two.</td></tr>'
    assert_file_lacks "$page" '<ins>'
}

test_diff_page_keeps_unrelated_lines_whole() {
    local page
    run_cdw
    edit_doc 's/^Alpha line one\.$/Something else entirely here./'
    run_cdw
    page=$(diff_pages)
    assert_file_contains "$page" '<tr class="del"><td class="g">-</td><td>Alpha line one.</td></tr>'
    assert_file_contains "$page" '<tr class="add"><td class="g">+</td><td>Something else entirely here.</td></tr>'
}

test_diff_page_escapes_html() {
    local page
    write_doc <<'EOF'
# A <b>bold</b> & "quoted" title
Source: https://example.test/docs/alpha

Use the <Card href="x"> tag & more.
EOF
    run_cdw
    edit_doc 's/& more/\& less/'
    run_cdw
    page=$(diff_pages)
    assert_file_contains "$page" 'Use the &lt;Card href=&quot;x&quot;&gt; tag &amp; <ins>less.</ins>'
    assert_file_contains "$page" 'A &lt;b&gt;bold&lt;/b&gt; &amp; &quot;quoted&quot; title'
    assert_file_lacks "$page" '<Card'
}

test_diff_page_folds_new_pages_and_lists_removed_ones() {
    local page
    run_cdw
    edit_doc '/^# Beta/,/^Beta line one/d'
    printf '\n\n# Delta\nSource: https://example.test/docs/delta\n\nDelta line one.\n' >>"$T/src/llms-full.txt"
    run_cdw
    page=$(diff_pages)
    assert_file_contains "$page" '<details><summary>Show the new page (4 lines)</summary>'
    assert_file_contains "$page" '<tr class="add"><td class="g">+</td><td>Delta line one.</td></tr>'
    assert_file_contains "$page" '<span class="tag">removed</span>Beta <a href="https://example.test/docs/beta">live page</a>'
    assert_file_contains "$page" '<p class="note">Page removed.</p>'
    assert_file_lacks "$page" 'Beta line one.'
    assert_file_contains "$page" '<li><a href="#p2">docs/delta</a> <span class="meta">new</span></li>'
}

test_diff_page_elides_long_unchanged_text() {
    local page filler
    filler=$(printf 'word%.0s ' $(seq 1 120))
    printf '# Alpha\nSource: https://example.test/docs/alpha\n\nStart %s middle old %s end.\n' "$filler" "$filler" | write_doc
    run_cdw
    edit_doc 's/middle old/middle new/'
    run_cdw
    page=$(diff_pages)
    assert_file_contains "$page" '<del>old</del>'
    assert_file_contains "$page" '<ins>new</ins>'
    assert_file_contains "$page" '<span class="gap"> &hellip; </span>'
    awk 'length($0) > 1500 { exit 1 }' "$page" || fail "a row kept its full unchanged text"
}

test_diff_page_from_the_document_without_page_files() {
    local page
    export CDW_DOCS_DIR=""
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    page=$(diff_pages)
    assert_file_contains "$page" '<span class="tag">changed</span>Alpha <a href="https://example.test/docs/alpha">live page</a></h2>'
    assert_file_contains "$page" '<td>@@ # Alpha</td>'
    assert_file_contains "$page" 'Alpha line <ins>1.</ins>'
    assert_file_lacks "$page" 'All pages'
}

test_diff_page_without_a_section_prefix() {
    local page
    export CDW_SECTION_PREFIX=""
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    page=$(diff_pages)
    assert_file_contains "$page" '<span class="tag">changed</span>llms-full.txt</h2>'
    assert_file_contains "$page" 'Alpha line <ins>1.</ins>'
    assert_file_contains "$page" 'Lines: +1 -1.'
}

test_two_changes_get_two_pages_and_a_history() {
    local first second
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    first=$(diff_pages)
    edit_doc 's/Alpha line two/Alpha line 2/'
    edit_doc 's/Beta line one/Beta line 1/'
    run_cdw
    assert_status 0
    assert_eq 2 "$(diff_pages | wc -l | tr -d ' ')" "diff pages"
    second=$(diff_pages | grep -vxF "$first")
    assert_file_contains "$second" 'Pages: 2 changed'
    cmp -s "$second" "$CDW_REPO_DIR/changes/latest.html" || fail "latest.html is not the newest page"
    assert_eq "${second##*/}
${first##*/}" "$(sed -n 's/^<tr><td><a href="\([^"]*\)">.*/\1/p' "$CDW_REPO_DIR/changes/index.html")" "history order"
    assert_file_contains "$CDW_REPO_DIR/changes/index.html" "Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1."
    assert_file_contains "$CDW_REPO_DIR/docs/index.md" "[Change history](../changes/index.html)"
}

test_changes_dir_can_be_disabled() {
    use_ntfy
    unset CDW_NTFY_ATTACH
    export CDW_NOTIFY=ntfy,desktop CDW_DESKTOP_CMD=terminal-notifier CDW_CHANGES_DIR=""
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_missing "$CDW_REPO_DIR/changes"
    assert_file_lacks "$CDW_REPO_DIR/docs/index.md" "Change history"
    assert_file_lacks "$STUB_LOG/curl.1.args" "--upload-file"
    assert_file_contains "$STUB_LOG/curl.1.data" "  + Alpha line 1."
    assert_file_contains "$STUB_LOG/terminal-notifier.1.args" "$CDW_URL"
}

test_custom_changes_dir() {
    export CDW_CHANGES_DIR=history
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_exists "$CDW_REPO_DIR/history/latest.html"
    assert_missing "$CDW_REPO_DIR/changes"
    assert_file_contains "$CDW_REPO_DIR/docs/index.md" "[Change history](../history/index.html)"
    assert_eq "" "$(git -C "$CDW_REPO_DIR" status --porcelain)" "work tree"
}

test_invalid_changes_dir_exits_2() {
    export CDW_CHANGES_DIR=../outside
    run_cdw
    assert_status 2
    assert_file_contains "$T/err" "CDW_CHANGES_DIR must be a plain directory name"
    export CDW_CHANGES_DIR=docs
    run_cdw
    assert_status 2
    assert_missing "$CDW_REPO_DIR"
}

# ---------------------------------------------------------------------------
# Diff page delivery
# ---------------------------------------------------------------------------

test_ntfy_attaches_the_diff_page() {
    local page
    use_ntfy
    unset CDW_NTFY_ATTACH
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    page=$(diff_pages)
    assert_eq 1 "$(calls curl)" "curl calls"
    assert_file_contains "$STUB_LOG/curl.1.args" "--upload-file"
    assert_file_contains "$STUB_LOG/curl.1.stdin" "header = \"Filename: ${page##*/}\""
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Message: Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1.\\n* docs/alpha\\n  + Alpha line 1.\\n  - Alpha line one."'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Title: Claude Code docs changed"'
    assert_file_lacks "$STUB_LOG/curl.1.stdin" "Click:"
    cmp -s "$page" "$STUB_LOG/curl.1.data" || fail "the attachment is not the diff page"
}

test_ntfy_message_header_encodes_non_ascii_text() {
    use_ntfy
    unset CDW_NTFY_ATTACH
    run_cdw
    edit_doc 's/Alpha line one/Alpha café/'
    run_cdw
    assert_status 0
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Message: =?UTF-8?B?'
    sed -n 's/^header = "Message: =?UTF-8?B?\(.*\)?="$/\1/p' "$STUB_LOG/curl.1.stdin" | base64 --decode >"$T/message"
    assert_file_contains "$T/message" '\n  + Alpha café.\n'
}

test_ntfy_sends_the_text_alone_when_the_attachment_is_rejected() {
    use_ntfy
    unset CDW_NTFY_ATTACH
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    export STUB_FAIL_MATCH=Filename
    run_cdw
    assert_status 0
    assert_eq 2 "$(calls curl)" "curl calls"
    assert_file_contains "$T/err" "ntfy rejected the attachment"
    assert_file_lacks "$STUB_LOG/curl.2.args" "--upload-file"
    assert_file_contains "$STUB_LOG/curl.2.stdin" "Click:"
    assert_file_contains "$STUB_LOG/curl.2.data" "  + Alpha line 1."
    assert_file_contains "$T/out" "Notified via ntfy."
}

test_ntfy_failing_both_ways_counts_once() {
    use_ntfy
    unset CDW_NTFY_ATTACH
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    export STUB_FAIL_MATCH=ntfy.example
    run_cdw
    assert_status 1
    assert_eq 2 "$(calls curl)" "curl calls"
    assert_eq 1 "$(grep -c 'notification failed: ntfy' "$T/err")" "failure lines"
}

test_email_carries_the_diff_page_as_html() {
    export CDW_NOTIFY=email CDW_EMAIL_TO=a@example.test
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_file_contains "$STUB_LOG/sendmail.1.stdin" 'Content-Type: multipart/alternative; boundary="=_claude-docs-watch-part"'
    assert_eq 2 "$(grep -c '^--=_claude-docs-watch-part$' "$STUB_LOG/sendmail.1.stdin")" "part separators"
    assert_eq "--=_claude-docs-watch-part--" "$(tail -n 1 "$STUB_LOG/sendmail.1.stdin")" "closing separator"
    email_body "$STUB_LOG/sendmail.1.stdin" html >"$T/html"
    cmp -s "$T/html" "$(diff_pages)" || fail "the HTML part is not the diff page"
    email_body "$STUB_LOG/sendmail.1.stdin" >"$T/body"
    assert_file_contains "$T/body" "  + Alpha line 1."
}

test_email_without_diff_pages_is_a_single_part() {
    export CDW_NOTIFY=email CDW_EMAIL_TO=a@example.test CDW_CHANGES_DIR=""
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_file_lacks "$STUB_LOG/sendmail.1.stdin" "multipart"
    email_body "$STUB_LOG/sendmail.1.stdin" >"$T/body"
    assert_file_contains "$T/body" "  + Alpha line 1."
}

test_channel_that_is_behind_opens_the_history() {
    export CDW_NOTIFY=desktop CDW_DESKTOP_CMD=terminal-notifier
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    export STUB_FAIL_MATCH=""
    PATH="$T/failing:$PATH"
    mkdir -p "$T/failing"
    printf '#!/bin/sh\nexit 1\n' >"$T/failing/terminal-notifier"
    chmod +x "$T/failing/terminal-notifier"
    run_cdw
    assert_status 1
    rm "$T/failing/terminal-notifier"
    edit_doc 's/Beta line one/Beta line 1/'
    run_cdw
    assert_status 0
    assert_file_contains "$STUB_LOG/terminal-notifier.1.args" "file://$CDW_REPO_DIR/changes/index.html"
    assert_file_contains "$STUB_LOG/terminal-notifier.1.args" "Pages: 2 changed"
}

test_test_notify_attaches_a_sample_page() {
    use_ntfy
    unset CDW_NTFY_ATTACH
    export CDW_NOTIFY=ntfy,desktop CDW_DESKTOP_CMD=terminal-notifier
    run_cdw test-notify
    assert_status 0
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Filename: claude-docs-changes-test.html"'
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Message: Test notification from claude-docs-watch'
    assert_file_contains "$STUB_LOG/curl.1.data" '<ins>new</ins>'
    assert_file_contains "$STUB_LOG/terminal-notifier.1.args" "$CDW_URL"
    assert_missing "$CDW_REPO_DIR"
}

# ---------------------------------------------------------------------------
# Report command
# ---------------------------------------------------------------------------

test_report_rebuilds_the_latest_change() {
    local page
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    page=$(diff_pages)
    cp "$page" "$T/original.html"
    rm -r "$CDW_REPO_DIR/changes"
    run_cdw report
    assert_status 0
    assert_eq "$page" "$(cat "$T/out")" "printed path"
    cmp -s "$page" "$T/original.html" || fail "the rebuilt page differs"
    assert_exists "$CDW_REPO_DIR/changes/index.html"
}

test_report_for_an_explicit_range() {
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    edit_doc 's/Beta line one/Beta line 1/'
    run_cdw
    run_cdw report 'HEAD~2' HEAD
    assert_status 0
    assert_file_contains "$(cat "$T/out")" 'Pages: 2 changed'
    assert_file_contains "$(cat "$T/out")" 'Alpha line <ins>1.</ins>'
    assert_file_contains "$(cat "$T/out")" 'Beta line <ins>1.</ins>'
    assert_eq 3 "$(diff_pages | wc -l | tr -d ' ')" "diff pages"
    run_cdw report 'HEAD~2'
    assert_status 0
    assert_eq 3 "$(diff_pages | wc -l | tr -d ' ')" "diff pages after a repeat"
}

test_report_all_rebuilds_every_change() {
    export CDW_CHANGES_DIR=""
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    edit_doc 's/Beta line one/Beta line 1/'
    run_cdw
    edit_doc 's/Gamma line one/Gamma line 1/'
    run_cdw
    assert_missing "$CDW_REPO_DIR/changes"
    unset CDW_CHANGES_DIR
    run_cdw report --all
    assert_status 0
    assert_eq 3 "$(diff_pages | wc -l | tr -d ' ')" "diff pages"
    assert_eq 3 "$(wc -l <"$T/out" | tr -d ' ')" "printed paths"
    assert_eq 3 "$(grep -c '^<tr><td><a href=' "$CDW_REPO_DIR/changes/index.html")" "history rows"
    assert_file_contains "$CDW_REPO_DIR/changes/latest.html" 'Gamma line <ins>1.</ins>'
    run_cdw report --all
    assert_eq 3 "$(diff_pages | wc -l | tr -d ' ')" "diff pages after a repeat"
}

test_report_errors() {
    run_cdw report
    assert_status 2
    assert_file_contains "$T/err" "no repository"
    run_cdw
    run_cdw report
    assert_status 1
    assert_file_contains "$T/err" "no change recorded yet"
    run_cdw report nonsense
    assert_status 2
    assert_file_contains "$T/err" "unknown revision: nonsense"
    run_cdw report a b c
    assert_status 2
    run_cdw --all
    assert_status 2
    CDW_CHANGES_DIR="" run_cdw report
    assert_status 2
    assert_file_contains "$T/err" "diff pages are disabled"
}

# ---------------------------------------------------------------------------
# Delivery tracking
# ---------------------------------------------------------------------------

test_failed_channel_is_retried_without_repeating_the_others() {
    use_ntfy
    export CDW_NOTIFY=ntfy,slack CDW_SLACK_WEBHOOK_URL=https://hooks.slack.example.test/x
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    export STUB_FAIL_MATCH=hooks.slack
    run_cdw
    assert_status 1
    assert_file_contains "$T/err" "notification failed: slack"
    assert_file_contains "$T/out" "Notified via ntfy."
    assert_eq 2 "$(calls curl)" "curl calls after failure"

    unset STUB_FAIL_MATCH
    run_cdw
    assert_status 0
    assert_eq 3 "$(calls curl)" "curl calls after retry"
    assert_file_contains "$STUB_LOG/curl.3.stdin" "hooks.slack"
    assert_file_contains "$STUB_LOG/curl.3.data" "docs/alpha"

    run_cdw
    assert_eq 3 "$(calls curl)" "curl calls after delivery"
}

test_retry_covers_every_change_since_the_last_delivery() {
    use_ntfy
    export CDW_NOTIFY=ntfy,slack CDW_SLACK_WEBHOOK_URL=https://hooks.slack.example.test/x
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    export STUB_FAIL_MATCH=hooks.slack
    run_cdw
    unset STUB_FAIL_MATCH
    edit_doc 's/Beta line one/Beta line 1/'
    run_cdw
    assert_status 0
    # Calls 3 and 4 are ntfy (second change only) and slack (both changes).
    assert_file_lacks "$STUB_LOG/curl.3.data" "docs/alpha"
    assert_file_contains "$STUB_LOG/curl.3.data" "docs/beta"
    assert_file_contains "$STUB_LOG/curl.4.data" "docs/alpha"
    assert_file_contains "$STUB_LOG/curl.4.data" "docs/beta"
    assert_file_contains "$STUB_LOG/curl.4.data" "Pages: 2 changed"
}

test_newly_enabled_channel_does_not_replay_history() {
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    use_ntfy
    run_cdw
    assert_status 0
    assert_eq 0 "$(calls curl)" "notifications"
    edit_doc 's/Beta line one/Beta line 1/'
    run_cdw
    assert_eq 1 "$(calls curl)" "notifications"
    assert_file_lacks "$STUB_LOG/curl.1.data" "docs/alpha"
    assert_file_contains "$STUB_LOG/curl.1.data" "docs/beta"
}

test_channel_enabled_on_the_run_that_finds_a_change_is_notified() {
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    use_ntfy
    run_cdw
    assert_eq 1 "$(calls curl)" "notifications"
}

# ---------------------------------------------------------------------------
# Configuration and command line
# ---------------------------------------------------------------------------

test_default_config_file_is_loaded() {
    mkdir -p "$HOME/.config/claude-docs-watch"
    printf 'CDW_NOTIFY=ntfy\nCDW_NTFY_TOPIC=from-file\n' >"$HOME/.config/claude-docs-watch/config"
    chmod 600 "$HOME/.config/claude-docs-watch/config"
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    assert_status 0
    assert_eq "" "$(cat "$T/err")" "stderr"
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'url = "https://ntfy.sh/from-file"'
}

test_config_option_and_permission_warning() {
    printf 'CDW_NOTIFY=ntfy\nCDW_NTFY_TOPIC=explicit\n' >"$T/custom.conf"
    chmod 644 "$T/custom.conf"
    run_cdw --config "$T/custom.conf" test-notify
    assert_status 0
    assert_file_contains "$T/err" "readable by other users"
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'url = "https://ntfy.sh/explicit"'
}

test_missing_config_file_exits_2() {
    run_cdw --config "$T/nope.conf"
    assert_status 2
    assert_file_contains "$T/err" "config file not readable"
}

test_unknown_channel_exits_2() {
    export CDW_NOTIFY=pigeon
    run_cdw
    assert_status 2
    assert_file_contains "$T/err" "unknown notification channel: pigeon"
    assert_missing "$CDW_REPO_DIR"
}

test_missing_channel_settings_exit_2() {
    export CDW_NOTIFY=ntfy
    run_cdw
    assert_status 2
    assert_file_contains "$T/err" "CDW_NTFY_TOPIC"
    export CDW_NOTIFY=slack
    run_cdw
    assert_status 2
    assert_file_contains "$T/err" "CDW_SLACK_WEBHOOK_URL"
    export CDW_NOTIFY=email
    run_cdw
    assert_status 2
    assert_file_contains "$T/err" "CDW_EMAIL_TO"
    export CDW_EMAIL_TO=a@example.test CDW_SMTP_URL=smtps://smtp.example.test
    run_cdw
    assert_status 2
    assert_file_contains "$T/err" "CDW_EMAIL_FROM"
    export CDW_NOTIFY=desktop CDW_DESKTOP_CMD=growl
    run_cdw
    assert_status 2
    assert_file_contains "$T/err" "desktop requires"
}

test_invalid_number_exits_2() {
    export CDW_MAX_PAGES=many
    run_cdw
    assert_status 2
    assert_file_contains "$T/err" "CDW_MAX_PAGES must be a non-negative integer"
}

test_test_notify_sends_to_every_channel_without_a_repository() {
    use_ntfy
    export CDW_NOTIFY=ntfy,desktop CDW_DESKTOP_CMD=notify-send
    run_cdw test-notify
    assert_status 0
    assert_eq 1 "$(calls curl)" "curl calls"
    assert_eq 1 "$(calls notify-send)" "notify-send calls"
    assert_file_contains "$STUB_LOG/curl.1.stdin" 'header = "Title: Claude Code docs changed (test)"'
    assert_file_contains "$STUB_LOG/curl.1.data" "Test notification from claude-docs-watch"
    assert_missing "$CDW_REPO_DIR"
}

test_test_notify_reports_failure() {
    use_ntfy
    export STUB_FAIL_MATCH=ntfy.example
    run_cdw test-notify
    assert_status 1
    assert_file_contains "$T/err" "notification failed: ntfy"
}

test_test_notify_without_channels_exits_2() {
    run_cdw test-notify
    assert_status 2
}

test_help_version_and_unknown_argument() {
    run_cdw --help
    assert_status 0
    assert_file_contains "$T/out" "Usage: claude-docs-watch"
    run_cdw --version
    assert_status 0
    assert_file_contains "$T/out" "claude-docs-watch 1."
    run_cdw --frobnicate
    assert_status 2
    assert_file_contains "$T/err" "unknown argument: --frobnicate"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

if (($# > 0)); then
    TESTS=("$@")
else
    TESTS=()
    while IFS= read -r name; do
        TESTS+=("$name")
    done < <(declare -F | awk '$3 ~ /^test_/ { print $3 }')
fi

printf 'bash %s, %s, %s\n' "$BASH_VERSION" "$(git --version)" "$("$REAL_CURL" --version | head -n 1 | cut -d' ' -f1-2)"

for name in "${TESTS[@]}"; do
    TESTS_RUN=$((TESTS_RUN + 1))
    CURRENT_FAILED=0
    setup "$name"
    "$name"
    if ((CURRENT_FAILED)); then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf 'not ok  %s\n' "$name"
    else
        printf 'ok      %s\n' "$name"
    fi
done

printf '\n%d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
((TESTS_FAILED == 0))
