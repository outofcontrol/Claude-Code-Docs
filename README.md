# claude-docs-watch

Tracks the Claude Code documentation at <https://code.claude.com/docs/llms-full.txt> in a local git repository and sends a notification when it changes.

Notification channels: [ntfy](https://ntfy.sh) (public or self hosted), Slack, email, and desktop notifications. One bash script. Runs on macOS and Linux.

## How it works

1. `curl` downloads the document.
2. The document is split into one Markdown file per page under `docs/`, with a root page at `docs/index.md` that links to every page.
3. A changed document is committed, with its page files, to a git repository in `~/.local/share/claude-docs-watch`.
4. Every configured channel receives a summary: the pages changed, added and removed, and the line counts. Email also carries the start of the diff.
5. A git ref per channel (`refs/claude-docs-watch/notified/<channel>`) records the last commit that channel announced. A channel that fails is retried on the next run with a summary of every change since its last delivery. Channels that succeeded are not notified again.

The first run records a baseline and sends nothing.

Example notification:

```text
Claude Code docs changed
Pages: 2 changed, 1 added, 0 removed. Lines: +41 -12.
* https://code.claude.com/docs/en/hooks
* https://code.claude.com/docs/en/settings
+ https://code.claude.com/docs/en/brand-new
```

## Requirements

* bash 3.2 or later
* git
* curl
* Per channel: `sendmail` for email without SMTP, `terminal-notifier` or `osascript` for macOS desktop notifications, `notify-send` for Linux desktop notifications

## Install

Run from a copy of this repository:

```sh
make install
```

This installs `~/.local/bin/claude-docs-watch` and creates `~/.config/claude-docs-watch/config` (mode 600) when no config exists. Set `PREFIX` to install elsewhere: `make install PREFIX=/usr/local`.

Without `make`:

```sh
install -d ~/.local/bin ~/.config/claude-docs-watch
install -m 755 bin/claude-docs-watch ~/.local/bin/
install -m 600 examples/config.example ~/.config/claude-docs-watch/config
```

Add `~/.local/bin` to `PATH` if it is missing.

## Configure

Edit `~/.config/claude-docs-watch/config`. The file uses bash syntax and is sourced on every run. Environment variables with the same names also work. A value in the file overrides the environment. Pass `--config FILE` or set `CDW_CONFIG` to read a different file.

Set `CDW_NOTIFY` to a comma separated list of channels:

```sh
CDW_NOTIFY="ntfy,desktop"
```

### General settings

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `CDW_NOTIFY` | empty | Channels: `ntfy`, `slack`, `email`, `desktop`. Empty tracks changes without notifying. |
| `CDW_URL` | `https://code.claude.com/docs/llms-full.txt` | Document to track. |
| `CDW_REPO_DIR` | `~/.local/share/claude-docs-watch` | Git repository that stores the history. |
| `CDW_FILE` | last path segment of `CDW_URL` | File name inside the repository. |
| `CDW_TITLE` | `Claude Code docs changed` | Notification title. |
| `CDW_SECTION_PREFIX` | `Source: ` | Line prefix that starts a page. Empty reports line counts only and disables the page files. |
| `CDW_DOCS_DIR` | `docs` | Directory inside the repository for the page files. Empty disables them. |
| `CDW_MAX_PAGES` | `15` | Maximum number of pages listed in a notification. |
| `CDW_MIN_BYTES` | `1024` | Smaller responses are rejected as failed downloads. |
| `CDW_TIMEOUT` | `120` | Download timeout in seconds. |

### ntfy

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `CDW_NTFY_TOPIC` | required | Topic name. |
| `CDW_NTFY_URL` | `https://ntfy.sh` | Server URL. Set this for a self hosted server. |
| `CDW_NTFY_TOKEN` | empty | Access token, sent as a bearer token. |
| `CDW_NTFY_USER`, `CDW_NTFY_PASSWORD` | empty | Basic authentication, used when no token is set. |
| `CDW_NTFY_PRIORITY` | `default` | `min`, `low`, `default`, `high` or `urgent`. |
| `CDW_NTFY_TAGS` | `books` | Comma separated tags. |

A topic on ntfy.sh is public. Anyone who knows the name can read it and publish to it. Use a long random topic name, or a self hosted server with a token.

Tapping the notification opens `CDW_URL`.

### Slack

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `CDW_SLACK_WEBHOOK_URL` | required | Incoming webhook URL. |

Create the webhook at <https://api.slack.com/apps> under "Incoming Webhooks".

### Email

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `CDW_EMAIL_TO` | required | Recipient addresses, comma separated. |
| `CDW_EMAIL_FROM` | empty | Sender address. Required with `CDW_SMTP_URL`. |
| `CDW_SMTP_URL` | empty | `smtps://host:465` or `smtp://host:587`. Empty sends through `sendmail`. |
| `CDW_SMTP_USER`, `CDW_SMTP_PASSWORD` | empty | SMTP credentials. |
| `CDW_SMTP_STARTTLS` | `1` | Require STARTTLS on `smtp://` URLs. Set `0` for a local relay without TLS. |
| `CDW_SENDMAIL` | `sendmail` on `PATH`, then `/usr/sbin/sendmail` | Sendmail command. |
| `CDW_EMAIL_DIFF_LINES` | `200` | Diff lines included in the message. `0` omits the diff. |

Set `CDW_SMTP_URL` on machines without a configured mail transfer agent. A default macOS install has `sendmail` but does not relay to outside addresses.

### Desktop

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `CDW_DESKTOP_CMD` | `auto` | `auto`, `terminal-notifier`, `osascript` or `notify-send`. |

`auto` uses the first command found, in that order. On macOS, allow notifications for terminal-notifier or Script Editor (the sender of `osascript` notifications) in System Settings, Notifications.

## Run

```sh
claude-docs-watch              # fetch, commit, notify
claude-docs-watch test-notify  # send a test message to every configured channel
claude-docs-watch --quiet      # print errors only
```

Exit codes:

| Code | Meaning |
| :-- | :-- |
| 0 | Success, with or without a change. |
| 1 | Download failed, a notification failed, or another run holds the lock. |
| 2 | Usage or configuration error. |

Secrets (tokens, webhook URLs, passwords) reach `curl` through standard input and do not appear in the process list.

## Schedule

The installer does not schedule anything. Pick one of the following.

### macOS: launchd

```sh
cp examples/local.claude-docs-watch.plist ~/Library/LaunchAgents/
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/local.claude-docs-watch.plist
```

The agent runs at login and every hour, and writes to `~/Library/Logs/claude-docs-watch.log`. It expects the script at `~/.local/bin/claude-docs-watch`. Change `StartInterval` (seconds) in the plist for a different interval.

```sh
launchctl kickstart "gui/$(id -u)/local.claude-docs-watch"   # run now
launchctl print "gui/$(id -u)/local.claude-docs-watch"       # status
launchctl bootout "gui/$(id -u)/local.claude-docs-watch"     # stop and unload
rm ~/Library/LaunchAgents/local.claude-docs-watch.plist      # remove
```

### Linux: systemd user timer

```sh
mkdir -p ~/.config/systemd/user
cp examples/claude-docs-watch.service examples/claude-docs-watch.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now claude-docs-watch.timer
```

```sh
systemctl --user list-timers claude-docs-watch.timer   # next run
journalctl --user -u claude-docs-watch.service         # log
systemctl --user disable --now claude-docs-watch.timer # stop
```

Run `loginctl enable-linger "$USER"` to keep the timer running while logged out.

### cron (macOS or Linux)

Run `crontab -e` and add:

```cron
17 * * * * $HOME/.local/bin/claude-docs-watch --quiet
```

cron runs outside the desktop session. Use launchd or the systemd timer when the `desktop` channel is enabled. cron sets `PATH` to `/usr/bin:/bin`. Add a `PATH=` line to the crontab when git, curl or terminal-notifier live elsewhere.

## Browse the pages

Open `~/.local/share/claude-docs-watch/docs/index.md`. It lists every page by title, grouped by directory.

* A page starts at a `# ` heading directly above a `Source:` line. Headings without a `Source:` line, such as `#` comments in code blocks, stay inside their page.
* The file path comes from the page URL, relative to the directory of `CDW_URL`: `https://code.claude.com/docs/en/hooks` becomes `docs/en/hooks.md`.
* Links to another page become relative file links: `](/docs/en/hooks#setup)` becomes `](../en/hooks.md#setup)`. Other links that start with `/` get the site origin. `llms-full.txt` in the repository stays identical to the download.
* `docs/` is rebuilt on every run. A page removed upstream loses its file, and local edits inside `docs/` are overwritten.
* Characters outside `A-Z a-z 0-9 . _ / -` in a path become `_`. A path that matches an earlier one without regard to case gets a numeric suffix.

Enabling the page files on an existing repository creates one commit named "Rebuild docs" and sends no notification.

## Inspect the history

```sh
cd ~/.local/share/claude-docs-watch
git log --stat            # every recorded change
git log -- docs/en/hooks.md   # changes to one page
git show                  # the latest change
git diff HEAD~3 HEAD      # the last three changes combined
git for-each-ref refs/claude-docs-watch   # last commit announced per channel
```

History is packed after each commit.

## Uninstall

```sh
make uninstall
rm -r ~/.config/claude-docs-watch ~/.local/share/claude-docs-watch
```

Remove the launchd agent, systemd timer or crontab line first.

## Development

```sh
make test   # run the test suite
make lint   # shellcheck and reuse lint
```

The tests need bash, git and curl. They stub every notification command and read the document from a `file://` URL, with no network access. The script under test runs with the bash that runs the tests: `/bin/bash tests/run.sh` covers bash 3.2 on macOS. Run one test by name: `tests/run.sh test_ntfy_request`.

## License

Licensed under either of Apache License 2.0 (`LICENSES/Apache-2.0.txt`) or MIT (`LICENSES/MIT.txt`), at your option. SPDX expression: `Apache-2.0 OR MIT`.

The repository follows the [REUSE specification](https://reuse.software) version 3.3.
