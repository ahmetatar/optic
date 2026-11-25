#!/bin/bash
# Tests for plugin/hooks/guard.sh. Run: tests/guard.test.sh
set -u
GUARD=$(cd "$(dirname "$0")/.." && pwd)/plugin/hooks/guard.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export OPTIC_CAPTURES=$T/captures
fails=0 count=0

run() { OUT=$(printf '%s' "$1" | "$GUARD" 2>"$T/err"); CODE=$?; ERR=$(cat "$T/err"); }
ok() { count=$((count + 1)); }
bad() { count=$((count + 1)); fails=$((fails + 1)); echo "FAIL: $1"; echo "  code=$CODE out=${OUT:0:300} err=${ERR:0:200}"; }
read_call() { jq -nc --arg p "$1" --arg c "${2:-}" '{hook_event_name: "PreToolUse", tool_name: "Read", tool_input: {file_path: $p}} + (if $c == "" then {} else {cwd: $c} end)'; }
expect_deny() { # name, needle
  if [[ $CODE == 0 ]] && jq -e --arg n "$2" '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains($n))' <<<"$OUT" >/dev/null 2>&1; then ok; else bad "$1"; fi
}
expect_allow() { if [[ $CODE == 0 && -z $OUT ]]; then ok; else bad "$1"; fi; }

# --- PreToolUse Read: extensions (files need not exist) ---
for ext in png jpg jpeg gif webp heic heif avif tiff tif bmp; do
  run "$(read_call "/work/shot.$ext")"; expect_deny "deny .$ext" "optic-look /work/shot.$ext"
done
run "$(read_call /work/Photo.JPG)"; expect_deny "uppercase extension" "optic-look"
run "$(read_call /work/a.Png)"; expect_deny "mixed-case extension" "optic-look"
run "$(read_call /docs/spec.PDF)"; expect_deny "pdf extension" "pdftotext -layout /docs/spec.PDF"
run "$(read_call /repo/src/main.rs)"; expect_allow "source file"
run "$(read_call /repo/logo.svg)"; expect_allow "svg is text"
run "$(read_call /repo/png/notes.md)"; expect_allow "png as directory name"
run "$(read_call /repo/image.png.txt)"; expect_allow "png not the last extension"
run '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{}}'; expect_allow "read without file_path"
run '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/a.png"}}'; expect_allow "write of png"
run '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls *.png"}}'; expect_allow "bash mentioning png"
run '{"hook_event_name":"PreToolUse","tool_name":"mcp__claude-in-chrome__computer","tool_input":{"action":"screenshot"}}'; expect_allow "chrome screenshot runs (PostToolUse strips it)"

# --- PreToolUse Read: content sniffing for unknown extensions ---
mk() { printf '%b' "$2" >"$T/$1"; }
mk png '\x89PNG\r\n\x1a\n\0\0\0\rIHDR'
mk jpeg '\xff\xd8\xff\xe0\0\x10JFIF\0'
mk gif89 'GIF89a\x01\0\x01\0'
mk gif87 'GIF87a\x01\0\x01\0'
mk webp 'RIFF\x24\0\0\0WEBPVP8 '
mk heic '\0\0\0\x18ftypheic\0\0\0\0'
mk avif '\0\0\0\x1cftypavif\0\0\0\0'
mk mif1 '\0\0\0\x1cftypmif1\0\0\0\0'
mk bmp 'BM\x36\0\x0c\0\0\0\0\0\x36\0\0\0'
mk tiffle 'II*\0\x08\0\0\0'
mk tiffbe 'MM\0*\0\0\0\x08'
for f in png jpeg gif89 gif87 webp heic avif mif1 bmp tiffle tiffbe; do
  run "$(read_call "$T/$f")"; expect_deny "magic $f" "optic-look $T/$f"
done
mk pdfdat '%PDF-1.7\n%\xe2\xe3'
run "$(read_call "$T/pdfdat")"; expect_deny "magic pdf" "pdftotext"
mk mp4 '\0\0\0\x18ftypisom\0\0\0\0'
mk bmish 'BM\x36\0\x0c\0\x01\0\0\0\x36\0\0\0'
mk riffwav 'RIFF\x24\0\0\0WAVEfmt '
mk text 'hello world, not an image'
mk short '\x89PN'
for f in mp4 bmish riffwav text short; do
  run "$(read_call "$T/$f")"; expect_allow "magic non-image $f"
