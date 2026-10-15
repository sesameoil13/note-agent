# T01 validation — text collection on macOS

Issue: [#2](https://github.com/sesameoil13/note-agent/issues/2), parent [#1](https://github.com/sesameoil13/note-agent/issues/1).

Status: source and native clipboard integration validated; **native acceptance is in progress**. This record does not close the issue or declare the whole product delivered.

## Agreed seam

Tests drive the public `NoteWorkspace` interface and inspect visible workspace state plus actual Markdown/source files in fresh temporary vaults. The widget and native clipboard tests use that same real workspace. Time, identity and the system-file publisher are injectable external boundaries. No test inspects SQLite tables or private methods.

The interruption test injects a process interruption at the file-system boundary after writing a real partial staging file. It then reopens the real SQLite workspace, recovers pending publication, and checks complete files. It simulates the interruption; it does not claim that a device power-loss test was performed.

The necessary native integration test runs in a real macOS Flutter host without a mocked clipboard or mocked text-input connection. It sets and reads the system clipboard, focuses the app fields, dispatches Cmd+V through Flutter's keyboard/shortcut route, saves through `NoteWorkspace`, checks the actual source and Markdown, and reopens the workspace. Its key events are framework events; it does not exercise AppKit key-event delivery, the native Edit menu or accessibility automation.

## Executed on the current Apple Silicon Mac

Environment verified on 2026-10-15: Flutter 3.47.7, Dart 3.13.5, macOS 26.6.2 (build 25G83), Xcode 27.0 (27A266a), Apple Swift 6.4. The earlier missing-Xcode build gate is resolved.

- `flutter test test --reporter expanded`: 5 tests passed. Covers restart/recovery, exact ordinary-note template/source, durable original after a vault write failure and retry, interrupted publication recovery, protection of an unrelated existing note, and collection/list/detail/original viewing through the real workspace.
- `flutter analyze`: passed with no issues.
- `flutter test integration_test/native_clipboard_test.dart -d macos --reporter expanded`: 1 real macOS integration test passed in the coordinator's native validation run. Chinese multiline text reached the fields through Flutter's paste route, the complete original and ordinary Markdown were saved, and the workspace reopened successfully. This passed with unchanged production code; no app clipboard defect was reproduced by this test.
- Standard `flutter build macos --debug` and `flutter build macos --release`: passed in the coordinator's validation run under full Xcode; the release app was reported as 45.3 MB. A successful build alone does not establish release UI acceptance.
- Collection and detail PNGs were captured from Flutter's real widget renderer and visually reviewed. These are widget-only evidence. Regenerate them with `flutter test --dart-define=VISUAL_OUTPUT=<output-directory> --dart-define=VISUAL_FONT=<CJK-font-file> --dart-define=VISUAL_ICONS=<Flutter-MaterialIcons-font-file>`. The optional renderer uses only explicitly supplied font paths; normal tests have no local font dependency.

All automatic behavior tests use temporary directories under the system temporary directory. No existing Obsidian vault was opened or modified, and no AI or paid service was called.

## Native application observations

The coordinator launched the native app and granted its system picker access to a newly created test vault. Ordinary keyboard entry saved the title `p` and original text `a`; the resulting `p.md` has 正文 → 关联 → 来源, no summary or YAML properties, and the inline `记录：… · 修改：…` line after the source link. The actual source file contains `a`. The saved record was recovered after the app was quit and relaunched, exercising the selected-directory bookmark restoration.

The Obsidian button handed the URI to the installed Obsidian app. Obsidian reported that the test folder had not yet been registered as a vault. End-to-end opening of the correct note and its source therefore remains unverified at this stage.

Accessibility automation attempts using set-value, paste and type-text reported changed accessibility values while the displayed Flutter field and saved controller value stayed unchanged. This is distinct from the passing native clipboard/framework shortcut test. The exact accessibility/input-route cause has not been isolated; there is no justified production fix from the current evidence.

## Native acceptance still required

1. Open the fresh test folder as a vault in Obsidian, then verify the app opens the corresponding note and the source link opens the original text. Confirm the approved reading order and hidden properties there.
2. Verify actual macOS keyboard/menu delivery of a Chinese multiline paste independently of accessibility value-setting. The native integration test validates Flutter's shortcut and clipboard service route only.
3. Check native picker cancellation and unavailable/revoked directory feedback without losing entered text. The filesystem failure/retry behavior already has automatic coverage.
4. Launch the standard release `.app` and complete the native visual review of readable content, hard edges, spacing and state colors.

The native clipboard test, debug/release builds and successful app relaunch are concrete completed checks. The remaining observations above must not be marked passed solely from widget renders or framework-generated key events.
