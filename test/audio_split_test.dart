import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/audio_split.dart';

/// Fixtures: 4 s of Mandarin speech made with macOS `say` + `afconvert`,
/// encoded as the app records (AAC 22050 Hz mono 32 kbps .m4a), as ADTS
/// .aac and as 16-bit 16 kHz .wav. The .aac carries the same 90 AAC frames as
/// the .m4a (checked with an independent script), so it is the answer key for
/// the .m4a conversion.
List<int> fixture(String name) =>
    File('test/fixtures/audio/$name').readAsBytesSync();

/// ADTS frames as (header, payload); header length 7 or 9 with CRC.
List<(List<int>, List<int>)> adtsFrames(List<int> b) {
  final frames = <(List<int>, List<int>)>[];
  var i = 0;
  while (i < b.length) {
    expect(b[i], 0xFF);
    expect(b[i + 1] & 0xF0, 0xF0);
    final length = ((b[i + 3] & 3) << 11) | (b[i + 4] << 3) | (b[i + 5] >> 5);
    final header = (b[i + 1] & 1) == 1 ? 7 : 9;
    frames.add((b.sublist(i, i + header), b.sublist(i + header, i + length)));
    i += length;
  }
  return frames;
}

/// A synthetic MPEG-1 Layer III stream: an ID3v2 tag, then frames with valid
/// headers (128 kbps, 44.1 kHz, mono), a side-info block whose first 9 bits
/// are main_data_begin (bytes borrowed from earlier frames' bit reservoir,
/// from [borrow]), and a filler payload. No encoder is available here, so this
/// checks frame and reservoir handling, not decoding.
const mp3FrameLength = 144 * 128000 ~/ 44100; // 417 bytes, no padding.
List<int> syntheticMp3(int frames, {int Function(int frame)? borrow}) {
  final out = BytesBuilder()
    ..add([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 10])
    ..add(List.filled(10, 0x20));
  for (var i = 0; i < frames; i++) {
    final begin = borrow?.call(i) ?? 0;
    out
      ..add([0xFF, 0xFB, 0x90, 0xC4])
      ..add([begin >> 1, (begin & 1) << 7])
      ..add(List.filled(mp3FrameLength - 6, i % 256));
  }
  return out.takeBytes();
}

