# T07 — local Word import

Source implementation for [#8](https://github.com/sesameoil13/note-agent/issues/8), based on the existing T06 document contract. Packaged macOS GUI acceptance remains a separate gate owned by the driving session. Android/Windows picker source is included; no Android/Windows native acceptance is claimed.

## Supported behavior

- `NoteWorkspace.importDocument` retains an untouched private original before extraction; `importPdf` remains compatible. Magic selects PDF versus Word and required package relationships/content types select the DOCX main story. Plain text, body/table/body ordering, simple rectangular tables, blank cells, cell line breaks and display text are preserved. UTF-8/UTF-16 XML and strict/transitional Word namespaces are supported.
- Word uses the same `DocumentExtraction` body/table/location/unprocessed/problem/completion values. Reflowable Word does not invent pages or bounds. Main part + zero-based block order identify paragraphs/tables; table cells additionally carry row/cell locators. Parser objects do not enter note publication or reminders.
- Pictures are retained in the original and explicitly unrecognized, with no OCR. Headers, footers, notes, comments and embedded stories are disclosed as unprocessed. Merged/nested/irregular tables, content-control wrappers and omitted grid positions preserve readable text once and disclose incomplete layout instead of emitting an apparently complete rectangular table. Revisions use current-view text (insertions retained, deletions/move-from omitted), cached field displays are not recalculated, and generated numbering is not reconstructed. Unsupported blocks and alternative content degrade explicitly.
- Old binary DOC, encrypted Office and macro main-document formats are retained with an explicit unsupported status and local save-as-DOCX guidance. The feature does not claim support for every Word format or faithful complex layout.
- Ordinary notes retain exactly 正文 → 关联 → 来源, no generated summary/property section. Source retention, extraction and Standard attachment publication remain separate. Large originals can be extracted locally while Standard publication is withheld.
- Cancellation kills the pure-Dart worker; deadline processing stops instead of merely abandoning a future. Retry/restart reuse original/note identities. An independently edited published note is left untouched. A missing/unreadable retained source stops in a non-active recoverable error without changing existing text, source/note identity or published files; recovery does not claim the unavailable original is retained.

## Resource and package policy

Only stored/deflated local OPC packages are accepted. ZIP central/local headers, bounded entry counts/metadata, payload overlap, data descriptors, required XML byte lengths and CRCs are checked before use. Equivalent ASCII-case part names and unsafe/duplicate paths are rejected. No entry is extracted as a host path; images are not inflated just to mark them unread. Required-part CRC is checked explicitly rather than relying on `ZipDecoder(verify: true)`.

Hard ceilings: 32 MiB compressed input (caller may lower), 2,048 entries, 1 MiB central directory, 4 MiB per XML part, 8 MiB cumulative read XML, 250,000 XML events per part, depth 64, 64 attributes per element, 1,000,000 output characters, 10,000 table cells and 30 seconds (caller may lower the last three). Work runs in a globally serialized background worker, with worker exit observed before releasing its queue. ZIP64, unsupported compression, unsafe names and ambiguous packages fail with the original retained. This is bounded local parsing, not an OS sandbox guarantee.

DTD/entity declarations are rejected; namespace/nesting/document structure are validated before DOM creation. No macros, external relationship targets, remote XML, hyperlinks, fonts or linked images are executed/fetched.

## Host evidence

`test/word_import_test.dart` drives the approved public Workspace seam using python-docx-authored real files and deliberately corrupted packages. `tool/generate_word_fixtures.py` contains the independent authoring/read-back procedure. Word UI coverage mocks only the system picker grant boundary, including cancellation and grant release after original durability. The existing real-PDF-engine suite and neutral contract run unchanged alongside Word.

Run with the configured Flutter SDK and Node 24 on PATH; install `services/pairing` dependencies from its frozen lockfile for the existing local-Worker test. No remote deployment, real API key or model call is needed.

```sh
flutter test
flutter analyze
flutter build macos --release
codesign --verify --deep --strict 'build/macos/Build/Products/Release/Note Agent.app'
```

## Remaining native gate

Use only the dedicated temporary vault and root-authored independent Word files. Cancel the real Word picker once (no note); import body/table, mixed image/header, image-only, complex-table and damaged samples. Confirm Chinese text/cell newlines and truthful complete/partial/failed states, open the unchanged original, inspect the three-section note in Obsidian, then normally quit/relaunch and check stable identities/count/hash. A retained unsupported DOC should explain save-as-DOCX. Retest PDF import once. GUI acceptance, Android SDK/build/device tests and Windows native tests are not replaced by headless tests.

Primary references: [Word structure](https://learn.microsoft.com/en-us/office/open-xml/word/structure-of-a-wordprocessingml-document), [OPC part equivalence](https://learn.microsoft.com/en-us/dotnet/core/compatibility/core-libraries/8.0/system-io-packaging-case-insensitive-uri), [Dart XML](https://pub.dev/documentation/xml/latest/), [archive bounded decoder](https://pub.dev/documentation/archive/latest/archive/ZLibDecoder-class.html). Pinned direct package versions and notices are recorded in pubspec.lock / third_party/NOTICES and collected into Flutter's license bundle.
