#!/bin/bash
# optic guard: keeps images from reaching the model. Claude asks about them through
# the look skill (optic-look -> GitHub Copilot CLI) instead.
#
#   PreToolUse Read      image or PDF (by extension, else by first bytes) -> deny
#   PostToolUse mcp__*   image blocks -> saved under $OPTIC_CAPTURES, replaced by their path
#   UserPromptSubmit     pasted image ([Image #N] placeholder) -> exit 2, prompt is not sent
#
# Fail-closed: unreadable input blocks; a PostToolUse failure withholds the whole tool output.
set -u
shopt -s nocasematch
CAPTURES=${OPTIC_CAPTURES:-$HOME/.optic/captures}

input=$(cat) || exit 2
# One jq call for the common fields (every jq start adds latency). \x1f separates them.
meta=$(jq -j '[.hook_event_name, .tool_name, .tool_input.file_path?, .cwd,
    ((.prompt? // "") | tostring | test("\\[Image #[0-9]+\\]"))]
  | map(if . == null then "" else tostring end) | join("\u001f")' <<<"$input" 2>/dev/null) || {
  echo "optic guard: hook input is not JSON; blocking." >&2
  exit 2
}
IFS=$'\x1f' read -r -d '' event tool path cwd pasted <<<"$meta"
pasted=${pasted%$'\n'}

deny() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# image | pdf | other, from the extension, else from the first 16 bytes.
file_kind() {
  local path=$1 name head
  name=${path##*/}
  if [[ $name == *.* ]]; then
    case ${name##*.} in  # nocasematch: PNG, Png, png
      png|jpg|jpeg|gif|webp|heic|heif|avif|tiff|tif|bmp) echo image; return ;;
      pdf) echo pdf; return ;;
    esac
  fi
  head=$(xxd -p -l 16 "$path" 2>/dev/null | tr -d '\n')
  case $head in
    # PNG, JPEG, GIF87a, GIF89a, TIFF little/big endian
    89504e470d0a1a0a*|ffd8ff*|474946383761*|474946383961*|49492a00*|4d4d002a*) echo image; return ;;
    255044462d*) echo pdf; return ;;
  esac
  # BMP: "BM", then four reserved zero bytes at offset 6.
  [[ ${head:0:4} == 424d && ${head:12:8} == 00000000 ]] && { echo image; return; }
  # WebP: "RIFF" .... "WEBP"
  [[ ${head:0:8} == 52494646 && ${head:16:8} == 57454250 ]] && { echo image; return; }
  # HEIF/AVIF: "ftyp" at offset 4, then the brand.
  if [[ ${head:8:8} == 66747970 ]]; then
    case ${head:16:8} in
      # heic heix hevc hevx heim heis mif1 msf1 avif avis
      68656963|68656978|68657663|68657678|6865696d|68656973|6d696631|6d736631|61766966|61766973) echo image; return ;;
    esac
  fi
  echo other
}

pre_read() {
  local full
  [[ -z $path ]] && exit 0
  if [[ $path == /* || -z $cwd ]]; then full=$path; else full=$cwd/$path; fi
  case $(file_kind "$full") in
    image) deny "optic guard: images are not sent to the model. Use the look skill: optic-look $path -p \"<question with full context>\"." ;;
    pdf) deny "optic guard: PDFs can carry page images. For text run: pdftotext -layout $path -. For anything visual use the look skill: optic-look $path -p \"<question>\"." ;;
  esac
  exit 0
}

withhold() {
  echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedMCPToolOutput":[{"type":"text","text":"[optic guard: tool output withheld because an image in it could not be removed safely.]"}]}}'
  exit 0
}

post_mcp() {
  local blocks total top i media ext path paths="[]"
  total=$(jq '[.tool_response | .. | objects | select(.type? == "image")] | length' <<<"$input") || withhold
  [[ $total == 0 ]] && exit 0
  blocks=$(jq -c '.tool_response | if type == "array" then . elif (.content? | type) == "array" then .content else [] end' <<<"$input") || withhold
  top=$(jq '[.[] | select(type == "object" and .type == "image")] | length' <<<"$blocks") || withhold
  # An image nested anywhere but the top level cannot be replaced in place.
  [[ $top == "$total" ]] || withhold
  mkdir -p "$CAPTURES" || withhold
  for ((i = 0; i < top; i++)); do
    media=$(jq -r --argjson i "$i" '[.[] | select(type == "object" and .type == "image")][$i] | .source.media_type // .mimeType // "image/png"' <<<"$blocks") || withhold
    ext=${media#image/}
    case $ext in png|gif|webp) ;; jpeg|jpg) ext=jpg ;; *) ext=img ;; esac
    path=$CAPTURES/$(date +%Y%m%d-%H%M%S)-$$-$i.$ext
    jq -r --argjson i "$i" '[.[] | select(type == "object" and .type == "image")][$i] | .source.data // .data // error("no data")' <<<"$blocks" \
      | base64 -D -o "$path" 2>/dev/null || withhold
    [[ -s $path ]] || withhold
    paths=$(jq -c --arg p "$path" '. + [$p]' <<<"$paths") || withhold
  done
  jq -c --argjson paths "$paths" '
    reduce .[] as $b ({out: [], i: 0};
      if ($b | type) == "object" and $b.type == "image"
      then .out += [{type: "text", text: "[optic guard: image saved to \($paths[.i]). It was not sent to the model; use the look skill to ask about it.]"}] | .i += 1
      else .out += [$b] end)
    | {hookSpecificOutput: {hookEventName: "PostToolUse", updatedMCPToolOutput: .out}}' <<<"$blocks" || withhold
  exit 0
}

case $event in
  PreToolUse)
    [[ $tool == Read ]] && pre_read
    exit 0 ;;
  PostToolUse)
    [[ $tool == mcp__* ]] && post_mcp
    exit 0 ;;
  UserPromptSubmit)
    if [[ $pasted == true ]]; then
      echo "optic guard: pasted images are not sent to the model. optic saves it from the clipboard (optic-clip) and Claude answers through Copilot." >&2
      exit 2
    fi
    exit 0 ;;
esac
exit 0
