# Claude Code Statusline

Custom 3-line statusline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI — model, git status, context window, session cost, and 5h/7j usage quotas with ANSI colors and caching.

## Preview

```
Claude Opus 4.6 │ my-project │ * main +2 ~1 ?3 │ v1.0.53
██████░░░░░░░░░ 40% │ $1.24 12.3k │ +45 -12 │ 3m 22s
5h ▰▰▰▰▱▱▱▱▱▱ 40% 3h12m │ 7j ▰▰▱▱▱▱▱▱▱▱ 18% $14.52 5j 8h
```

## Features

**Line 1 — Identity & Git**
- Model name with color coding (Opus = magenta, Sonnet = blue, Haiku = cyan)
- Sub-agent name (if applicable)
- Vim mode indicator (`[N]`/`[I]`)
- Current project name
- Git branch with staged (`+`), modified (`~`), and untracked (`?`) counts
- Claude Code version

**Line 2 — Context & Session**
- Context window progress bar with color thresholds (green < 70%, yellow < 90%, red >= 90%)
- Alert when exceeding 200k tokens
- Session cost (USD) and total tokens
- Lines added/removed
- Session duration

**Line 3 — Usage Quotas**
- 5-hour usage quota with mini progress bar and reset timer
- 7-day usage quota with mini progress bar, estimated weekly cost, and reset timer
- Data fetched from the Anthropic OAuth API (cached 60s)

## Dependencies

- `jq` — JSON parsing
- `bc` — floating point formatting
- `curl` — API calls for usage quotas
- `git` — branch and status info

```bash
# Ubuntu/Debian
sudo apt install -y jq bc curl git
```

## Installation

1. Copy the script to your Claude config directory:

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

2. Add to your Claude Code settings (`~/.claude/settings.json`):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 1
  }
}
```

3. Restart Claude Code. The statusline appears at the bottom of the terminal.

## How it works

Claude Code pipes a JSON object to the statusline command via stdin on each render. The script parses it with `jq` to extract model info, context window stats, session cost, and more.

Git status and API usage data are cached in `/tmp/` to avoid slowdowns:
- Git cache: 5 second TTL (per directory)
- Usage cache: 60 second TTL

The weekly cost estimate is calculated locally from Claude Code's JSONL conversation logs using official API pricing.

## License

MIT
