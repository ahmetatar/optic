# optic

A Claude Code plugin for setups where images can't be sent to Claude Code's API (a network or data policy blocks them) but GitHub Copilot CLI is allowed.

Claude keeps working as usual. When it needs to see something, the image goes through Copilot CLI to the same model, `claude-opus-5.5`, and the answer comes back as text:

- a screenshot or image file,
- a PDF page,
- a pasted image,
- a Chrome screenshot.

Copilot can read the project's files, so Claude can ask the question with full context.

## What's inside

| Part | What it does |
|---|---|
| `plugin/hooks/guard.sh` | **PreToolUse `Read`:** denies images and PDFs, by extension or by magic bytes. **PostToolUse `mcp__*`:** saves image blocks (Chrome screenshots, etc.) to `~/.optic/captures/` and replaces them with their paths. **UserPromptSubmit:** blocks prompts with a pasted image. Fails closed. |
| `plugin/hooks/paste.sh` | Async `UserPromptSubmit` hook (`asyncRewake`). When a prompt with a pasted image is blocked, it saves the clipboard image with `optic-clip` and wakes Claude with the blocked message and the saved path, so Claude answers it through `optic-look` without the user resending. |
| `plugin/bin/optic-look` | `copilot --model claude-opus-5.5 --attachment …`. Copilot may read files under the project dir. Shell, file writes, URLs and built-in MCP servers are off. `-s <id>` asks a follow-up in the same session. |
| `plugin/bin/optic-clip` | Saves the clipboard image and prints its path. |
| `plugin/skills/look/SKILL.md` | Tells Claude when and how to use the above, including how to write a question with full context. |

## Requirements

- macOS (uses `osascript`, `xxd` and `base64 -D`), plus `jq`, which ships with recent macOS.
- [GitHub Copilot CLI](https://github.com/github/copilot-cli), logged in, with access to `claude-opus-5.5`. Each question costs a Copilot premium request. To use another model, set `OPTIC_LOOK_MODEL`.

## Install

```sh
claude plugin marketplace add ahmetatar/optic
claude plugin install optic@optic --scope user
```

User scope makes the guard active in every project. Hooks load when a session starts, so open a new session after installing.

Optionally, add a line like this to `~/.claude/CLAUDE.md`, so Claude reaches for the skill before it hits the guard:

> Images can't be sent to the API here. Whenever you need to see an image (a screenshot, an image file, a PDF page, a pasted image, a Chrome/MCP screenshot), use the `optic:look` skill.

To turn it off later: `claude plugin disable optic@optic`.

## Limits

- Only `Read`, MCP tool results and pasted images are covered. Other ways an image could reach the API (for example WebFetch of an image URL, or notebook outputs) are not handled.
- A pasted image is taken from the clipboard after submit. If several images are pasted, only the one still on the clipboard (usually the last) is saved; if the clipboard changed, Claude asks for the image again.
- Captures in `~/.optic/captures/` are not cleaned up automatically.
- Sizes, colours and pixel positions in Copilot's answers are model estimates.

## Tests

```sh
tests/guard.test.sh
```

## License

MIT