void main() {
  test('a recording within the limits is sent as it is', () {
    final m4a = fixture('speech.m4a');
    final parts = splitForTranscription(m4a, format: 'm4a');
    expect(parts, hasLength(1));
    expect(parts.single.format, 'm4a');
    expect(parts.single.bytes, m4a);
    // Counted from the encoded frames, so it includes the encoder's priming
    // and padding: never less than the 4.06 s heard, at most the 90 frames.
    // Erring long only makes the budget reservation more conservative.
    expect(parts.single.duration.inMilliseconds, inInclusiveRange(4057, 4180));
  });

  test(
    'a long .m4a becomes equal ADTS parts carrying exactly its AAC frames',
    () {
      final parts = splitForTranscription(
        fixture('speech.m4a'),
        format: 'm4a',
        maxDuration: const Duration(milliseconds: 1500),
      );
      expect(parts, hasLength(3));
      final key = adtsFrames(fixture('speech.aac'));
      final produced = [for (final p in parts) ...adtsFrames(p.bytes)];
      expect(produced.length, 90);
      for (var i = 0; i < 90; i++) {
        expect(produced[i].$2, key[i].$2, reason: 'frame $i payload');
        // Same profile, sample rate and channels as Apple's own ADTS header.
        expect(produced[i].$1[2], key[i].$1[2]);
        expect(produced[i].$1[3] & 0xC0, key[i].$1[3] & 0xC0);
      }
      for (final part in parts) {
        expect(part.format, 'aac');
        expect(part.mime, 'audio/aac');
        // 30 frames × 1024 samples at 22050 Hz each.
        expect(part.duration.inMilliseconds, closeTo(1393, 1));
      }
    },
  );

  test('ADTS .aac splits on frame boundaries without changing a byte', () {
    final aac = fixture('speech.aac');
    final parts = splitForTranscription(
      aac,
      format: 'aac',
      maxDuration: const Duration(seconds: 1),
    );
    expect(parts, hasLength(5));
    expect([for (final p in parts) ...p.bytes], aac);
    expect(parts.map((p) => adtsFrames(p.bytes).length), [18, 18, 18, 18, 18]);
  });

  test('.wav parts are complete WAV files whose samples join back exactly', () {
    final wav = fixture('speech.wav');
    final parts = splitForTranscription(
      wav,
      format: 'wav',
      maxDuration: const Duration(seconds: 2),
    );
    expect(parts, hasLength(3));
    final joined = <int>[];
    for (final part in parts) {
      final b = ByteData.sublistView(Uint8List.fromList(part.bytes));
      expect(String.fromCharCodes(part.bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(part.bytes.sublist(8, 12)), 'WAVE');
      expect(b.getUint32(4, Endian.little), part.bytes.length - 8);
      expect(b.getUint16(22, Endian.little), 1); // mono
      expect(b.getUint32(24, Endian.little), 16000);
      expect(b.getUint16(34, Endian.little), 16);
      expect(String.fromCharCodes(part.bytes.sublist(36, 40)), 'data');
      expect(b.getUint32(40, Endian.little), part.bytes.length - 44);
      joined.addAll(part.bytes.sublist(44));
      expect(part.duration.inMilliseconds, lessThanOrEqualTo(2000));
    }
    // 64913 samples × 2 bytes, exactly as afinfo reports for the fixture.
    expect(joined.length, 129826);
  });

  test('.mp3 splits by frames and keeps every frame exactly once', () {
    final mp3 = syntheticMp3(100); // 100 × 1152 samples ≈ 2.6 s.
    final parts = splitForTranscription(
      mp3,
      format: 'mp3',
      maxDuration: const Duration(seconds: 1),
    );
    expect(parts, hasLength(3));
    final frames = [for (final p in parts) p.bytes.length ~/ mp3FrameLength];
    expect(frames.reduce((a, b) => a + b), 100);
    expect([for (final p in parts) ...p.bytes], mp3.sublist(20));
    expect(parts.first.mime, 'audio/mpeg');
  });

  test('the byte limit splits too, and a part never exceeds it', () {
    final aac = fixture('speech.aac');
    final parts = splitForTranscription(aac, format: 'aac', maxBytes: 5000);
    expect(parts.length, greaterThanOrEqualTo(4));
    expect(parts.every((p) => p.bytes.length <= 5000), isTrue);
    expect([for (final p in parts) ...p.bytes], aac);
  });

  test('a damaged file is refused rather than sent', () {
    final m4a = fixture('speech.m4a');
    expect(
      () => splitForTranscription(
        m4a.sublist(0, 900),
        format: 'm4a',
        maxDuration: const Duration(seconds: 1),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => splitForTranscription(List.filled(4000, 7), format: 'aac'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => splitForTranscription(fixture('speech.wav'), format: 'flac'),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'an .mp3 part starts with the earlier frames its first frame borrows from',
    () {
      // Every frame borrows 500 bytes: more than one earlier frame's 396 bytes
      // of main data (417 − 4 header − 17 side info), so two frames are needed.
      final mp3 = syntheticMp3(100, borrow: (_) => 500);
      final parts = splitForTranscription(
        mp3,
        format: 'mp3',
        maxDuration: const Duration(seconds: 1),
      );
      expect(parts, hasLength(3));
      final frames = mp3.sublist(20);
      List<int> frame(int i) =>
          frames.sublist(i * mp3FrameLength, (i + 1) * mp3FrameLength);
      // Parts own frames 0–33, 34–67 and 68–99.
      expect(parts[0].bytes, [for (var i = 0; i < 34; i++) ...frame(i)]);
      expect(parts[1].bytes, [for (var i = 32; i < 68; i++) ...frame(i)]);
      expect(parts[2].bytes, [for (var i = 66; i < 100; i++) ...frame(i)]);
      // The duration counts only each part's own frames.
      expect(parts[1].duration.inMilliseconds, closeTo(888, 1));

      // A frame that borrows nothing needs nothing in front of it.
      final independent = syntheticMp3(
        100,
        borrow: (i) => i % 34 == 0 ? 0 : 500,
      );
      final clean = splitForTranscription(
        independent,
        format: 'mp3',
        maxDuration: const Duration(seconds: 1),
      );
      expect(clean[1].bytes.length, 34 * mp3FrameLength);
    },
  );
}
