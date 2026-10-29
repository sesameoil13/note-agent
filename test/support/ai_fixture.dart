import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:note_agent/connection.dart';
import 'package:note_agent/note_workspace.dart';

class AiMemoryStore implements SecureCredentialStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async {
    value = v;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

/// Paired devices talking to a real local Worker (pairing and to-do sync
/// only, no budget) and a fake Bailian server. The devices share [now].
class AiFixture {
  late Process _worker;
  late Uri _workerOrigin;
  late HttpServer _router;
  late Directory root;
  DateTime now = DateTime(2026, 10, 29, 9);

  /// Every path the Worker was asked for, e.g. `/v1/pairing/...`.
  final workerPaths = <String>[];

  /// qwen-plus requests, oldest first.
  final modelRequests = <Map<String, dynamic>>[];

  /// Statuses for successive qwen-plus requests; 200 when empty.
  final modelStatuses = <int>[];

  /// The organized result returned for a request; an ordinary note when null.
  Map<String, dynamic>? modelResult;

  /// Runs while a qwen-plus request is held, before the reply is written.
  Future<void> Function()? beforeReply;

  /// qwen3-asr-flash requests, oldest first.
  final audioRequests = <Map<String, dynamic>>[];

  /// Seconds of audio in each transcription request, read from its WAV.
  final audioSeconds = <int>[];

  /// Statuses for successive transcription requests; 200 when empty.
  final audioStatuses = <int>[];
  String transcript = '明天下午两点整理会议记录。';

  /// Transcripts for successive parts; [transcript] when empty.
  final partTranscripts = <String>[];

  /// Runs while a transcription request is held, before the reply.
  Future<void> Function()? beforeAudioReply;

  /// The first device's recorder, if a test records.
  AudioPlatform? recorder;
  final workspaces = <NoteWorkspace>[];
  final _stores = <AiMemoryStore>[];
  // Widget tests mock every HttpClient made in their zone; the proxy to the
  // local Worker needs a real one.
  final _proxy = HttpOverrides.runWithHttpOverrides(
    HttpClient.new,
    _RealHttpOverrides(),
  );

  Future<void> start({int devices = 2}) async {
    root = await Directory.systemTemp.createTemp('ai-fixture-');
    _worker = await Process.start(
      Platform.environment['NOTE_AGENT_NODE'] ?? 'node',
      ['tools/local-harness.mjs'],
      workingDirectory: 'services/pairing',
    );
    _worker.stderr.transform(utf8.decoder).listen((_) {});
    _workerOrigin = Uri.parse(
      await _worker.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          // Starting the local Worker runtime is slow on Windows CI.
          .timeout(const Duration(seconds: 60)),
    );
    _router = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _router.listen(_route);
    for (var i = 0; i < devices; i++) {
      _stores.add(AiMemoryStore());
      await Directory('${root.path}/vault$i').create();
      workspaces.add(await _open(i));
    }
    final owner = workspaces.first.connection;
    await owner.connectAi('sk-ai-fixture-only-key');
    await owner.activatePairing(
      setupToken: 'local-test-setup-only',
      deviceName: 'owner',
    );
    for (final w in workspaces.skip(1)) {
      await owner.createPairing();
      await w.connection.joinPairing(owner.pairing.code!, deviceName: 'member');
      await owner.refreshPairing();
      await owner.approvePairing(
        verificationCode: owner.pairing.verificationCode!,
      );
      await w.connection.refreshPairing();
      await owner.refreshPairing();
    }
  }

  Future<void> _route(HttpRequest r) async {
    if (r.uri.path.startsWith('/v1/')) {
      workerPaths.add(r.uri.path);
      await _forward(r);
      return;
    }
    if (r.uri.path == '/chat/completions') {
      final request =
          jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, dynamic>;
      if (request['model'] == 'qwen3-asr-flash') {
        await _transcribe(r, request);
      } else {
        await _organize(r, request);
      }
      return;
    }
    // The key check lists models.
    r.response.write('{"object":"list","data":[{"id":"qwen-plus"}]}');
    await r.response.close();
  }

