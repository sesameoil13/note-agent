import 'dart:math';
import 'dart:typed_data';

/// Bailian transcribes at most 5 minutes and 10 MB (base64) per request
/// (ADR 0003), so longer recordings are split on the device into as few
/// equal parts as the limits allow. A recording within the limits is sent
/// unchanged; .m4a parts become ADTS .aac carrying the same AAC frames.
class TranscriptionPart {
  const TranscriptionPart(this.bytes, this.format, this.duration);
  final List<int> bytes;

  /// `m4a`, `aac`, `mp3` or `wav`.
  final String format;
  final Duration duration;

  String get mime => switch (format) {
    'm4a' => 'audio/m4a',
    'aac' => 'audio/aac',
    'mp3' => 'audio/mpeg',
    _ => 'audio/wav',
  };
}

const transcriptionPartDuration = Duration(seconds: 270);
const transcriptionPartBytes = 7000000;

List<TranscriptionPart> splitForTranscription(
  List<int> bytes, {
  required String format,
  Duration maxDuration = transcriptionPartDuration,
  int maxBytes = transcriptionPartBytes,
}) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final _Frames frames = switch (format) {
    'm4a' => _mp4(data),
    'aac' => _adts(data),
    'mp3' => _mp3(data),
    'wav' => _wav(data),
    _ => throw const FormatException('不支持的录音格式。'),
  };
  if (frames.count == 0) throw const FormatException('录音中没有可转写的音频。');
  final whole = frames.wholeDuration ?? frames.duration(0, frames.count);
  if (whole <= maxDuration && data.length <= maxBytes) {
    return [TranscriptionPart(bytes, format, whole)];
  }
  var parts = max(
    (frames.duration(0, frames.count).inMicroseconds /
            maxDuration.inMicroseconds)
        .ceil(),
    (frames.payloadBytes / maxBytes).ceil(),
  );
  while (true) {
    final per = (frames.count / parts).ceil();
    final result = [
      for (var start = 0; start < frames.count; start += per)
        frames.part(start, min(start + per, frames.count)),
    ];
    if (result.every(
      (p) => p.bytes.length <= maxBytes && p.duration <= maxDuration,
    )) {
      return result;
    }
    if (per == 1) throw const FormatException('单个音频帧超过上传上限。');
    parts++;
  }
}

/// A recording as a run of independently decodable frames.
abstract class _Frames {
  int get count;
  int get payloadBytes;
  Duration? get wholeDuration => null;
  Duration duration(int start, int end);
  TranscriptionPart part(int start, int end);
}

// ---------------------------------------------------------------- ADTS / M4A

const _aacRates = [
  96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, //
  16000, 12000, 11025, 8000, 7350,
];

class _AacFrames extends _Frames {
  _AacFrames(this.frames, this.rate, [this.wholeDuration]);

  /// Complete ADTS frames (header included).
  final List<Uint8List> frames;
  final int rate;
  @override
  final Duration? wholeDuration;
  @override
  int get count => frames.length;
  @override
  int get payloadBytes => frames.fold(0, (sum, f) => sum + f.length);
  @override
  Duration duration(int start, int end) =>
      Duration(microseconds: (end - start) * 1024 * 1000000 ~/ rate);
  @override
  TranscriptionPart part(int start, int end) {
    final out = BytesBuilder(copy: false);
    for (var i = start; i < end; i++) {
      out.add(frames[i]);
    }
    return TranscriptionPart(out.takeBytes(), 'aac', duration(start, end));
  }
}

_AacFrames _adts(Uint8List b) {
  final frames = <Uint8List>[];
  int? rate;
  var i = 0;
  while (i < b.length) {
    if (i + 7 > b.length || b[i] != 0xFF || (b[i + 1] & 0xF6) != 0xF0) {
      throw const FormatException('AAC 音频帧无法识别。');
    }
    final length =
        ((b[i + 3] & 0x03) << 11) | (b[i + 4] << 3) | (b[i + 5] >> 5);
    final index = (b[i + 2] >> 2) & 0x0F;
    if (length < 7 || i + length > b.length || index >= _aacRates.length) {
      throw const FormatException('AAC 音频帧不完整。');
    }
    rate ??= _aacRates[index];
    frames.add(Uint8List.sublistView(b, i, i + length));
    i += length;
  }
  return _AacFrames(frames, rate ?? 44100);
}

