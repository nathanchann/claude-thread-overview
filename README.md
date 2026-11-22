# Claude thread overview

One list of every Claude Code thread across all your projects: title, project,
state (needs you / working / ready for review / done) and last activity.

```
python3 threads.py            # terminal overview
python3 threads.py --html     # also opens a page you can keep in a browser tab
python3 threads.py --days 7   # show finished threads from the last week
python3 threads.py --debug    # if something looks off (never prints your token)
```

## Limiting projects

By default every project is shown. To limit it, copy `config.example.json` to
`config.json` and list the project names you want (case-insensitive).
`config.json` is gitignored. `--projects A,B` overrides it for one run.

## How it works

- Every project thread is a Claude Code cloud session. Each one is tagged with the
  project it belongs to, and the server already tracks its state ("status bucket")
  plus a one-line "needs action" / "recent action" summary.
- The script reads the login the `claude` CLI already saved in your macOS Keychain
  ("Claude Code-credentials") and your org id from `~/.claude.json`, then calls the
  same session-list endpoint the CLI uses (`/v1/code/sessions`).
- It only reads. It never refreshes, rewrites or prints your token.

## Caveats

- The session API is internal and undocumented, so it can change without notice.
- If the token has expired, open `claude` once (it refreshes itself), then rerun.
- Project names come from each project's coordinator session title. If a project's
  coordinator isn't returned, the row shows a short project id instead.

## Ideas for later

- A menu bar item (SwiftBar/xbar) that shows the "needs you" count.
- A macOS notification when a thread flips to "needs you" or "done".
