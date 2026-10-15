# T04 search, titles and rename validation

Source scope for issue [#5](https://github.com/sesameoil13/note-agent/issues/5), based on integration `5da8b14` and the shared authorized-vault adapter from T02 (`ffb112a`). The final source handoff incorporates T02/T03 integration plus the inactive-workflow removal at `d774700`.

`NoteWorkspace.search` finds saved original text or titles, including records whose vault export failed. Empty search returns recent records. Detail retains the exact ordinary-note order 正文 → 关联 → 来源, no properties or ordinary-note summary, and the existing record/modified line immediately after the source. Search results lead to that detail, the complete original, its source-file handoff and the Obsidian note handoff.

`captureText` and `renameNote` accept a preferred title and ordered `semanticTitleCandidates`. The workspace tries supplied valid alternatives before appending ` (2)`, ` (3)`, etc. It does not append dates or times. A numbered title exposes `WorkspaceNote.titleCollision`; the interface uses a bone title border (normal ash, acid focus) with no duplicate dialog. Portable filenames reserve case variants, existing files/directories/symlinks, reject empty titles and avoid Windows device stems. Original text and the full naming request persist before vault lookup, so unavailable access retains a retryable capture.

The shared filename policy converts Obsidian link-syntax punctuation `# | ^ : % [ ]` to readable fullwidth forms `＃ ｜ ＾ ： ％ ［ ］` in manual titles, rename requests and semantic candidates. Thus `C#学习` becomes `C＃学习` rather than losing the language marker; title search applies the same normalization so typing `C#` still finds it. Plain Chinese titles and original source bytes stay unchanged. This avoids the reserved characters identified by [Obsidian's internal-link guidance](https://obsidian.md/help/links). Markdown output also encodes URL-reserved filename characters instead of letting them become URI fragments or queries.

The semantic candidates are a result contract for T13's organizing service. T04 does **not** generate AI titles, infer semantic candidates locally, call OpenRouter, add a paid provider or validate real-model Chinese title quality. Manual Chinese titles work now.

Rename keeps the stable record identity and original source attachment. It publishes the new note without replacement, updates inbound links, then removes the old file only if its content is unchanged. A durable plan resumes after interruption. Supported destinations include Obsidian wiki links/aliases/headings/embeds and Markdown inline/reference-definition links with relative paths, nested source folders, angle brackets and percent-encoded Chinese. Equal-length backtick runs protect inline code, including shorter runs inside and multiline spans; escaped link syntax, fenced/indented code and external URLs stay intact. Backslash behavior and exact delimiter runs follow [CommonMark code spans](https://spec.commonmark.org/0.31.2/#code-spans). This is not a general Markdown editor; custom Obsidian URI strings and arbitrary HTML links are not currently rewritten. A concurrently changed file fails its expected-content check and preserves the old/new targets for retry rather than overwriting that edit; there is no conflict-resolution editor in this slice.

Automated evidence on macOS (headless; temporary vaults, real files, public workspace actions; no private SQL assertions):

- `flutter test test ../research/t04-merge-probe_test.dart ../research/t04-sequential-rename-probe_test.dart --reporter expanded`: 23 passed (20 repository tests plus two merger probes and one sequential-rename probe). The merger URI probe was corrected to resolve a file URI and decode its fragment, rather than treating percent-encoded URI components as raw filesystem names.
- `flutter analyze`: no issues.
- `flutter build macos --debug --no-pub`: passed without launching the generated app.
- Search by Chinese title/original, Latin case folding, missing results and restart order.
- Semantic alternatives, persisted numbering, existing-file preservation, directory/case/symlink collisions, portable title handling and simultaneous duplicate captures.
- Reserved punctuation: corrected URI/file checks verify `C＃学习` wiki/Markdown destinations, decoded anchors, ASCII query lookup, duplicate capture and normalized semantic candidates; source bytes remain intact.
- Literal-code regression: double-backtick spans containing shorter runs, multiline code, escaped brackets/backticks, even/odd backslashes, four-backtick/tilde fences and indented code remain unchanged while adjacent wiki and encoded Unicode links update.
- Chinese rename with inbound wiki/Markdown/encoded/nested links and reference definitions with optional titles, preserved source, same-title no-op and restart retrieval.
- Simulated interruption after a real inbound-file update: both targets remain available before restart; restart finishes the rename without duplicate records or lost source.
- Unavailable vault lookup: original plus semantic request remain durable; access restoration and retry select the semantic candidate.
- Close lifecycle: a gated real publication keeps close pending; close rejects new captures, drains the accepted capture, and reopening retrieves one complete note and source.
- Combined phone behavior: rejected permission and cancelled reauthorization retain the draft; restoring the same grant retries one durable capture.
- Widget flow: keyword search → detail → original → source-file platform handoff → duplicate Chinese title edit, with no duplicate dialog and no summary/properties.

Tests were introduced before their corresponding search/title/rename interface or UI behavior. The Unicode-link, unavailable-vault, pending-close and two merger regressions reproduced behavioral failures before correction. Grouping paragraphs for multiline code initially exposed the existing reference-definition regression; the final multiline-aware reference pass restores that behavior. The Android-channel test validates the Dart boundary against a controlled platform response; it is not an Android device result.

No native app, CUA, real keyboard, visual/native border check, Android device, Windows VM, Obsidian sync or paid AI acceptance was run by the T04 implementer. Those gates remain for the coordinated platform/T13 acceptance; issue #5 is not closed by this source handoff.
