# T09 Android recording — source and acceptance boundaries

The Android adapter uses the same public `NoteWorkspace` recording actions as
macOS. Microphone access begins only after explicit Start in the visible App.
The native permission request checks microphone separately from notification:
denying notifications does not deny a granted microphone. A denied microphone
returns an actionable error and permits retry without a completed-capture claim.

A non-exported microphone foreground service owns MediaRecorder, with a visible
ongoing notification when the system permits notifications. The notification can
pause/resume or end capture and return to the App. It captures mono 22,050 Hz AAC
at 32,000 bit/s into a private M4A original. Native duration and size limits stop
capture even while Flutter cannot poll. Pause freezes accumulated recording time;
the service also bounds total lifetime including pauses to 30 minutes. The UI
states these rules. No recording is automatically restarted after process death.

Locking or switching Apps leaves the service recording, subject to Android and
HyperOS restrictions. Removing the task normally requests native finalization.
Android force-stop, process kill, power loss and OEM termination may skip all
callbacks; unfinished containers remain retained originals marked interrupted.
System-silenced capture and native errors end capture with an explicit error.
No battery exemption, autostart permission, broad storage grant, boot receiver,
or global privacy setting change is requested by this implementation.

## Durability and recovery

SQLite commits the stable ID and private original path before native Start.
The service writes a fsynced atomic journal beside that exact original. It marks
completion only after stopping/releasing the recorder, flushing the source and
inspecting actual container magic, audio track metadata and packet timestamps.
An OS known-limit stop can already be asynchronous when its callback arrives;
a redundant native Stop error at that limit is accepted only if subsequent
container inspection succeeds. This is not a claim that every packet was decoded.

On workspace restoration, `AudioRecordingRecovery` asks the OS about that exact
path. A live service restores record/pause state and polling. A confirmed completed
container follows the normal original-validation, queue-adoption and vault-export
path with the same ID. Missing, unreadable or incomplete journal data establishes
no successful completion. Even a partially written file left by failed Start is
listed as interrupted, retains its byte count and permits a playback attempt;
playback failure never deletes it. An interrupted original is not queued as ready
for AI processing. Exports use the existing SAF `BinaryVaultStorage` boundary.

Local save and vault publication do not establish official Obsidian Sync delivery.
The service and player do not upload audio or invoke AI. Native imports inspect
actual M4A/AAC, WAV/PCM or MP3 bytes, not picker filenames; unsupported originals
remain retained. The microphone adapter shares this inspector with queue adoption.

## Headless evidence

Pre-agreed seams: public `NoteWorkspace`, real temporary files/SQLite, and the OS
microphone/player boundary. TDD skill plus its tests/mocking references were read.

- Completed native recovery: a real Flutter host test process is SIGKILLed after
  public Start commits its ID/source. A second process initially failed because
  the completed original was marked interrupted. It now recovers the native
  completion, duration, original bytes, same queue ID, vault export and playback.
- Live paused recovery: a second red showed idle instead of paused after the
  killed process. The new process now restores the native 15-second paused state,
  resumes and saves one stable recording through public actions.
- Failed native Start after partial output: red showed failed/zero-byte metadata.
  It now exposes interrupted, the real three-byte original, no vault/AI success,
  and an honest failed playback attempt while preserving those bytes.
- The existing macOS recording/permission/vault-retry/UI regressions remain in
  the host suite. All 112 host tests passed with pinned Node and the local Worker
  harness dependencies; no external endpoint, API Key or cloud model was used.
- `flutter analyze --no-pub` passed. Release ARM64 compilation passed. Exact final
  candidate signature/alignment/hash are recorded in the handoff evidence outside
  the repository. A build is not a real microphone/HyperOS acceptance result.

Run the two host crash probes in fresh output directories:

```sh
python3 tool/check_recording_recovery.py --flutter /absolute/path/to/flutter --output /fresh/finished
python3 tool/check_recording_recovery.py --flutter /absolute/path/to/flutter --phase active --output /fresh/active
```

The subprocess microphone is controlled; SIGKILL affects only these test process
groups. No phone, real microphone or App process is operated by these probes.

## Root-owned physical acceptance (pending)

The known phone is Xiaomi `2509FPN0BC`, Android 16/API 36, HyperOS OS3.0 build
OS3.0.319.0.WPBCNXM. Root read these conditions from the authorized USB device;
the implementer performed no device operations. Use only `NoteAgent-Test-T02`.
Install the reviewed development-signed ARM64 APK with normal update semantics,
preserving prior notes and grants. The user owns microphone/notification dialogs.

1. Deny microphone once, verify no recording/timer or false saved result, then
   grant in the App/system prompt or settings and retry. Record notification choice.
2. Record at least 15 seconds with real speech; observe measured waveform/timer,
   pause stability, resume and save. Play the original and obtain human audibility.
   Verify private/vault retained originals through the authorized test boundary.
3. While recording, switch screens/Apps and lock for a bounded interval. Return
   and inspect actual timer/state and audible retained speech. Exercise notification
   pause/save if notification permission was granted. Record any HyperOS limit.
4. During a separate capture remove Note Agent from recents, then reopen: expect
   the same finalized source, or an honest interrupted source if HyperOS killed it
   before completion. Saved originals and queue identities must remain available.
5. Verify the approximate ten-minute native cutoff without relying on an open
   Flutter recorder screen. Keep timing/bytes/decode evidence honest, including
   any platform limitation. Normal reopen must retain saved originals and grant.

An optional checked-in real-microphone integration run validates the short
pause/save/native-inspection/play/reopen path through `NoteWorkspace`:

```sh
flutter test integration_test/android_recording_test.dart -d DEVICE \
  --dart-define=ANDROID_TEST_VAULT_NAME=NoteAgent-Test-T02 \
  --dart-define=ALLOW_ANDROID_MICROPHONE_TEST=true
```

The two guards prevent generic test discovery from recording or writing a
personal vault. This run requests real microphone access; only root may run it
after authorization. It does not establish lock screen, notification controls,
process death, physical denial or human audibility. Restore the ordinary Release
APK after any framework harness run. Do not close #10 until actual gates pass.

Build sequentially after host tests with `flutter build apk --release
--target-platform android-arm64` (normal pub resolution, unchanged lockfile).
In this dormant checkout, using `--no-pub` initially retained a generated
integration-test plugin registrant incompatible with Release; normal Flutter
generation corrected it. No generated plugin source is committed or hand-edited.