  Future<void> _forward(HttpRequest r) async {
    final upstream = await _proxy.openUrl(
      r.method,
      _workerOrigin.resolve(r.uri.toString().substring(1)),
    );
    r.headers.forEach((name, values) {
      if (name == 'authorization' || name == 'content-type') {
        upstream.headers.set(name, values);
      }
    });
    await upstream.addStream(r);
    final result = await upstream.close();
    r.response.statusCode = result.statusCode;
    r.response.headers.contentType = result.headers.contentType;
    await r.response.addStream(result);
    await r.response.close();
  }

  /// Bailian's OpenAI-compatible qwen-plus reply.
  Future<void> _organize(HttpRequest r, Map<String, dynamic> request) async {
    modelRequests.add(request);
    final status = modelStatuses.isEmpty ? 200 : modelStatuses.removeAt(0);
    await beforeReply?.call();
    r.response.statusCode = status;
    if (status != 200) {
      r.response.write('{}');
      await r.response.close();
      return;
    }
    final input = jsonDecode(
      (request['messages'] as List).last['content'] as String,
    ) as Map;
    r.response.write(
      jsonEncode({
        'id': 'chatcmpl-ai-fixture-${modelRequests.length}',
        'model': 'qwen-plus',
        'usage': {'prompt_tokens': 37, 'completion_tokens': 22},
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {
              'content': jsonEncode({
                'sourceId': input['sourceId'],
                ...modelResult ??
                    {
                      'manifestVersion': 3,
                      'kind': 'ordinary',
                      'title': '记录想法',
                      'body': '整理后的普通想法。',
                      'actions': [],
                      'associations': [],
                      'newTopics': [],
                    },
              }),
            },
          },
        ],
      }),
    );
    await r.response.close();
  }

  /// Bailian's qwen3-asr-flash reply through chat/completions.
  Future<void> _transcribe(HttpRequest r, Map<String, dynamic> request) async {
    audioRequests.add(request);
    final status = audioStatuses.isEmpty ? 200 : audioStatuses.removeAt(0);
    final content = ((request['messages'] as List).single as Map)['content'];
    final data =
        (((content as List).single as Map)['input_audio'] as Map)['data']
            as String;
    final header = ByteData.sublistView(
      Uint8List.fromList(base64Decode(data.split(',').last)),
    );
    audioSeconds.add(
      (header.getUint32(40, Endian.little) /
              header.getUint32(28, Endian.little))
          .ceil(),
    );
    await beforeAudioReply?.call();
    r.response.statusCode = status;
    if (status != 200) {
      r.response.write('{}');
      await r.response.close();
      return;
    }
    r.response.write(
      jsonEncode({
        'id': 'chatcmpl-asr-fixture-${audioRequests.length}',
        'model': 'qwen3-asr-flash',
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {
              'role': 'assistant',
              'content': partTranscripts.isEmpty
                  ? transcript
                  : partTranscripts.removeAt(0),
            },
          },
        ],
        'usage': {'seconds': audioSeconds.last},
      }),
    );
    await r.response.close();
  }

  Future<NoteWorkspace> _open(int i) => NoteWorkspace.open(
    localDirectory: Directory('${root.path}/local$i'),
    vaultDirectory: Directory('${root.path}/vault$i'),
    audioPlatform: i == 0 ? recorder : null,
    clock: () => now,
    connection: WorkspaceConnection(
      secureStore: _stores[i],
      textApiBase: Uri.parse('http://127.0.0.1:${_router.port}/'),
      keyCheck: AiKeyCheck(
        endpoint: Uri.parse('http://127.0.0.1:${_router.port}/key'),
      ),
      pairingEndpoint: Uri.parse('http://127.0.0.1:${_router.port}'),
      allowLocalPairingForTests: true,
    ),
  );

  /// [whileClosed] runs between closing and reopening, e.g. to stand in for
  /// data an older app version saved.
  Future<void> reopen(
    int i, {
    void Function(Directory local)? whileClosed,
  }) async {
    await workspaces[i].close();
    whileClosed?.call(Directory('${root.path}/local$i'));
    workspaces[i] = await _open(i);
  }

  Future<void> close() async {
    for (final w in workspaces) {
      await w.close();
    }
    await _router.close(force: true);
    _proxy.close(force: true);
    _worker.kill(ProcessSignal.sigterm);
    await _worker.exitCode;
    await root.delete(recursive: true);
  }
}

class _RealHttpOverrides extends HttpOverrides {}
