# T11 local audio import and processing queue

Production has no audio processor or budget adapter. Imported and finalized
recorded audio is retained and remains **待处理 · 处理服务未连接**. No transcript,
AI completion, paid request or cloud connection is invented. The controlled
processor used below exists only in tests.

## Public workspace behavior

`NoteWorkspace.importAudio(original:, submissionId:)` accepts an ephemeral
picker file. The UI chooses a submission token once, disables duplicate import
actions, and releases source access only after the workspace has retained its
private original. An incomplete import can reselect the file using the same
persisted token. Repeating a token with different complete bytes is rejected;
a new token may intentionally collect identical bytes.

The import journal precedes the bounded streaming copy/hash. A complete staging
file is flushed, its SHA-256 and length committed, and then atomically renamed
inside the private `audio-sources/<id>/` directory. Startup reconciles a complete
staging file or renamed original against its journal. Partial/missing originals
remain explicitly incomplete and require reselection. Unsupported inputs retain
the exact original and a specific reason. A failed copy never claims a saved
original. Existing finalized captures join the same queue with their existing
recording ID; interrupted, unfinalized captures are not automatically processed.

`audioSources` exposes original, inspection, processing and vault-publication
facts independently. Publication uses the existing binary vault and atomic
publisher. The conservative Standard limit remains 5,000,000 bytes. Larger
originals stay private without being rejected by audio inspection merely because
of that Sync limit. Once processing produces a note, its existing attachment
policy applies, including a blocked Sync status for an oversized original.

`resumePendingAudioProcessing()` is the idempotent lifecycle/connectivity hint.
The app calls it after reopening, importing and resuming. It runs one job at a
time, committing claims/checkpoints in short workspace mutations around external
work. Text capture remains usable while the processor waits. `close()` stops
scheduling, checkpoints interrupted work and ignores late callbacks without
waiting for a blocked processor.

Processing persists the full transcript before organizing and persists the
organized result before publishing one previously allocated note ID. An output
write retry reuses both results and that ID. Full transcript and organized body
remain distinct (`WorkspaceNote.originalText` versus `text`). Source Markdown
links to the full transcript and uses the original publication facts; uncertain
publication is never called definitely local-only.

Recoverable failures schedule at most three automatic retries after the initial
attempt, after 5, 10 and 20 seconds. Counts and deadlines survive restart. A
manual retry preserves source/output identity and starts a new bounded retry
allowance. Credentials, balance, budget, unsupported/invalid results and unknown
request outcomes do not automatically loop. The clock is injectable; production
uses the real system clock and timer. An interrupted adapter request is replayed
only when that adapter explicitly guarantees safe replay. Future paid adapters
must reserve/settle budget and reconcile ambiguous outcomes themselves; local
idempotency does not establish remote exactly-once billing.

## Inspection and platform scope

macOS has a separate import inspection/player capability restricted to exact
workspace-owned `audio-sources/<id>/<name>` or existing recording originals.
Symlink escapes and external picker paths are rejected. Core Audio detects the
container/codec and AVFoundation decodes bounded first/middle/tail windows.
WAV/PCM, M4A/AAC and MP3 were checked with real files; misleading extensions do
not grant format support. Inspection is serialized, limited to 256 MiB and
24 hours, and the caller stops waiting after 10 seconds. A timed-out OS decoder
remains serialized until it returns, preventing a pile of duplicate probes.

The portable inspector checks actual complete PCM WAV structure and frames with
bounded header reads. It explicitly reports other formats unsupported on
platforms without the native decoder. Android/Windows native compressed-audio
inspection and playback are not claimed. The shared source picker is T06's
optional `audioOnly` capability; Android streams SAF content into private storage
and FileProvider grants source opening only from the existing private allowlist
plus the narrow `audio-sources` addition. Android build/device and Windows native
acceptance remain deferred/unavailable in this session.

## Verification

The agreed main test seam is NoteWorkspace with real temporary files, real WAV
structure, real SQLite recovery, a loopback controlled processing service, and
clock/system adapters. Tests do not query private SQL or test private helpers.

```sh
flutter test test/audio_queue_test.dart test/audio_import_ui_test.dart
flutter test test/audio_native_inspection_test.dart
python3 tool/check_audio_crash_recovery.py --flutter /path/to/flutter --output /fresh/output
flutter analyze
flutter build macos --release
```

The crash harness sends SIGKILL to the actual worker process, with no `close()`,
after rename, during transcription, after the transcript checkpoint, and after
Markdown publication before acknowledgement. Reopening/replaying must produce
one stable source and one note. Evidence is written through public results.

The headless native test compiles the in-app inspector, generates real WAV/AAC,
and checks scope rejection and a truncated M4A. Set `T11_MP3_FIXTURE` to the
separately acquired FFmpeg FATE `mpegaudio/extra_overread.mp3` fixture to include
its native MP3 check; tests never download it. This test corpus remains outside
the repository. Host full-suite setup additionally uses the existing pinned
local pairing dependencies and the bundled Node runtime; no remote services
are involved. A macOS build/headless decoder pass does not replace actual native
picker, playback, permission, restart and platform acceptance.