/// Reads an MP4/M4A file's AAC track (sample tables and AudioSpecificConfig)
/// and wraps each sample in an ADTS header.
_AacFrames _mp4(Uint8List b) {
  final view = ByteData.sublistView(b);
  int u32(int at) {
    if (at < 0 || at + 4 > b.length) throw const FormatException('M4A 文件不完整。');
    return view.getUint32(at);
  }

  int u64(int at) => u32(at) * 4294967296 + u32(at + 4);

  /// Child boxes of [start, end) as (type, body start, end).
  List<(String, int, int)> boxes(int start, int end) {
    final out = <(String, int, int)>[];
    var at = start;
    while (at + 8 <= end) {
      var size = u32(at), header = 8;
      final type = String.fromCharCodes(b.sublist(at + 4, at + 8));
      if (size == 1) {
        size = u64(at + 8);
        header = 16;
      } else if (size == 0) {
        size = end - at;
      }
      if (size < header || at + size > end) {
        throw const FormatException('M4A 文件不完整。');
      }
      out.add((type, at + header, at + size));
      at += size;
    }
    return out;
  }

  (int, int)? find(List<(String, int, int)> list, String type) {
    for (final (t, s, e) in list) {
      if (t == type) return (s, e);
    }
    return null;
  }

  final moov = find(boxes(0, b.length), 'moov');
  if (moov == null) throw const FormatException('M4A 文件缺少音轨信息。');
  for (final (type, ts, te) in boxes(moov.$1, moov.$2)) {
    if (type != 'trak') continue;
    final mdia = find(boxes(ts, te), 'mdia');
    if (mdia == null) continue;
    final mdiaBoxes = boxes(mdia.$1, mdia.$2);
    final minf = find(mdiaBoxes, 'minf');
    final stbl = minf == null ? null : find(boxes(minf.$1, minf.$2), 'stbl');
    if (stbl == null) continue;
    final tables = boxes(stbl.$1, stbl.$2);
    final stsd = find(tables, 'stsd');
    if (stsd == null) continue;
    // stsd: version/flags, entry count, then the sample entry box.
    final entries = boxes(stsd.$1 + 8, stsd.$2);
    final mp4a = find(entries, 'mp4a');
    if (mp4a == null) continue;
    // AudioSampleEntry: 28 bytes of fields, then child boxes (esds).
    final esds = find(boxes(mp4a.$1 + 28, mp4a.$2), 'esds');
    if (esds == null) throw const FormatException('M4A 缺少 AAC 配置。');
    final config = _audioSpecificConfig(b, esds.$1 + 4, esds.$2);

    final stsz = find(tables, 'stsz'), stsc = find(tables, 'stsc');
    final stco = find(tables, 'stco'), co64 = find(tables, 'co64');
    if (stsz == null || stsc == null || (stco == null && co64 == null)) {
      throw const FormatException('M4A 缺少音频索引。');
    }
    final fixedSize = u32(stsz.$1 + 4), sampleCount = u32(stsz.$1 + 8);
    int sizeOf(int i) => fixedSize != 0 ? fixedSize : u32(stsz.$1 + 12 + 4 * i);
    final offsets = stco != null
        ? [for (var i = 0; i < u32(stco.$1 + 4); i++) u32(stco.$1 + 8 + 4 * i)]
        : [
            for (var i = 0; i < u32(co64!.$1 + 4); i++)
              u64(co64.$1 + 8 + 8 * i),
          ];
    final runs = [
      for (var i = 0; i < u32(stsc.$1 + 4); i++)
        (u32(stsc.$1 + 8 + 12 * i), u32(stsc.$1 + 12 + 12 * i)),
    ];
    final frames = <Uint8List>[];
    var sample = 0;
    for (var chunk = 0; chunk < offsets.length; chunk++) {
      var perChunk = 0;
      for (final (first, count) in runs) {
        if (first <= chunk + 1) perChunk = count;
      }
      var at = offsets[chunk];
      for (var k = 0; k < perChunk && sample < sampleCount; k++, sample++) {
        final size = sizeOf(sample);
        if (at + size > b.length || size + 7 > 8191) {
          throw const FormatException('M4A 音频数据不完整。');
        }
        frames.add(_adtsFrame(config, Uint8List.sublistView(b, at, at + size)));
        at += size;
      }
    }
    if (sample != sampleCount) throw const FormatException('M4A 音频索引不一致。');
    Duration? whole;
    final mdhd = find(mdiaBoxes, 'mdhd');
    if (mdhd != null) {
      final v1 = b[mdhd.$1] == 1;
      final scale = u32(mdhd.$1 + (v1 ? 20 : 12));
      final length = v1 ? u64(mdhd.$1 + 24) : u32(mdhd.$1 + 16);
      if (scale > 0) {
        whole = Duration(microseconds: length * 1000000 ~/ scale);
      }
    }
    return _AacFrames(frames, _aacRates[config.$2], whole);
  }
  throw const FormatException('M4A 文件没有 AAC 音轨。');
}

