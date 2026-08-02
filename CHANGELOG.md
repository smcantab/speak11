# Changelog

## v1.3.0

### Highlights

**Rebindable shortcut.** The global hotkey is no longer fixed to `⌥⇧/`. Menu bar icon → **Shortcut** opens a key recorder: press any combination and it takes effect immediately, no restart. Either a function key (`F1`–`F20`) on its own, or any key with `⌘`, `⌥` or `⌃`. This matters when another app installs a global keyboard tap — dictation tools, macro utilities, some launchers — and grabs the combination first; macOS offers no way to claim priority, so being able to move the shortcut is the fix. The binding is stored as a keycode, so it follows the physical key across keyboard layouts.

**Sentences no longer skipped.** The sentence splitter cut on punctuation with the English pySBD ruleset regardless of the text's actual language. German text was over-split, and lines without terminal punctuation — headings, salutations — were glued onto the following paragraph and could be dropped from playback entirely. Splitting is now paragraph-first (a blank line is a sentence break in every language, needing no segmenter), followed by per-paragraph language detection, then the pySBD ruleset for that language.

### New features

- **Configurable global shortcut**: key recorder in the menu bar, persisted to `~/.config/speak11/config` as `HOTKEY_CODE` / `HOTKEY_FLAGS`, applied to the live event tap without a restart. Bare keys and Shift-only combinations are rejected — the tap consumes what it matches, so binding `⇧A` would eat every capital A you type
- **`speak11-audio detect-lang`**: batched language detection over `NaturalLanguage`, one process spawn for the whole document plus every paragraph, constrained to the languages the splitter has rulesets for

### Bug fixes

- **Lines silently skipped during playback**: paragraph-first splitting keeps a heading or salutation that lacks terminal punctuation from being absorbed into the next paragraph
- **German text over-split**: each paragraph is segmented with the pySBD ruleset for its own detected language, falling back to the document language when a short fragment isn't confidently identified
- **Numeric dates split mid-date**: `30.06.` and similar are protected before segmentation, so no pause lands inside a date
- **`pysbd` now installed** by `install.command` alongside `ftfy` and `pylatexenc`; without it the splitter falls back to a regex that mishandles abbreviations and dates

## v1.2.0

### Highlights

**Named custom voice library.** Add multiple custom ElevenLabs voices, each with its own name, straight from the menu bar — they now appear as regular entries in the **Voice** menu instead of a single overwritable slot. A new "Add Custom Voice…" dialog takes a name and a voice ID, and a "Remove Custom Voice" submenu manages them. Voices are stored in `~/.config/speak11/custom_voices.json`.

**Non-ASCII text fixed.** Selections containing German (ß, ä, ö, ü), accents, or other non-ASCII characters are now spoken correctly. When launched from the menu bar, the app had no `LANG` set, so `pbpaste` fell back to ASCII and the characters were mangled and then stripped before reaching ElevenLabs. Speak11 now forces a UTF-8 character type for the clipboard read.

### New features

- **Multiple named custom voices**: add, select, and remove custom ElevenLabs voices from the **Voice** menu; persisted to `custom_voices.json`

### Bug fixes

- **Paste in dialogs**: `⌘V` (and `⌘C`/`⌘X`/`⌘A`) now work in the Add Custom Voice, Sentence Pause, and API Key dialogs. The menu bar app has no Edit menu, so a new `EditableTextField` routes the standard editing shortcuts through the responder chain — previously only right-click → Paste worked.
- **German / non-ASCII selections dropped**: force a UTF-8 `LC_CTYPE` in `speak.sh`, and pass `LC_CTYPE=UTF-8` to the spawned process from the app, so `pbpaste` keeps non-ASCII text intact

## v1.1.0

### Highlights

**Gapless playback.** A native Swift audio queue player replaces per-sentence `afplay` calls, cutting the gap between sentences from ~970ms to ~30ms. A configurable pause (default 400ms at 1× speed) restores natural speech rhythm and scales automatically with your speed setting. Adjustable from the menu bar -- click "Sentence Pause" and type any value in milliseconds.

