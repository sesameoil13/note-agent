# T08 macOS recording validation

T08 implements local microphone recording through AVFoundation, AAC source files,
pause/resume, measured waveform/time, a native ten-minute cap, original playback,
and workspace recovery. It does not transcribe or claim AI processing completed.
Android/Windows microphone adapters belong to their separate tickets.

## Source and headless evidence

- Existing host baseline: 5 tests passed at `5da8b14`.
- Public `NoteWorkspace` recording tracer failed at the missing API, then passed
  pause/resume, local/vault original bytes, stable identity, restart and playback.
- A second tracer failed because the ten-minute save depended on a visible
  recorder screen. Workspace polling now finalizes the capture independently.
- An interrupted-save tracer failed on a lost byte count. The retained original
  now remains visible with an interrupted status and a playback attempt.
- Additional system-boundary guards cover denied permission with retry, vault
  failure/retry after restart, interrupted source publication with restart, and a
  5,000,001-byte original staying local without a false vault-copy claim.
- After merging T04 source ancestor `7d4a529`, the combined host suite has 28
  passing tests and `flutter analyze` reports no issues. This includes the public
  recorder UI sequence start → pause at 15 seconds → resume → save → local play,
  plus late meter replies and meter failure keeping explicit Stop available.
- The live Mac workspace initially opens the recorder page, with a prominent
  recording entry and convenient text capture. Entering the page does not start
  the microphone; only the explicit Start action requests permission.
- Android SAF text behavior remains covered by its existing host regression.
  Audio controls are enabled only for the supported Mac directory workspace.
- macOS debug and release static builds include the native AVFoundation bridge and pass.
  Building does not establish microphone permission, real input or audible output.

## Encoding verification

A narrowly authorized, headless AVFoundation harness encoded synthetic PCM using
exactly the recorder's AAC settings: mono, 22,050 Hz, 32,000 bit/s, medium quality.
On macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Swift 6.4:

- Encoded duration: 600 seconds.
- Actual file: 2,216,071 bytes, below a conservative 5,000,000-byte cap.
- Decoded readback: 13,230,000 frames, all finite, nonzero PCM.
- Peak 0.181918; RMS 0.066961.

The harness and raw output live outside the repository under
`work/native-t08-codec/`. This proves codec/size behavior for synthetic audio; it
is not a microphone, permission, pause/resume or listening acceptance result.
The app also checks actual finalized file length before publishing to the vault.
An oversized source remains in app-local storage with a visible error.

## Durability and status

SQLite commits the stable recording identity and original path before microphone
start. The native recorder closes the encoded container before the workspace
validates duration, flushes the original and records a pending vault publication.
The app retains that original independently of vault export. Vault publication
uses a private staging file, flush, exclusive atomic commit and byte readback;
retry never replaces a different existing file. Source filenames use stable IDs.

An interrupted or invalid container stays visible as interrupted and can be tried
for playback; the UI does not declare it a completed capture. Recovering a pending
vault publication uses the same identity and original. Neither local save nor
vault publication asserts official Obsidian Sync delivery.

## Root-owned native acceptance

Root performed the actual app/native GUI checks against a dedicated test vault
on October 16–17, 2026. The user owned microphone permission decisions. No
implementer launched the app or changed microphone permissions. The complete
session record lives outside the repository at `work/research/t08-native-evidence.md`;
numeric-only metadata is in `work/native-t08-acceptance/`.

Candidate `097fe5e` recorded real microphone input with changing measured
waveform/time. Pause at 19 seconds froze recording time; resume continued the
same recording. The session was later found paused at 09:58 after an overnight
interval with unknown intervening human action. Root resumed the final seconds
and observed automatic saving without manual Stop. The original decoded to
599.257687 seconds of finite mono PCM at 22,050 Hz and occupied 2,457,517 bytes.
Private and vault copies matched by SHA-256. This verifies the observed
approximately ten-minute cap/save path, not uninterrupted overnight capture or
an exact 600.000-second duration.

Native local playback advanced from 00:00 to 00:54 before root stopped it; the
user confirmed it was audible. Normal Quit ended the process. Relaunch restored
the same recording ID, duration, size, saved status and selected vault without a
picker; local playback then advanced to 00:21 before root stopped it.

Physical OS denial and restoration were subsequently verified with the same
unchanged `74cd40d` Release binary. With Note Agent OFF in System Settings,
root quit and relaunched the app before Start. The app immediately showed
`录音未完成` / `麦克风权限未开启` / `未能开始录音`, stayed at 00:00 and enabled
Start again without claiming a finalized capture. After the user restored
Note Agent ON, root quit and relaunched that same binary again. Start produced
changing measured waveform/time; Stop saved a 52.381315-second, 239,350-byte
original with `本机原音频已保存 · 尚未转写`. The intended short check ran longer
because of tool/turn latency; it is not evidence of an exact 15.000-second capture.

The restored-permission original decoded locally to 1,155,008 finite mono PCM
frames at 22,050 Hz (peak 0.072491139, RMS 0.004519734). Private and vault copies
matched SHA-256
`3e080cc468e5c0a5f0b50bb218ee8547c8c0465812421f1765992521ce499c5e`.
Native local playback entered its playing state and later ended. The original
599-second recording remained byte-identical. See
`work/native-t08-acceptance/restored-permission-metadata.json` for numeric details.

Save, recovery and playback used local files; no transcription, remote service,
AI call or audio upload was involved. Host Wi-Fi was not physically disabled,
so this session does not prove a physical network-disconnection run.

Platform QA limit: switching permission OFF while the previous process was
still alive did not immediately invalidate its cached AVFoundation permission.
The accepted denial/restoration procedure therefore includes normal
Quit/relaunch after each user-owned toggle. Immediate live-process revocation
and hardware interruption remain unverified platform edges. No global privacy
reset or TCC/code-requirement weakening was used.

## Source follow-up after native observations

Root's native session found blank accessibility names on the compact icon-only
recording/recent/new-text controls and the recording-row play/stop control. A
public semantics test reproduced empty labels despite existing tooltips. The
controls now expose explicit names, enabled/button state and press actions while
preserving their appearance and callbacks. Headless accessibility actions navigate
those pages and start/stop workspace playback. Root's refreshed native AX check
on `74cd40d` found the compact header controls named, including `连接与设备`.

A storage operation may publish complete audio and fail while acknowledging its
result. The recording UI now reports “笔记库写入未确认” for an export failure,
without asserting the vault copy is absent. A real temporary-file public probe
checks this case, retained local playback, and one stable recording after retry;
the independent merger probe also passes.

The earlier accessibility/publication follow-up passed its complete 33-test host
suite, clean `flutter analyze`, and the independent publication-truth probe. It
was source-only: the running native bundle was neither rebuilt nor relaunched by
the implementer.

The completed physical denial check exposed a naming mismatch: System Settings
lists `Note Agent` (the configured macOS product name), while the error guidance
said `笔记工作区`. The finishing follow-up changes only that name in the guidance;
permission handling and audio behavior are unchanged.

Finishing verification on the `74cd40d` integration base: all 12 existing
recording workspace/UI tests pass, `flutter analyze --no-pub` is clean, and the
own-worktree macOS Release static build passes. No native launch or permission
prompt was performed for this copy/documentation change; root's running bundle
was untouched.
