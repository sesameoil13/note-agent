# T01 validation — text collection on macOS

Issue: [#2](https://github.com/sesameoil13/note-agent/issues/2), parent [#1](https://github.com/sesameoil13/note-agent/issues/1).

Status: **T01's three core acceptance criteria are met and ready for ticket resolution after integration**. Native Chinese paste, normal release quit/relaunch, and Obsidian note/source handoff have passed. This record does not close the issue or declare the whole product delivered.

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

The coordinator launched the native app and granted its system picker access to a newly created test vault. Ordinary keyboard entry saved the title `p` and original text `a`; the resulting `p.md` has 正文 → 关联 → 来源, no summary or YAML properties, and the inline `记录：… · 修改：…` line after the source link. The actual source file contains `a`. The release process restoration and subsequent verified normal-quit/relaunch cycle are described below.

The coordinator explicitly added only the newly created acceptance test folder through Obsidian's Open Vault → Open local folder flow. No Sync connection was configured and no old-vault or remote-vault switch occurred. The standard release app was then launched as a new process from its release build output and restored the persisted SQLite `p`/`a` record and directory bookmark without showing the picker. Its basic collection/list/detail interface ran in the native release window. This initial fresh-process restoration was followed by the explicit release quit/relaunch check below.

The user explicitly confirmed that physical Cmd+V pasted Chinese text and that saving it worked normally. The coordinator then inspected `粘贴验证.md` and its actual source attachment: the note had exactly the three approved headings and the source agreed with the body (42 characters). The user-entered body is not reproduced in this validation record.

The coordinator then used the release app's normal Quit menu action and checked the process list: release PID 49289 was absent. Launching the exact standard release app created a new process, PID 49594. The directory was restored without a picker, the recent-record count was two, and the saved Chinese record's detail, source and inline dates were visible. The earlier debug process remained live and is not part of this verified release quit/relaunch claim.

From the selected release-app record, “在 Obsidian 打开” opened the correct note: the observed Obsidian window title was `p - vault - Obsidian1.14.4`. The note showed exactly the three approved sections and the inline dates. After switching Obsidian to Reading view, clicking “原始文字” opened the generated `de9b5f5916b28f22d6fdfb5b313776bf.txt` attachment in TextEdit with the exact original value `a`. The opened path matched the note's generated source attachment. The note/source handoff therefore passed in the actual installed applications.

Accessibility automation attempts using set-value, paste and type-text reported changed accessibility values while the displayed Flutter field and saved controller value stayed unchanged. This is distinct from the passing native clipboard/framework shortcut test. The exact accessibility/input-route cause has not been isolated; there is no justified production fix from the current evidence.

## T01 acceptance result

| GitHub criterion | Evidence | Result |
| --- | --- | --- |
| Approved minimal collection, list and detail interface running on the current Mac | Actual standard release app observed; physical Chinese paste/save confirmed; native record detail and recent list checked | Passed |
| Durable text survives restart; ordinary note has only 正文 → 关联 → 来源, no summary/properties, and inline collection/modification dates after the source | Real Markdown/source checks, public-interface recovery tests, and verified normal release quit/relaunch with Chinese detail restored | Passed |
| Public NoteWorkspace interface and actual temporary vault files, without touching an old vault | Five behavior/widget tests, one real native clipboard integration test, and a dedicated fresh native acceptance vault | Passed |

## Broader validation still unverified

Native picker cancellation and unavailable/revoked/moved-directory feedback without losing entered text have not yet been exercised. Filesystem failure/retry behavior already has automatic coverage. Carry these native setup/platform scenarios into [T28 / #29](https://github.com/sesameoil13/note-agent/issues/29) and [T29 / #30](https://github.com/sesameoil13/note-agent/issues/30).

T01 covers this first local text slice. Its acceptance does not establish the later tickets or the entire product, and no test-vault Sync behavior has been accepted.
