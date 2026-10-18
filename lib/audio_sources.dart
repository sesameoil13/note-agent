import 'dart:io';
import 'dart:typed_data';

/// Inspection is an OS/file-format boundary. Only complete private originals
/// are passed here; filenames and picker MIME types are never validation.
abstract interface class AudioSourceInspector {
  Future<AudioSourceMetadata> inspectAudioSource(String privatePath);
}

abstract interface class AudioSourcePlayer {
  Future<void> playAudioSource(String privatePath);
}

class AudioSourceMetadata {
  const AudioSourceMetadata({
    required this.container,
    required this.codec,
    required this.duration,
    required this.sampleRate,
    required this.channels,
  });
  final String container;
  final String codec;
  final Duration duration;
  final int sampleRate;
  final int channels;
  Map<String, Object> toJson() => {
    'container': container,
    'codec': codec,
    'durationMs': duration.inMilliseconds,
    'sampleRate': sampleRate,
    'channels': channels,
  };
  factory AudioSourceMetadata.fromJson(Map<String, dynamic> json) =>
      AudioSourceMetadata(
        container: json['container'] as String,
        codec: json['codec'] as String,
        duration: Duration(milliseconds: json['durationMs'] as int),
        sampleRate: json['sampleRate'] as int,
        channels: json['channels'] as int,
      );
}

class AudioInspectionFailure implements Exception {
  const AudioInspectionFailure(this.message, {this.retryable = false});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

/// Portable PCM WAV inspection for platforms without a native decoder adapter.
/// Reads bounded headers and verifies complete PCM frames against real length.
/// MP3/AAC require the native decoder; a filename can never opt into support.
class PcmWaveInspector implements AudioSourceInspector {
  @override
  Future<AudioSourceMetadata> inspectAudioSource(String privatePath) async {
    final file = await File(privatePath).open();
    try {
      final length = await file.length();
      if (length < 12) throw const AudioInspectionFailure('文件为空或音频头不完整，原件已保留。');
      final header = await file.read(12);
      String tag(List<int> bytes, int offset) =>
          String.fromCharCodes(bytes.skip(offset).take(4));
      if (tag(header, 0) != 'RIFF' || tag(header, 8) != 'WAVE') {
        throw const AudioInspectionFailure('此平台尚不支持此音频格式；可检查 PCM / WAV，原件已保留。');
      }
      final riffSize =
          ByteData.sublistView(header).getUint32(4, Endian.little) + 8;
      if (riffSize != length) {
        throw const AudioInspectionFailure('WAV 文件长度与音频头不符，原件可能不完整。');
      }
      int? rate, channels, alignment, bits;
      var audioBytes = 0;
      var offset = 12;
      var chunks = 0;
      while (offset + 8 <= length) {
        if (++chunks > 4096) {
          throw const AudioInspectionFailure('音频头过于复杂，已保留原件，请使用较简单的 WAV。');
        }
        await file.setPosition(offset);
        final chunk = await file.read(8);
        final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
        if (offset + 8 + size > length) {
          throw const AudioInspectionFailure('音频数据不完整，原件已保留。');
        }
        if (tag(chunk, 0) == 'fmt ') {
          if (size < 16 || size > 4096) {
            throw const AudioInspectionFailure('WAV 格式信息无效，原件已保留。');
          }
          final format = ByteData.sublistView(await file.read(16));
          if (format.getUint16(0, Endian.little) != 1) {
            throw const AudioInspectionFailure('此平台仅支持 PCM 编码 WAV，原件已保留。');
          }
          channels = format.getUint16(2, Endian.little);
          rate = format.getUint32(4, Endian.little);
          alignment = format.getUint16(12, Endian.little);
          bits = format.getUint16(14, Endian.little);
          if (channels < 1 ||
              channels > 8 ||
              rate < 8000 ||
              rate > 192000 ||
              ![8, 16, 24, 32].contains(bits) ||
              alignment != channels * bits ~/ 8 ||
              format.getUint32(8, Endian.little) != rate * alignment) {
            throw const AudioInspectionFailure('WAV 音频参数无效，原件已保留。');
          }
        } else if (tag(chunk, 0) == 'data') {
          audioBytes += size;
        }
        offset += 8 + size + (size.isOdd ? 1 : 0);
      }
      if (offset != length ||
          rate == null ||
          channels == null ||
          alignment == null ||
          audioBytes == 0 ||
          audioBytes % alignment != 0) {
        throw const AudioInspectionFailure('没有完整可解码的 PCM 音频，原件已保留。');
      }
      return AudioSourceMetadata(
        container: 'WAV',
        codec: 'PCM',
        duration: Duration(
          microseconds: (audioBytes * 1000000 ~/ (rate * alignment)),
        ),
        sampleRate: rate,
        channels: channels,
      );
    } finally {
      await file.close();
    }
  }
}
