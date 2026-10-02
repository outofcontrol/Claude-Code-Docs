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
    export CDW_NOTIFY=ntfy CDW_NTFY_URL=https://ntfy.example.test/ CDW_NTFY_TOPIC=docs
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
* https://example.test/docs/alpha
+ https://example.test/docs/delta
- https://example.test/docs/beta" "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

test_title_line_belongs_to_the_page_below_it() {
    use_ntfy
    run_cdw
    edit_doc 's/^# Beta$/# Beta renamed/'
    run_cdw
    assert_eq "Pages: 1 changed, 0 added, 0 removed. Lines: +1 -1.
* https://example.test/docs/beta" "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

test_deleted_lines_are_attributed_to_their_page() {
    use_ntfy
    run_cdw
    edit_doc '/^Alpha line two/d'
    run_cdw
    assert_eq "Pages: 1 changed, 0 added, 0 removed. Lines: +0 -1.
* https://example.test/docs/alpha" "$(cat "$STUB_LOG/curl.1.data")" "summary"
}

test_page_list_is_capped() {
    use_ntfy
    export CDW_MAX_PAGES=2
    run_cdw
    edit_doc 's/line one/line 1/'
    run_cdw
    assert_eq "Pages: 3 changed, 0 added, 0 removed. Lines: +3 -3.
* https://example.test/docs/alpha
* https://example.test/docs/beta
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
* https://example.test/docs/beta" "$(cat "$STUB_LOG/curl.2.data")" "summary"
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
    assert_eq '{"text":"*Docs \"changed\" &lt;now&gt; \\ &amp; then*\nPages: 1 changed, 0 added, 0 removed. Lines: +1 -1.\n* https://example.test/docs/alpha"}' \
        "$(cat "$STUB_LOG/curl.1.data")" "payload"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$STUB_LOG/curl.1.data" ||
            fail "payload is not valid JSON"
    fi
}

email_body() {
    sed '1,/^$/d' "$1" | base64 --decode
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
    assert_file_lacks "$T/body" "Gamma line 1."
}

test_email_without_diff() {
    export CDW_NOTIFY=email CDW_EMAIL_TO=a@example.test CDW_EMAIL_DIFF_LINES=0
    run_cdw
    edit_doc 's/Alpha line one/Alpha line 1/'
    run_cdw
    email_body "$STUB_LOG/sendmail.1.stdin" >"$T/body"
    assert_file_contains "$T/body" "Range: "
    assert_file_lacks "$T/body" "Alpha line 1."
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
* https://example.test/docs/alpha
-group
claude-docs-watch
-open
$CDW_URL" "$(cat "$STUB_LOG/terminal-notifier.1.args")" "arguments"
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
* https://example.test/docs/alpha" "$(cat "$STUB_LOG/notify-send.1.args")" "arguments"
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
