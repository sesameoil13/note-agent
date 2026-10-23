# T03 Windows text collection — acceptance pending

Issue [#4](https://github.com/sesameoil13/note-agent/issues/4) remains open. Windows runner/adapters are implemented in source; no Windows build or Windows 11 runtime result has been obtained. Passing macOS tests does not satisfy this ticket's platform acceptance.

## Implemented boundaries

- Windows' `IFileOpenDialog` selects an existing filesystem folder. Cancellation leaves the previous selection intact. No vault is discovered automatically.
- The app records only the selected path under `HKCU\Software\NoteAgent\VaultDirectory`. This is a desktop filesystem selection, not a sandbox permission grant. Windows ACLs still apply; unavailable saved folders return a visible error and can be selected again.
- Private local state lives under `%LOCALAPPDATA%\dev.noteagent\workspace`; the selected vault holds the same ordinary-note Markdown and original text as on macOS.
- File publication flushes a private staging file then calls Unicode `MoveFileExW` without replacement or cross-volume-copy flags. An existing destination remains untouched; retry checks a previously committed file's contents. macOS continues using its existing POSIX publisher.
- Obsidian handoff resolves existing file and vault handles, checks that the file lies inside that vault, percent-encodes the Unicode path, and opens the `obsidian:` URI through `ShellExecuteExW`. A missing handler returns app feedback.

The native clipboard integration test uses Ctrl+V on Windows and Cmd+V on macOS. Its generated key events remain framework-driven integration coverage; they do not replace physical keyboard/IME acceptance.

## Evidence obtained on 2026-10-15

- macOS ARM64: `flutter test` passed all 5 existing workspace/widget tests; `flutter analyze` passed. These cover source/template persistence, failure and retry, interruption recovery, existing-file preservation, and the visible capture flow on the host platform.
- A Windows platform integration test was written before its native adapter. Attempting `flutter test integration_test/windows_platform_test.dart -d windows` could not start because this macOS host has no Windows Flutter device. No behavioral red/green result is claimed for it.
- Read-only Parallels inventory identified an existing **stopped Windows 11 ARM64 VM**, with 4 CPUs and 6GB RAM. The root coordinator authorized a CLI boot and task-limited guest inspection. Boot failed because the Parallels activation period had expired. No guest command, installation, license change, or purchase was performed.
- A manual Windows build workflow draft is retained locally outside the repository. The integration head has no runnable workflow file; the draft has never been registered on the default branch or dispatched. Its reviewed design uses `workflow_dispatch` as the only trigger, one `windows-2025` x64 job with a 30-minute limit, `contents: read`, official actions pinned to commit hashes, checksum-pinned official Flutter 3.47.7, and a release-only ZIP capped at 100 MiB and retained for one day. Registration, repository permissions and explicit bounded-cost authorization must be resolved before any later dispatch. A hosted runner can validate compilation/tests; it cannot establish Windows 11 desktop acceptance.

## Hosted Windows CI (2026-10-24)

Workflow `windows-build.yml` (manual `workflow_dispatch` on `main`, input `ref`, `windows-2025` x64, Flutter 3.47.7) was run against branch `claude/windows-t03-t10-t22`. **Run [40024648028](https://github.com/sesameoil13/note-agent/actions/runs/40024648028) at `9cf6aa8` is fully green**: `flutter test` 301 passed, 3 skipped (the macOS-only native inspection test and the two `chmod` cases below); `flutter analyze` reports no issues; the x64 release build succeeded; the release bundle was packaged within the 100 MiB cap and uploaded.

Runs and what each revealed:

1. [40015588926](https://github.com/sesameoil13/note-agent/actions/runs/40015588926): first real Windows result. `flutter test`: 284 passed, 19 failed. Build: C++/WinRT needs C++20 (the C++17 `/await` coroutine headers were removed), and `small` is an `rpcndr.h` macro.
2. [40017022299](https://github.com/sesameoil13/note-agent/actions/runs/40017022299): the release build **compiles and links** (runner, Media Foundation, C++/WinRT). Tests unchanged, plus one more timing-sensitive UI failure.
3. [40019298687](https://github.com/sesameoil13/note-agent/actions/runs/40019298687): with the fixes below, 298 passed and 3 failed (timing-sensitive UI tests only).
4. [40021136981](https://github.com/sesameoil13/note-agent/actions/runs/40021136981) and [40022692622](https://github.com/sesameoil13/note-agent/actions/runs/40022692622): only timing failures remained. The local Worker harness sometimes needs more than 15 s to start on the runner, and a budget release outlasts fixed waits.
5. [40024648028](https://github.com/sesameoil13/note-agent/actions/runs/40024648028): green.

Windows defects the hosted run found in shared Dart code (none visible on macOS):

- **Every vault write failed for paths containing `/`.** The publisher prefixes `\\?\`, which turns off Win32 normalization, so a mixed `C:\...\x/vault\note.md` path was rejected. Paths are now normalized before the prefix is added.
- **Vault-relative paths used `\` on Windows.** Link rewriting on rename, inbound links and attachment links assume `/` (as Obsidian does). `DirectoryVaultStorage` now always returns `/`-separated relative paths and accepts either separator.
- **PDF open errors were lost.** PDFium stores its error code in the thread's Win32 last error, and the Dart runtime can overwrite that between the two FFI calls. Locked and damaged PDFs then showed the generic "cannot open" message. When the code is lost, the file is now classified from its bytes (`/Encrypt` means a password is required; otherwise it is treated as damaged).
- **No Windows folder pick for the read-only backup comparison** (`chooseFolder`). It is now implemented with `IFileOpenDialog`; the choice is never persisted.

Test-only portability changes: separator-neutral path expectations. UI tests that waited a fixed 50 to 100 ms for real file, SQLite or loopback work now poll (`test/support/async_settle.dart`), because the hosted runner's disk is slower. The Worker harness startup bound is 60 s. The two recycle-bin cases that make the vault unwritable with POSIX `chmod` are skipped on Windows; their Dart logic is platform-independent and still runs on macOS.

Runner build settings: C++20; `/W4 /WX`; C++ exceptions enabled, because the DPAPI store and C++/WinRT throw; SDK headers compiled with `/external:W0`. Links Media Foundation and `windowsapp`.

What a hosted runner proves: `flutter test`, `flutter analyze` and `flutter build windows --release` on x64 Windows Server. It does not prove the folder picker, Obsidian handoff, physical keyboard/IME, microphone, toasts, Windows 11 desktop behaviour or ARM64 execution. The gate below is unchanged.

## Remaining native gate

Use an available, appropriately licensed Windows 11 machine and a fresh local test vault. Record the actual OS build and processor architecture. Install/configure Flutter 3.47.7 and Visual Studio's required Windows desktop C++ toolchain according to [Flutter's Windows setup instructions](https://docs.flutter.dev/platform-integration/windows/setup); account or license prompts require the machine owner.

```powershell
flutter pub get --enforce-lockfile
flutter test --no-pub
flutter analyze --no-pub
flutter build windows --release --no-pub
flutter test integration_test/windows_platform_test.dart -d windows
flutter test integration_test/native_clipboard_test.dart -d windows
```

Coordinate native integration-test launches with the session owner, since they open a window and the clipboard test temporarily writes the system clipboard. Open the entire release bundle's `note_agent.exe` on that Windows 11 machine, then record:

1. System folder picker cancellation and selection of a new test vault; no existing user vault is used.
2. Physical Chinese input and Ctrl+V, saving, clear 正文 → 关联 → 来源 ordering, exact original text, and timestamps after the source link.
3. A controlled write failure preserves local original text and shows a useful error; retry after correcting the test folder succeeds without duplicate records or replacement of unrelated files.
4. Normal quit, process exit, relaunch, restored selected directory, persisted record, original source and template. A reopened in-process workspace alone is insufficient evidence for this step.
5. Real Obsidian installed and the same test directory registered locally; the button opens the corresponding Unicode/space-containing note. Also verify absent-handler feedback on a suitable clean test setup.
6. Moved/unavailable directory feedback and recovery through the picker. Record any remaining permission-edge gaps under the final platform/setup tasks.

Only after real Windows results are recorded should the three issue acceptance criteria be considered for completion. An x64 hosted build does not validate ARM64 execution in the unavailable VM.

## Primary references

- [Windows folder-dialog options](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/ne-shobjidl_core-_fileopendialogoptions)
- [MoveFileExW flags and failure semantics](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
- [ShellExecuteExW](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shellexecuteexw)
- [Official Flutter Windows release manifest](https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json)