**Text normalizer.** A new 6-phase Python preprocessor turns PDFs, LaTeX, and Markdown into clean, speakable text. It combines general-purpose normalization (currency, abbreviations, Unicode cleanup) with domain-specific handling for technical and scientific content (LaTeX math, SI units, Greek letters). Separate front-ends for PDF, LaTeX, and Markdown input clean up format-specific artifacts before the text reaches the TTS engine.

### New features

- **Audio queue player** (`speak11-audio.swift`): gapless sentence playback via `AVAudioPlayer` queue with `CoreAudio` mute detection, replacing the old afplay-per-sentence approach
- **Sentence pause**: configurable inter-sentence silence (0--1000+ ms) that scales inversely with playback speed; free-form input from the menu bar
- **Text normalizer** (`normalize.py`): 1200-line preprocessor with general and domain-specific rules:
  - *General*: currency (`$1.5M` reads as "1.5 million dollars"), abbreviations (`e.g.`, `i.e.`, `et al.`), math symbols (`±`, `×`, `∞`), Unicode cleanup via ftfy
  - *Scientific*: LaTeX math environments (`equation`, `align`, `matrix`, `cases`, fractions, superscripts, subscripts), SI units and compound units (`kg/m³`, `kPa`, `nm`, `°C`, `kcal/mol`), Greek letters (`\alpha`, `\beta`, including diacritics and final sigma), Miller crystallographic indices (`(111)`, `[110]`), set theory symbols (`∈`, `⊂`, `∪`)
  - *PDF front-end*: rejoins mid-word line breaks, strips superscript citations, removes page headers
  - *LaTeX front-end*: converts math environments, commands, and macros into spoken text
  - *Markdown front-end*: strips YAML front matter, wikilinks, callout syntax, inline code, HTML tags

### Performance

- Audio queue player eliminates ~970ms inter-sentence overhead (down to ~30ms hardware latency)
- Test suite runs in ~36s, down from ~2min, with section filtering (`--fast`, `--section`)
- ftfy is now a required dependency for reliable Unicode normalization

### Bug fixes

- Bare URLs (`go.nature.com/4rzrnyx`) verbalized as "go dot nature dot com slash 4rzrnyx" so local TTS reads dots and slashes correctly
- PDF mid-word newlines: text copied from PDFs no longer has spurious line breaks inside words and sentences
- Compound hyphen rejoining across PDF line breaks
- Superscript citations glued to sentence-ending periods (e.g., `result.²³` now strips cleanly)
- Nested LaTeX environments (`\begin{equation}\begin{cases}...\end{cases}\end{equation}`)
- Nested bold/italic in Markdown (`***bold italic***`)
- `\left\langle` / `\right\rangle` bracket commands
- Chained equals signs in equations (`a = b = c`)
- Dollar signs inside math environments (`\$`)
- Scientific notation (`3\times10^{5}`, negative exponents)
- `\cfrac` (continuous fractions)
- Unit slash not triggering false positives on `s/he`
- Greek final sigma (`ς`) spoken as "sigma"
- Greek letters with tonos diacritics
- Star-prefixed lists not breaking italic regex
- siunitx edge cases and unit joining
- Denominator singular vs plural (`per mole` not `per moles`)
- Matrix environments inside equation wrappers
- `SCRIPT_DIR` ordering bug in speak.sh
- Terminal no longer minimizes during install/uninstall

### Infrastructure

- Repo-local dev venv for the test suite
- Always uses the venv Python interpreter, never falls back to system python3
- `VENV_PYTHON` guards on `split_sentences` and `run_local_tts`
- Test suite expanded from ~200 to 1066 tests
- Profiling script (`tests/profile.sh`) for end-to-end pipeline timing

## v1.0.0

Initial release.