done
run "$(read_call /no/such/file)"; expect_allow "missing file without extension"
mkdir -p "$T/repo/assets"; cp "$T/png" "$T/repo/assets/raw"
run "$(read_call assets/raw "$T/repo")"; expect_deny "relative path resolved against cwd" "optic-look assets/raw"

# --- UserPromptSubmit ---
up() { jq -nc --arg p "$1" '{hook_event_name: "UserPromptSubmit", prompt: $p}'; }
run "$(up '[Image #1] what is this')"; if [[ $CODE == 2 && $ERR == *optic-clip* ]]; then ok; else bad "pasted image blocks"; fi
run "$(up 'compare [Image #12] and [Image #13]')"; if [[ $CODE == 2 ]]; then ok; else bad "multi-digit placeholder"; fi
for p in 'no image here' '[Image #] x' '[Image #a1] x' 'Image #1' '[image #1]'; do
  run "$(up "$p")"; expect_allow "prompt '$p'"
done

# --- PostToolUse MCP images ---
PNG_B64=$(base64 <"$T/png")
post() { jq -nc --arg t "$1" --argjson r "$2" '{hook_event_name: "PostToolUse", tool_name: $t, tool_response: $r}'; }
run "$(post mcp__claude-in-chrome__computer "$(jq -nc --arg d "$PNG_B64" '[{type: "text", text: "before"}, {type: "image", source: {type: "base64", media_type: "image/png", data: $d}}, {type: "text", text: "after"}]')")"
out=$(jq -c '.hookSpecificOutput.updatedMCPToolOutput' <<<"$OUT" 2>/dev/null)
saved=$(jq -r '.[1].text' <<<"$out" 2>/dev/null | sed -n 's/.*saved to \([^ ]*\.png\)\..*/\1/p')
if [[ $(jq -r '.[0].text, .[2].text' <<<"$out" 2>/dev/null | tr '\n' ' ') == "before after " && $(jq '[.. | objects | select(.type? == "image")] | length' <<<"$out") == 0 && -n $saved ]] && cmp -s "$saved" "$T/png"; then ok; else bad "api-format image replaced and saved byte-exact"; fi
run "$(post mcp__lab__get "$(jq -nc --arg d "$PNG_B64" '{content: [{type: "image", data: $d, mimeType: "image/jpeg"}]}')")"
if jq -e '.hookSpecificOutput.updatedMCPToolOutput[0].text | test("saved to .*\\.jpg\\.")' <<<"$OUT" >/dev/null 2>&1; then ok; else bad "mcp-format image in .content, jpeg extension"; fi
run "$(post mcp__x__y "$(jq -nc --arg d "$PNG_B64" '[{type: "image", source: {data: $d}}, {type: "image", source: {data: $d}}]')")"
two=$(jq -r '.hookSpecificOutput.updatedMCPToolOutput[].text' <<<"$OUT" 2>/dev/null | sed -n 's/.*saved to \([^ ]*\.png\)\..*/\1/p' | sort -u)
if [[ $(wc -l <<<"$two") == *2 ]] && cmp -s $(head -1 <<<"$two") "$T/png" && cmp -s $(tail -1 <<<"$two") "$T/png"; then ok; else bad "two images, two distinct saved files"; fi
run "$(post mcp__x__y '[{"type":"text","text":"plain"}]')"; expect_allow "mcp result without image untouched"
run "$(post mcp__x__y '[{"type":"text","nested":{"type":"image","source":{"data":"AAAA"}}}]')"
if jq -e '.hookSpecificOutput.updatedMCPToolOutput == [{"type":"text","text":"[optic guard: tool output withheld because an image in it could not be removed safely.]"}]' <<<"$OUT" >/dev/null 2>&1; then ok; else bad "nested image withholds output"; fi
run "$(post mcp__x__y '[{"type":"image","source":{"media_type":"image/png"}}]')"
if jq -e '.hookSpecificOutput.updatedMCPToolOutput[0].text | contains("withheld")' <<<"$OUT" >/dev/null 2>&1; then ok; else bad "image without data withholds output"; fi
run "$(post Bash '[{"type":"image","source":{"data":"AAAA"}}]')"; expect_allow "non-mcp tool ignored"

# --- input errors ---
run 'not json'; if [[ $CODE == 2 ]]; then ok; else bad "non-JSON input blocks"; fi
run '{"hook_event_name":"Stop"}'; expect_allow "other events"

echo "$((count - fails))/$count passed"
((fails == 0))