/// (object type, sample rate index, channel configuration) from esds.
(int, int, int) _audioSpecificConfig(Uint8List b, int start, int end) {
  var at = start;
  int length() {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      if (at >= end) throw const FormatException('AAC 配置不完整。');
      final byte = b[at++];
      value = (value << 7) | (byte & 0x7F);
      if (byte & 0x80 == 0) break;
    }
    return value;
  }

  while (at < end) {
    final tag = b[at++];
    final size = length();
    if (tag == 0x03) {
      at += 3; // ES_ID and flags; no optional fields in recorded files.
    } else if (tag == 0x04) {
      at += 13; // objectTypeIndication … avgBitrate
    } else if (tag == 0x05) {
      if (size < 2 || at + 2 > end) throw const FormatException('AAC 配置不完整。');
      final objectType = b[at] >> 3;
      final rate = ((b[at] & 0x07) << 1) | (b[at + 1] >> 7);
      final channels = (b[at + 1] >> 3) & 0x0F;
      if (objectType < 1 || objectType > 4 || rate >= _aacRates.length) {
        throw const FormatException('不支持的 AAC 配置。');
      }
      return (objectType, rate, channels);
    } else {
      at += size;
    }
  }
  throw const FormatException('M4A 缺少 AAC 配置。');
}

Uint8List _adtsFrame((int, int, int) config, Uint8List payload) {
  final (objectType, rate, channels) = config;
  final length = payload.length + 7;
  return Uint8List(length)
    ..[0] = 0xFF
    ..[1] = 0xF1
    ..[2] = ((objectType - 1) << 6) | (rate << 2) | (channels >> 2)
    ..[3] = ((channels & 3) << 6) | (length >> 11)
    ..[4] = (length >> 3) & 0xFF
    ..[5] = ((length & 7) << 5) | 0x1F
    ..[6] = 0xFC
    ..setRange(7, length, payload);
}

// ----------------------------------------------------------------------- MP3

/// MP3 frames may borrow up to 511 bytes of main data from earlier frames
/// (the bit reservoir, `main_data_begin`). A part therefore starts with the
/// earlier frames its first frame borrows from: a few tens of milliseconds of
/// overlap, which its duration does not count.
class _Mp3Frames extends _Frames {
  _Mp3Frames(
    this.frames,
    this.borrowed,
    this.mainData,
    this.samples,
    this.rate,
  );
  final List<Uint8List> frames;

  /// Per frame: main_data_begin, and its own bytes of main data.
  final List<int> borrowed, mainData;
  final int samples, rate;
  @override
  int get count => frames.length;
  @override
  int get payloadBytes => frames.fold(0, (sum, f) => sum + f.length);
  @override
  Duration duration(int start, int end) =>
      Duration(microseconds: (end - start) * samples * 1000000 ~/ rate);
  @override
  TranscriptionPart part(int start, int end) {
    var first = start;
    for (var covered = 0; first > 0 && covered < borrowed[start];) {
      first--;
      covered += mainData[first];
    }
    final out = BytesBuilder(copy: false);
    for (var i = first; i < end; i++) {
      out.add(frames[i]);
    }
    return TranscriptionPart(out.takeBytes(), 'mp3', duration(start, end));
  }
}

