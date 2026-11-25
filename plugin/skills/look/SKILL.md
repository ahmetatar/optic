---
name: look
description: >-
  How to see images while sending them to Claude Code's API is blocked. Claude Opus reads the image
  through GitHub Copilot CLI (optic-look) and answers in text. ALWAYS use it when you need to look at a
  screenshot, image file, PDF page, pasted/clipboard image, a Chrome or other MCP screenshot, or a UI
  change. Also use it whenever an "optic guard" message appears. Triggers - "ekran görüntüsü", "bak",
  "screenshot", "görsel", "image", "UI'ı kontrol et".
---

# look

The optic guard keeps images away from Claude Code's API. You still look at them: the same model (Claude Opus 5.5) sees each image through GitHub Copilot CLI and you get its answer as text. Use this exactly where you would have looked at the image yourself. The result should be just as good.

## Get the image into a file

- **File on disk:** use its path. Reading it directly is denied.
- **Pasted or on the clipboard:** run `optic-clip`. It saves the image and prints the path.
- **Chrome `screenshot` / `zoom` / `scroll`, or any MCP tool that returns an image:** call the tool as usual. The guard saves the image, and the result says `image saved to <path>`.
- **PDF:** get the text with `pdftotext -layout <file> -`. For figures, layout or scanned pages, pass the PDF to `optic-look`.
- **Web pages:** for text and structure, `read_page` / `find` / `get_page_text` are faster and exact. Take a screenshot when the question is visual.

## Ask

```
optic-look [-C <project dir>] <file>... -p "<prompt>"   # new question (stderr: optic-look session: <id>)
optic-look -s <id> [<file>...] -p "<prompt>"            # follow-up in the same session
```

Copilot sees only the image(s) and your prompt. It can read files under `-C` (default: the current directory) but nothing else. So write the prompt as the full question you would be answering yourself:

- **Context:** what we are doing and what just changed. For example: "I moved the Save button into the toolbar in `src/Toolbar.swift`".
- **What to check:** the expected state, and the code or strings it should match, named by path.
- **Answer format:** findings with locations. Exact text quoted verbatim. "Unsure" wherever it cannot tell, never a guess stated as fact.

Put every question you have about an image into one prompt. Each call takes 9–19 s (measured). For a closer look or a new question about the same image, use `-s <id>` instead of starting over.

- Bad: `-p "What is in this image?"`
- Good: `-p "iOS settings screen after my fix for the clipped footer (SettingsView.swift). Is the footer text 'Sürüm 2.3 · Gizlilik' fully visible on one line? Is it left-aligned with the section titles above? Quote any text that is cut off or has wrong Turkish letters, and say where it is."`

## Rules

- Act on the answer the way you would act on your own sight. If something matters and is ambiguous, ask a follow-up; don't fill the gap yourself.
- Sizes, pixel offsets, colours and contrast in the answer are the model's estimates. When an exact value matters, measure it: `sips -g pixelWidth -g pixelHeight <file>`, or the DOM/CSS for web pages. Otherwise label it as an estimate.
- Never route an image around the guard (base64 in a prompt, other upload tools). Don't change `optic-look`'s Copilot flags: shell, file writes, URLs and built-in MCP servers are off on purpose.
