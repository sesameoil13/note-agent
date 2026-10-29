part of 'note_workspace.dart';

/// The parts a recording is sent in (ADR 0003); a part's transcript is
/// saved as it arrives, so a later send only covers the missing parts.
List<Map<String, dynamic>> _parts(Map<String, dynamic> p) => [
  for (final part in (p['parts'] as List?) ?? const [])
    (part as Map).cast<String, dynamic>(),
];

extension _WorkspaceAudioProcessing on NoteWorkspace {
  Future<List<int>> _verifiedAudio(
    WorkspaceAudioSource source, {
    Map? expected,
  }) async {
    if (!source.originalSaved ||
        source.metadata == null ||
        source.byteLength > 25000000) {
      throw const ConnectionFailure('原件尚未通过检查或超过 25 MB，原音保留。');
    }
    final metadata = await _audioQueue.inspector
        .inspectAudioSource(source.originalPath)
        .timeout(const Duration(seconds: 10));
    final format = metadata.container.toLowerCase();
    if (!['wav', 'mp3', 'm4a', 'aac'].contains(format) ||
        metadata.duration.inMilliseconds < 1 ||
        metadata.duration.inMilliseconds > 600000 ||
        metadata.duration != source.metadata!.duration ||
        metadata.container != source.metadata!.container) {
      throw const ConnectionFailure('音频格式或时长未能核对，原音保留。');
    }
    final file = File(source.originalPath);
    if (await file.length() != source.byteLength) {
      throw const ConnectionFailure('音频原件已改变，未上传。');
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      bytes.addAll(chunk);
      if (bytes.length > 25000000) {
        throw const ConnectionFailure('音频原件超过上传上限，未上传。');
      }
    }
    if (bytes.length != source.byteLength) {
      throw const ConnectionFailure('音频原件已改变，未上传。');
    }
    final magic = switch (format) {
      'wav' =>
        bytes.length >= 12 &&
            ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
            ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WAVE',
      'm4a' =>
        bytes.length >= 12 &&
            ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp',
      'aac' => bytes.length >= 2 && bytes[0] == 255 && (bytes[1] & 246) == 240,
      'mp3' =>
        bytes.length >= 3 &&
            ((bytes[0] == 73 && bytes[1] == 68 && bytes[2] == 51) ||
                (bytes[0] == 255 && (bytes[1] & 224) == 224)),
      _ => false,
    };
    final digest = (await const DartSha256().hash(bytes)).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    if (!magic ||
        digest != source.digest ||
        (expected != null &&
            (expected['digest'] != digest ||
                expected['format'] != format ||
                expected['durationMs'] != metadata.duration.inMilliseconds))) {
      throw const ConnectionFailure('音频内容与已检查原件不符，未上传。');
    }
    return bytes;
  }

  /// The qwen-plus request for a recording's complete transcript. Optional
  /// association context yields to the transcript, and exactly the sent
  /// candidates are kept so omitted ones cannot be invented by the model.
  Future<Map<String, dynamic>> _audioTextRequest(
    String noteId,
    String transcript,
    Map<String, dynamic> payload,
  ) async {
    final candidates = [...await _associationCandidates(noteId, transcript)];
    Map<String, dynamic> request() => textModelPayload(
      noteId,
      transcript,
      const {},
      associationCandidates: candidates,
    );
    var encoded = request();
    while (utf8.encode(jsonEncode(encoded)).length > 20000 &&
        candidates.isNotEmpty) {
      candidates.removeLast();
      encoded = request();
    }
    if (utf8.encode(jsonEncode(encoded)).length > 20000) {
      throw const ConnectionFailure('完整转写超过整理上限，原音与完整转写保留；未发送或截断。');
    }
    payload['associationCandidates'] = candidates;
    return encoded;
  }

  /// Sends the parts of a recording not yet transcribed, in order, then
  /// saves the joined transcript as its note's source.
  Future<String> _transcribe(
    String jobId,
    String sourceId,
    Map<String, dynamic> payload,
  ) async {
    final source = _audioQueue.source(sourceId);
    final split = splitForTranscription(
      await _verifiedAudio(source),
      format: source.metadata!.container.toLowerCase(),
    );
    var parts = _parts(payload);
    // The same checked original always splits the same way.
    if (parts.length != split.length) {
      parts = [
        for (var i = 0; i < split.length; i++) {'index': i},
      ];
    }
    payload['parts'] = parts;
    await _saveText(jobId, TextProcessingStatus.sending, payload);
    for (var i = 0; i < split.length; i++) {
      if (parts[i]['transcript'] is String) continue;
      final reply = await connection.sendAudio(
        bytes: split[i].bytes,
        mime: split[i].mime,
      );
      parts[i]['transcript'] = reply.text;
      await _saveText(jobId, TextProcessingStatus.sending, payload);
    }
    final transcript = parts.map((part) => part['transcript']).join();
    await _materializeTranscript(sourceId, transcript);
    return transcript;
  }

  Future<void> _materializeTranscript(String id, String transcript) =>
      _mutate(() async {
        final source = _audioQueue.source(id);
        _database.execute(
          'UPDATE audio_queue SET transcript=? WHERE id=? AND vault=?',
          [transcript, id, vaultStorage.identity],
        );
        await _materializeAudioNote(
          source,
          AudioOrganizedNote(title: '录音转写', text: transcript),
        );
      }, accepted: true);

  /// Old estimate/confirm audio jobs are dropped without being sent; the
  /// audio and any transcript that arrived stay.
  Future<void> _dropUnfinishedAudioJobs() async {
    for (final row in _database.select(
      "SELECT source_id,payload FROM audio_jobs WHERE vault=? AND status NOT IN ('completed','cancelled')",
      [vaultStorage.identity],
    )) {
      final id = row['source_id'] as String;
      final p = (jsonDecode(row['payload'] as String) as Map)
          .cast<String, dynamic>();
      if (p['transcript'] is String) {
        try {
          await _materializeTranscript(id, p['transcript'] as String);
        } catch (_) {
          /* The transcript stays in the old job; it is not sent either. */
        }
      }
      await _mutate(() async {
        _database.execute(
          'UPDATE audio_jobs SET status=?,error=? WHERE source_id=? AND vault=?',
          ['cancelled', '升级后不再发送旧的预估任务；原音与已有转写保留。', id, vaultStorage.identity],
        );
      }, accepted: true);
    }
  }
}
