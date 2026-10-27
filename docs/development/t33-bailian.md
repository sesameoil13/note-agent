# T33 AI service: Alibaba Cloud Bailian instead of OpenRouter (issue #34)

Decision: [ADR 0003](../adr/0003-bailian-instead-of-openrouter.md). Probe results are on issue
#34; the probe itself lives outside the repo (`qwen-probe/`).

## What changed

- **Key** (`lib/connection.dart`): checked by listing models at
  `https://dashscope.aliyuncs.com/compatible-mode/v1/models` (not billed). Saved as `aiKey` +
  `aiProvider: bailian-cn`. A device that only holds the old `openRouterKey` is asked to
  reconnect; that key stays on the device and is never sent anywhere.
- **Pairing** (`lib/pairing.dart`): config format 2 carries `aiProvider` + `aiKey`. A format-1
  payload (an OpenRouter key from an original device still on the old app) is refused before
  anything is saved or acknowledged.
- **Text** (`lib/text_model.dart`, `lib/text_processing.dart`): `qwen-plus`, `enable_thinking:
  false`, strict `json_schema`. The response id and token usage are saved as the receipt and
  replayed to settle. There is no cost lookup by id (probe Q9), so a response without usage keeps
  its hold until checked in the console. A job estimated before the switch is released for a new
  estimate instead of being sent.
- **Splitting** (`lib/audio_split.dart`): pure Dart. M4A (sample tables + AudioSpecificConfig,
  each frame rewrapped as ADTS), ADTS, MP3 frames (each later part starts with the earlier frames
  its bit reservoir borrows) and PCM WAV become as few equal parts as 4.5 min and 7 MB allow
  (base64 must stay under Bailian's 10 MB). Within the limits a file is sent unchanged.
- **Transcription** (`lib/audio_model.dart`, `lib/audio_processing.dart`): `qwen3-asr-flash`
  through `chat/completions` with the audio inline as a data URI and `enable_itn: false`. One
  budget attempt per part; a part's transcript and receipt are saved before the next part goes.
  The transcript is assembled as soon as every part has arrived, even if settling fails. A retry
  (or a new estimate after a cancelled retry) keeps finished parts and sends only the rest.
- **Worker** (`services/pairing/src/budget.mjs`): quotes with `provider: "bailian-cn"` come from
  `BAILIAN_PRICES`, frozen onto each quote; attempts settle from `usage` (tokens or seconds).
  Parts are bound by index (`chunk`, up to 8), at most 290 s and 7 MB each. Quotes without a
  provider still use OpenRouter, so older apps keep working during the switch. Migration
  `0005_bailian_budget.sql` adds `usage`.

- **Lost responses** (`lib/processing_recovery.dart`, `lib/console_charge_dialog.dart`):
  Bailian cannot look up a cost by id, so the budget panel offers 按控制台账单记录费用 on a text
  job with a pending cost and on a paused or completed recording. Each request the ledger still
  holds as sent or uncertain is shown with its hold; the amount the user reads in the console
  (0 if not billed) settles it as `confirmedCnyMicros`. Above the hold it is recorded as it is
  and pauses paid admission. A request the ledger already holds as settled (a reply lost after
  recording) is adopted into the job.

## Deploying

1. In the Bailian console (Beijing), read the per-second price of `qwen3-asr-flash` and the
   per-token prices of `qwen-plus`.
2. Set `BAILIAN_PRICES` as a Worker variable, in nano-元 (1 元 = 10⁹):
   ```json
   {"version":"2026-10-27","text":{"model":"qwen-plus","promptNanoCnyPerToken":800,"completionNanoCnyPerToken":2000},"transcription":{"model":"qwen3-asr-flash","secondNanoCny":<from console>,"minimumSeconds":1}}
   ```
   Without a valid table, Bailian quotes are refused (`quote_unavailable`); nothing is charged.
3. Apply migration `0005` and deploy the Worker **before** releasing the app (the deploy script
   backs up the database and asks before each change).
4. Release the Mac app, then Android and Windows. Each device reconnects once with the Bailian
   key (or pairs again to receive it).

## Tests

- `services/pairing/test/bailian-budget.test.mjs`: yuan quotes, frozen prices, part limits,
  missing price table, older apps after Bailian quotes exist.
- `test/bailian_connection_test.dart`: key check, saved key, old key kept, fixed endpoint,
  pairing format 2 and refusal of format 1 (real local Worker).
- `test/bailian_text_test.dart`, `test/bailian_transcription_test.dart`: request shapes,
  settlement in yuan, holds without receipts, parts in order, retry of one part, a settle failure,
  a cancelled retry estimate.
- `test/audio_split_test.dart`: fixtures in `test/fixtures/audio/` are 4 s of synthetic speech;
  the M4A conversion is checked frame by frame against Apple's own ADTS encoding.

## Not covered

- A real Bailian call from the app (the probe made the real calls), real recordings from each
  platform's recorder, and real MP3 files (no MP3 encoder was available; MP3 frames are
  synthetic).

