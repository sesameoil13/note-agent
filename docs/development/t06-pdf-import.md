# T06 — local PDF import

`NoteWorkspace.importPdf` creates one ordinary note, stages/flushes/renames an
immutable private original through the existing attachment module, and only
then opens the PDF adapter. `retryDocumentExtraction` uses that original even
when a smaller Sync copy was chosen. If saving the original failed, its optional
`original` argument can complete the same note; it cannot replace a saved original.

The internal `DocumentExtractor` interface accepts the retained file, source
identity and validated options. Its engine-neutral result contains body blocks,
table cells, source locations, completion, structured problems, and unprocessed
page/region ranges. A location can instead identify a source `part` and
zero-based `blockIndex` without inventing a page or coordinate system. Body
and table blocks can declare global `order` for stable mixed content; old PDF
JSON falls back to page/top ordering. PDF locations use 1-based pages and unrotated PDF points
`[left, bottom, right, top]` from a bottom-left origin; rotation is explicit.
Word and future OCR adapters can return the same result types.

The PDF adapter uses the pinned `pdfium_flutter`/`pdfium_dart` 0.3.1 deployment
and guarded PDFium 7811 calls. It counts characters before allocating Dart
glyphs, processes one page at a time on a background isolate, and serializes
documents until native cleanup and worker exit have finished. It does not
render pages, open URLs, download fonts, run PDF JavaScript, perform OCR, or
call an AI service during extraction.

Only complete axis-aligned ruled grids with unambiguous character assignments
become tables. Empty cells, multi-line cells and Markdown delimiters are
preserved. Columns of prose, incomplete/merged grids and rotated tables remain
text; unsupported geometry is reported rather than guessed. Complex layout
reconstruction is outside this capability.

Cell lines use PDFium character-origin baselines, not painted glyph bottoms:
embedded Chinese glyphs such as `一` can have a much higher painted bottom than
their neighbors while sharing a baseline. Missing character origins make a
candidate ambiguous and leave its content as text. Adapter provenance is
`guarded-text-v2`. `test/fixtures/embedded-font-table.pdf` is the independent
ReportLab/embedded-font acceptance document (SHA-256
`fc60fb0169aca81eaefc325fd7204edbe32041e380bfc8035a37753a772a0cd5`);
its final cell must remain exactly `第一行\n第二行`.

Current ceilings, which callers may lower but cannot raise:

| Resource | Ceiling |
| --- | --- |
| Input opened by parser | 32 MiB, after full original retention |
| Pages processed | 300 |
| Raw characters in one page | 100,000 before glyph allocation |
| Raw characters across processed pages | 1,000,000 |
| Serialized body/table output | 1,000,000 UTF-16 code units |
| Extracted table cells | 10,000 |
| Page objects analyzed | 10,000 |
| Segments per path / total analyzed | 1,000 / 50,000 |
| Axis-aligned rules retained | 1,024 |
| Table candidates per page | 32 |
| Cooperative elapsed budget | 30 seconds, checked between pages |
| Active PDFium workers | 1 |

Cancellation stops later pages. These are application allocation/output/work
guards, **not** a process memory sandbox or a hard native-call timeout. PDFium
may allocate or spend time inside document/page loading before a guard can run.
Closing the workspace waits for accepted work and native cleanup; no
`Future.timeout` claims to stop a native call. Limits and cancellation produce
explicit partial/failure results and remaining page ranges.

Text and tables enter `正文`, with the existing `关联` and `来源` sections. The
source section includes extraction coverage/problems and an original PDF link
or an explicit local-only source entry. Scan/blank/unknown empty pages say no
extractable text and no OCR. Mixed image pages retain successful text while
marking pages needing OCR. Password-protected PDFs are retained and reported;
the app does not ask for or persist passwords. Extraction limits are independent
of the existing 5,000,000-byte Sync publication gate.

Retry publication uses the same note and source identities. Re-extraction uses
a durable compare-and-replace journal, preserves associations/source entries,
and declines to replace an externally edited body or unreadable/moved note.
Recovery replays a pending write or reports an interrupted extraction.

`WorkspacePlatform.chooseSourceFile({pdfOnly: false, audioOnly: false})` keeps
its existing unfiltered default. A selected file has temporary access until
`releaseSourceFile`. Android copies `ACTION_OPEN_DOCUMENT` content through
`ContentResolver` into private cache; Dart never treats its URI as a path. SAF
binary publication streams and verifies the private source. Android's
FileProvider exposes only original/recording source directories with a temporary
read grant. It does not expose the workspace database. Android source changes
are unbuilt while Android setup remains deferred.

Host coverage is in `test/pdf_import_test.dart` and `test/pdf_ui_test.dart`.
`tool/generate_pdf_fixtures.py` constructs independent known-text/geometry
fixtures without using the production extractor. `locked.pdf` is the checked-in
encrypted test artifact; tests intentionally provide no password.

Native acceptance still requires the packaged macOS picker, PDFium load,
original/source handoff and normal quit/relaunch. Android source picker/SAF,
native-asset ABI and 16 KiB alignment, memory profiling, and Windows build and
native flows require their respective toolchains/devices. No host test or
headless build establishes those gates. Upstream native update/digest review
and release signing remain release work; see the PDF research notes.
