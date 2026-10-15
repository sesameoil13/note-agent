# T01 validation — text collection on macOS

Issue: [#2](https://github.com/sesameoil13/note-agent/issues/2), parent [#1](https://github.com/sesameoil13/note-agent/issues/1).

Status: source, native clipboard integration, release launch and Obsidian note/source handoff validated; **the human paste and explicit normal-quit/relaunch checks are pending**. This record does not close the issue or declare the whole product delivered.

## Agreed seam

Tests drive the public `NoteWorkspace` interface and inspect visible workspace state plus actual Markdown/source files in fresh temporary vaults. The widget and native clipboard tests use that same real workspace. Time, identity and the system-file publisher are injectable external boundaries. No test inspects SQLite tables or private methods.

The interruption test injects a process interruption at the file-system boundary after writing a real partial staging file. It then reopens the real SQLite workspace, recovers pending publication, and checks complete files. It simulates the interruption; it does not claim that a device power-loss test was performed.

The necessary native integration test runs in a real macOS Flutter host without a mocked clipboard or mocked text-input connection. It sets and reads the system clipboard, focuses the app fields, dispatches Cmd+V through Flutter's keyboard/shortcut route, saves through `NoteWorkspace`, checks the actual source and Markdown, and reopens the workspace. Its key events are framework events; it does not exercise AppKit key-event delivery, the native Edit menu or accessibility automation.

## Executed on the current Apple Silicon Mac

Environment verified on 2026-10-15: Flutter 3.47.7, Dart 3.13.5, macOS 26.6.2 (build 25G83), Xcode 27.0 (27A266a), Apple Swift 6.4. The earlier missing-Xcode build gate is resolved.

- `flutter test test --reporter expanded`: 5 tests passed. Covers restart/recovery, exact ordinary-note template/source, durable original after a vault write failure and retry, interrupted publication recovery, protection of an unrelated existing note, and collection/list/detail/original viewing through the real workspace.
- `flutter analyze`: passed with no issues.
- `flutter test integration_test/native_clipboard_test.dart -d macos --reporter expanded`: 1 real macOS integration test passed in the coordinator's native validation run. Chinese multiline text reached the fields through Flutter's paste route, the complete original and ordinary Markdown were saved, and the workspace reopened successfully. This passed with unchanged production code; no app clipboard defect was reproduced by this test.
- Standard `flutter build macos --debug` and `flutter build macos --release`: passed in the coordinator's validation run under full Xcode; the release app was reported as 45.3 MB. The standard release app was subsequently launched and checked as described below.
- `codesign --verify --deep --strict` on the release app: passed in the coordinator's actual check, including the embedded Flutter, App and SQLite frameworks. The app was valid on disk and satisfied its designated requirement.
- Collection and detail PNGs were captured from Flutter's real widget renderer and visually reviewed. These are widget-only evidence. Regenerate them with `flutter test --dart-define=VISUAL_OUTPUT=<output-directory> --dart-define=VISUAL_FONT=<CJK-font-file> --dart-define=VISUAL_ICONS=<Flutter-MaterialIcons-font-file>`. The optional renderer uses only explicitly supplied font paths; normal tests have no local font dependency.

All automatic behavior tests use temporary directories under the system temporary directory. No existing Obsidian vault was opened or modified, and no AI or paid service was called.

## Native application observations

The coordinator launched the native app and granted its system picker access to a newly created test vault. Ordinary keyboard entry saved the title `p` and original text `a`; the resulting `p.md` has 正文 → 关联 → 来源, no summary or YAML properties, and the inline `记录：… · 修改：…` line after the source link. The actual source file contains `a`. A subsequently launched release process restored the persisted record and directory, as described below; an explicit normal-quit/relaunch cycle has not yet been verified.

The coordinator explicitly added only the newly created acceptance test folder through Obsidian's Open Vault → Open local folder flow. No Sync connection was configured and no old-vault or remote-vault switch occurred. The standard release app was then launched as a new process from its release build output and restored the persisted SQLite `p`/`a` record and directory bookmark without showing the picker. Its basic collection/list/detail interface ran in the native release window. A later process check showed both the earlier debug process and the new release process still live; the earlier automated Quit attempt therefore does not establish a complete normal-quit/relaunch cycle.

From the selected release-app record, “在 Obsidian 打开” opened the correct note: the observed Obsidian window title was `p - vault - Obsidian1.14.4`. The note showed exactly the three approved sections and the inline dates. After switching Obsidian to Reading view, clicking “原始文字” opened the generated `de9b5f5916b28f22d6fdfb5b313776bf.txt` attachment in TextEdit with the exact original value `a`. The opened path matched the note's generated source attachment. The note/source handoff therefore passed in the actual installed applications.

Accessibility automation attempts using set-value, paste and type-text reported changed accessibility values while the displayed Flutter field and saved controller value stayed unchanged. This is distinct from the passing native clipboard/framework shortcut test. The exact accessibility/input-route cause has not been isolated; there is no justified production fix from the current evidence.

## Native acceptance still required

1. Complete the human check of actual macOS keyboard/menu delivery of a Chinese paste independently of accessibility value-setting. The coordinator has requested a Chinese paste and save under the title `粘贴验证`; no result has been recorded yet. The native integration test validates Flutter's shortcut and clipboard service route only.
2. Perform and verify an explicit normal quit followed by relaunch of the native app. Fresh-process SQLite and bookmark restoration has passed, but both earlier processes were still live at the last process check.
3. Check native picker cancellation and unavailable/revoked directory feedback without losing entered text. The filesystem failure/retry behavior already has automatic coverage; these native permission failure paths remain unverified.

The native clipboard test, debug/release builds, release signature integrity check, fresh release process restoration of the directory/record, and actual Obsidian note/source handoff are concrete completed checks. Final disposition of T01's three GitHub acceptance criteria remains pending the remaining input and normal-quit/relaunch evidence. This checklist does not declare the later tickets or the entire product complete, and no test-vault Sync behavior has been accepted.