_Mp3Frames _mp3(Uint8List b) {
  var i = 0;
  // ID3v2 tag: 10-byte header with a syncsafe size (plus footer if flagged).
  if (b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
    final size = (b[6] << 21) | (b[7] << 14) | (b[8] << 7) | b[9];
    i = 10 + size + ((b[5] & 0x10) != 0 ? 10 : 0);
  }
  const v1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
  const v2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
  const rates = {
    3: [44100, 48000, 32000],
    2: [22050, 24000, 16000],
    0: [11025, 12000, 8000],
  };
  final frames = <Uint8List>[];
  final borrowed = <int>[], mainData = <int>[];
  int? rate, samples;
  while (i + 4 <= b.length) {
    // A trailing ID3v1 tag ends the stream.
    if (b.length - i == 128 && b[i] == 0x54 && b[i + 1] == 0x41) break;
    final version = (b[i + 1] >> 3) & 3, layer = (b[i + 1] >> 1) & 3;
    final bitrate = b[i + 2] >> 4, rateIndex = (b[i + 2] >> 2) & 3;
    if (b[i] != 0xFF ||
        (b[i + 1] & 0xE0) != 0xE0 ||
        version == 1 ||
        layer != 1 ||
        bitrate == 0 ||
        bitrate == 15 ||
        rateIndex == 3) {
      throw const FormatException('MP3 音频帧无法识别。');
    }
    final hz = rates[version]![rateIndex];
    final kbps = (version == 3 ? v1 : v2)[bitrate];
    final padding = (b[i + 2] >> 1) & 1;
    final length = (version == 3 ? 144 : 72) * kbps * 1000 ~/ hz + padding;
    if (i + length > b.length) throw const FormatException('MP3 音频帧不完整。');
    // Side information follows the header (and its CRC, if present).
    final mono = (b[i + 3] >> 6) == 3;
    final side = i + 4 + ((b[i + 1] & 1) == 0 ? 2 : 0);
    final sideLength = version == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17);
    if (side + 2 > i + length || side + sideLength > i + length) {
      throw const FormatException('MP3 音频帧不完整。');
    }
    borrowed.add(version == 3 ? (b[side] << 1) | (b[side + 1] >> 7) : b[side]);
    mainData.add(i + length - side - sideLength);
    rate ??= hz;
    samples ??= version == 3 ? 1152 : 576;
    frames.add(Uint8List.sublistView(b, i, i + length));
    i += length;
  }
  return _Mp3Frames(frames, borrowed, mainData, samples ?? 1152, rate ?? 44100);
}

// ----------------------------------------------------------------------- WAV

class _WavFrames extends _Frames {
  _WavFrames(
    this.b,
    this.data,
    this.frameCount,
    this.channels,
    this.rate,
    this.bits,
    this.align,
  );
  final Uint8List b;
  final int data, frameCount, channels, rate, bits, align;
  @override
  int get count => frameCount;
  @override
  int get payloadBytes => frameCount * align;
  @override
  Duration duration(int start, int end) =>
      Duration(microseconds: (end - start) * 1000000 ~/ rate);
  @override
  TranscriptionPart part(int start, int end) {
    final size = (end - start) * align;
    final out = Uint8List(44 + size);
    final v = ByteData.sublistView(out);
    out.setRange(0, 4, 'RIFF'.codeUnits);
    v.setUint32(4, 36 + size, Endian.little);
    out.setRange(8, 16, 'WAVEfmt '.codeUnits);
    v
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, channels, Endian.little)
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * align, Endian.little)
      ..setUint16(32, align, Endian.little)
      ..setUint16(34, bits, Endian.little);
    out.setRange(36, 40, 'data'.codeUnits);
    v.setUint32(40, size, Endian.little);
    out.setRange(44, 44 + size, b, data + start * align);
    return TranscriptionPart(out, 'wav', duration(start, end));
  }
}

_WavFrames _wav(Uint8List b) {
  final v = ByteData.sublistView(b);
  if (b.length < 12 ||
      String.fromCharCodes(b.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(b.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('WAV 文件无法识别。');
  }
  int? channels, rate, bits, align, data, dataSize;
  var at = 12;
  while (at + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(at, at + 4));
    final size = v.getUint32(at + 4, Endian.little);
    final body = at + 8;
    if (body + size > b.length) {
      if (id != 'data') throw const FormatException('WAV 文件不完整。');
    }
    if (id == 'fmt ') {
      if (size < 16 || v.getUint16(body, Endian.little) != 1) {
        throw const FormatException('仅支持 PCM WAV。');
      }
      channels = v.getUint16(body + 2, Endian.little);
      rate = v.getUint32(body + 4, Endian.little);
      align = v.getUint16(body + 12, Endian.little);
      bits = v.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      data = body;
      dataSize = min(size, b.length - body);
      break;
    }
    at = body + size + (size & 1);
  }
  if (channels == null || data == null || align == null || align == 0) {
    throw const FormatException('WAV 文件缺少音频数据。');
  }
  return _WavFrames(b, data, dataSize! ~/ align, channels, rate!, bits!, align);
}
