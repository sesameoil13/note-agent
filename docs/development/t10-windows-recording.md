# T10 Windows recording — source and acceptance boundaries

Issue [#11](https://github.com/sesameoil13/note-agent/issues/11) stays open until real Windows 11 results are recorded. Windows uses the same public `NoteWorkspace` recording actions and `dev.noteagent/audio` channel as macOS/Android (`MethodChannelAudioPlatform`); business rules, queue adoption, vault publication and recovery stay in Dart. No upload, AI call or paid service is involved.

## Native adapter (`windows/runner/native_audio.cpp`)

- **Capture:** Media Foundation device source for the default console capture endpoint (`MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_ROLE = eConsole`) → source reader (float32 or PCM16/32 at the device mix rate) → own downmix to mono and linear resample to 44.1/48 kHz → sink writer, AAC-LC in an MPEG-4 (`.m4a`) container. Only explicit Start opens the microphone.
- **Access check before any file exists:** Start returns only after the first buffer is read. `E_ACCESSDENIED` (Windows privacy: "Microphone access" / "Let desktop apps access your microphone" off) becomes `microphone_denied` with the Settings path; a missing or failing device becomes `microphone_unavailable` with the HRESULT. Desktop apps get no OS prompt on Windows; nothing changes system settings.
- **Pause/resume:** the device keeps running while paused and buffers are discarded; samples are re-timed from the written frame count, so recorded time freezes during pause, as on macOS.
- **Ten-minute cap:** enforced natively by frame count (600 s), independently of Flutter polling; the worker finalizes and reports `stopped`, and workspace polling saves it.
- **Device loss mid-capture:** reader error/end-of-stream finalizes what was written and reports `stopped` with an error ("录音设备中断…"), so the original is retained and the UI does not claim a clean capture.
- **Playback:** Media Engine (`MF_MEDIA_ENGINE_AUDIOONLY`) from a file byte stream; the original is first opened and decoded through a source reader so an unreadable file fails with feedback instead of silently.
- **Import inspection (`inspectAudioSource`):** same rules as macOS — only workspace-owned `audio-sources\<id>\<file>` or `recordings\<id>.m4a`, no links, ≤ 256 MB, container from magic bytes (ftyp / RIFF-WAVE / ID3 or MPEG sync) matched to the decoded codec (AAC / PCM / MP3), duration and parameters bounded, decode windows at start, middle and tail.

## Durability and recovery

As on macOS, SQLite commits the stable ID and original path before Start. Additionally, closing the window (`OnDestroy`) and `WM_ENDSESSION` finalize the container. After every clean finalize the recorder writes `<original>.m4a.done` (flushed, atomic rename). On the next launch `recoverRecording` (now enabled on Windows as on Android) trusts only that exact original with a journal **and** a successful decode, and the workspace finalizes it under the same ID through the normal validation/queue/vault path. Process kill, crash or power loss leave an unfinalized MP4 without an index; with no journal it stays a retained original marked interrupted, with a playback attempt, exactly as on macOS.

## Known gap: vault size at 96 kbit/s

The Windows AAC encoder accepts only 44.1/48 kHz input and 12,000–24,000 bytes/s output ([AAC Encoder](https://learn.microsoft.com/en-us/windows/win32/medfound/aac-encoder)); the app uses the minimum, 96 kbit/s (macOS uses 32 kbit/s at 22.05 kHz). A ten-minute Windows original is about 7.2 MB, above the 5 MB vault-attachment limit (`SyncPolicy.maximumFileBytes`). Originals longer than about 6 min 56 s therefore stay local with the existing visible "only on this device" status; shorter ones are copied to the vault. The recorder page states this on Windows. A lower-bitrate path (another encoder/container) would need a product decision.

## Headless evidence (macOS host)

- `test/method_channel_audio_test.dart`: an adapter with native recovery asks for that exact original and maps the native stopped snapshot; without it, no completion is claimed and the OS is not asked. Red seen before the change.
- `flutter analyze` clean; full `flutter test` result recorded in the branch report.
- Windows CI (hosted `windows-2025` x64): the Media Foundation adapter compiles and links in the release build since run [40017022299](https://github.com/sesameoil13/note-agent/actions/runs/40017022299); see t03-validation.md for the full run history. A hosted runner has no microphone, speaker or interactive desktop, so nothing above is exercised at runtime there.

## Requires real Windows 11 desktop acceptance

- [ ] First Start with microphone privacy on/off (both toggles), denied feedback and retry after allowing.
- [ ] No input device / unplug during capture: feedback, retained original, playback attempt.
- [ ] 15 s, ~5 min and full 10 min captures with pause/resume; measured level moves; auto-save at 10 min.
- [ ] Playback of the saved original and of imported M4A/MP3/WAV; inspection rejects other formats.
- [ ] Close the window while recording → relaunch recovers the same recording as saved; kill the process while recording → interrupted original retained.
- [ ] Originals ≤ 5 MB appear in the vault; longer ones stay local with the visible status.
