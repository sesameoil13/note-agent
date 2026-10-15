# T01 validation — text collection on macOS

Issue: [#2](https://github.com/sesameoil13/note-agent/issues/2), parent [#1](https://github.com/sesameoil13/note-agent/issues/1).

Status: implementation ready for integration; **native macOS acceptance remains open**. Do not close the issue or treat its downstream tickets as unblocked solely because the source tests pass.

## Agreed seam

Tests drive the public `NoteWorkspace` interface and inspect visible workspace state plus actual Markdown/source files in fresh temporary vaults. The widget test uses that same real workspace. Time, identity and the system-file publisher are injectable external boundaries. No test inspects SQLite tables or private methods.

The interruption test injects a process interruption at the file-system boundary after writing a real partial staging file. It then reopens the real SQLite workspace, recovers pending publication, and checks complete files. It simulates the interruption; it does not claim that a device power-loss test was performed.

## Executed on the current Apple Silicon Mac

Environment: Flutter 3.47.7, Dart 3.13.5, macOS 26.6.2 (build 25G83), Apple Swift 6.1.2, CommandLineTools installed; full Xcode absent.

- `flutter test --reporter expanded`: 5 tests passed. Covers restart/recovery, exact ordinary-note template/source, durable original after a vault write failure and retry, interrupted publication recovery, protection of an unrelated existing note, and collection/list/detail/original viewing through the real workspace.
- `flutter analyze`: passed with no issues.
- Swift type checking of `MainFlutterWindow.swift` and Flutter's generated plugin registrant against the official bundled `FlutterMacOS.framework`: passed. This confirms Swift type correctness, not a native application launch.
- `flutter build macos --debug`: failed before building with `Xcode not installed; this is necessary for iOS and macOS development.`
- Collection and detail PNGs were captured from Flutter's real widget renderer for visual review. These are widget-only evidence, not a launched native app. Regenerate them with `flutter test --dart-define=VISUAL_OUTPUT=<output-directory> --dart-define=VISUAL_FONT=<CJK-font-file> --dart-define=VISUAL_ICONS=<Flutter-MaterialIcons-font-file>`. The optional renderer uses only explicitly supplied font paths; normal tests have no local font dependency.

All automatic behavior tests use temporary directories under the system temporary directory. No existing Obsidian vault was opened or modified, and no AI or paid service was called.

## Native acceptance still required

After full Xcode is installed and configured:

1. Run `flutter run -d macos`, create an empty temporary test directory, and select it through the native picker.
2. Enter Chinese text and a short title, save, inspect 正文 → 关联 → 来源 and the inline `记录：… · 修改：…` line, and check the note and exact original `.txt` in that test vault. Confirm no summary or native properties are displayed; the generated note has no frontmatter.
3. Quit and relaunch the native app. Verify directory bookmark restoration, recent record retrieval, detail, and original text.
4. Open that test folder as a vault in Obsidian, then use the app's Obsidian button to open the corresponding note. Confirm the source link opens the original text.
5. Revoke/move the selected directory and verify useful reselection/error feedback without losing entered text. Check the native picker cancellation path and the write-failure retry path.
6. Verify the dark RIGID BODY spacing, hard edges, readable content and state colors in the real native window, then build and launch a release `.app`.

Native directory authorization persistence, a launched app, native visual review and Obsidian handoff have **not** passed acceptance yet. Widget tests and Swift type checking do not replace them.
