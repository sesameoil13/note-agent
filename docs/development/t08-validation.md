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

## Native acceptance still pending

Root coordinates all actual app/native GUI interaction against a dedicated test
vault. No implementer has launched the app or changed microphone permissions.
Before closing #9, collect real evidence for:

1. Initial microphone permission, a denied attempt and a later allowed retry.
2. Real 15-second recording with changing measured waveform and timer.
3. Pause with stationary recording time, resume, stop and audible local playback.
4. Offline save, normal app quit/relaunch and finding/replaying the same original.
5. Ten-minute real capture and actual original size (synthetic evidence above is
   separate), plus any hardware interruption result that is actually exercised.

Use the app's `录音` page; the operating-system permission prompt is user-owned.
Do not touch the old vault or reset global privacy settings for this check.
