#!/bin/bash
# optic paste: async UserPromptSubmit hook (asyncRewake). guard.sh blocks a prompt with a
# pasted image; this hook saves the image from the clipboard and wakes Claude with the
# blocked message and the saved path, so Claude answers it through the look skill.
# Exit 2 = wake the model with stderr; exit 0 = nothing to do.
set -u
input=$(cat) || exit 0
# Only prompts the user typed; the wake-up message itself must not trigger another wake-up.
prompt=$(jq -r 'select(.hook_event_name == "UserPromptSubmit" and (.source // "user") == "user") | .prompt // empty' <<<"$input" 2>/dev/null) || exit 0
[[ $prompt =~ \[Image\ \#[0-9]+\] ]] || exit 0

count=$(grep -oE '\[Image #[0-9]+\]' <<<"$prompt" | sort -u | wc -l | tr -d ' ')
# The wake-up text goes through UserPromptSubmit too: write placeholders so the guard lets it pass.
quoted=$(sed -E 's/\[Image #([0-9]+)\]/(pasted image \1)/g' <<<"$prompt")
if path=$("${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/bin/optic-clip" 2>/dev/null); then
  note=""
  ((count > 1)) && note=" Only the image still on the clipboard (usually the last one pasted) was saved; say so if the message refers to the others."
  cat >&2 <<EOF
optic: the user's last message had a pasted image, so the guard kept it from the model. The image is saved at $path.$note
Answer that message now as if you had seen the image: use the look skill (optic-look $path -p "<full question>"). The message was:
$quoted
EOF
else
  cat >&2 <<EOF
optic: the user's last message had a pasted image, so the guard kept it from the model, and the clipboard no longer holds an image. Tell the user to copy the image again, or give its file path. The message was:
$quoted
EOF
fi
exit 2
