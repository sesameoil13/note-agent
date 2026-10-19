import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'note_files.dart';
import 'workspace_setup.dart';
export 'workspace_setup.dart' hide WorkspaceSetup;
import 'connection.dart';
import 'cloud_budget.dart';
export 'cloud_budget.dart';
import 'attachments.dart';
import 'note_links.dart';
export 'attachments.dart' hide WorkspaceAttachments;
import 'vault_storage.dart';
import 'sync_policy.dart';
import 'recordings.dart';
import 'audio_queue.dart';
export 'audio_queue.dart'
    hide WorkspaceAudioQueue, AudioQueueCommit, AudioNoteMaterializer;
import 'document_extraction.dart';
import 'pdf_extractor.dart';
import 'word_extractor.dart';
export 'document_extraction.dart';
export 'sync_policy.dart';
export 'recordings.dart' hide WorkspaceRecordings;
export 'vault_storage.dart';
export 'note_files.dart' show NoteFilePublisher, AtomicNoteFilePublisher;

/// Local file publication is separate from any future sync acknowledgement.
enum NoteStatus {
  exportPending,
  localSaved,
  exportFailed,
  renamePending,
  renameFailed,
}

/// Official Sync provides no acknowledgement to this app. Local publication
/// can only establish eligibility, never arrival on another device.
enum NoteSyncStatus { notPublished, unverified, attachmentBlocked }

/// The lightweight task-status connection is independent of note-file Sync.
enum TaskStatusSync { notConnected }

/// A collected note, exposed without storage or processing implementation details.
class WorkspaceNote {
  const WorkspaceNote({
    required this.id,
    required this.title,
    required this.text,
    required this.createdAt,
    required this.modifiedAt,
    required this.notePath,
    required this.sourcePath,
    required this.status,
    this.titleCollision = false,
    this.error,
    this.attachments = const [],
    this.sourceText,
    this.document,
  });

  final String id;
  final String title;
  final String text;
  final String? sourceText;
  String get originalText => sourceText ?? text;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String notePath;
  final String sourcePath;
  final NoteStatus status;

  /// Numbering was needed after the supplied semantic alternatives conflicted.
  final bool titleCollision;
  final String? error;

  final List<WorkspaceAttachment> attachments;
  final WorkspaceDocument? document;

  NoteSyncStatus get syncStatus {
    if (attachments.any((item) => item.hasLocalOnlyOriginal)) {
      return NoteSyncStatus.attachmentBlocked;
    }
    return status == NoteStatus.localSaved
        ? NoteSyncStatus.unverified
        : NoteSyncStatus.notPublished;
  }
}

/// The public business boundary shared by the app and behavioral tests.
///
/// Original text and stable identity are committed locally before note export.
/// Use a dedicated test vault during development; no vault is discovered implicitly.
class NoteWorkspace {
  NoteWorkspace._(
    this._database,
    this.vaultStorage,
    this._clock,
    this._createId,
    this.connection,
  );

  WorkspaceBudgetState get budget => const WorkspaceBudgetState();

  late final WorkspaceRecordings _recordings;
  late final WorkspaceSetup _setup;
  WorkspaceSetupState get setup => _setup.state;
  Future<void> reportSetupCheck(SetupCheck check, bool checked) =>
      _mutate(() async => _setup.report(check, checked));
  Future<void> confirmRemoteSlotSwitch() =>
      _mutate(() async => _setup.consent());
  Future<void> clearSetupReports() => _mutate(() async => _setup.clear());
  late final WorkspaceAudioQueue _audioQueue;

  String newAudioSubmissionId() => _randomId();
  List<WorkspaceAudioSource> get audioSources => _audioQueue.sources;
  Future<WorkspaceAudioSource> importAudio({
    required File original,
    required String submissionId,
  }) => _mutate(() async {
    final result = await _audioQueue.import(original, submissionId);
    if (_audioQueue.processor == null) _audioQueue.markDisconnected();
    return _audioQueue.source(result.id);
  });
  late final WorkspaceAttachments _attachments;

  List<WorkspaceAttachment> get attachments => _attachments.attachments;

  Future<WorkspaceAttachment> attachFile({
    required String noteId,
    required File original,
  }) => _mutate(() => _attachments.attach(noteId, original));

  Future<WorkspaceAttachment> chooseAttachmentCopy({
    required String attachmentId,
    required File copy,
  }) => _mutate(() => _attachments.chooseCopy(attachmentId, copy));

  Future<WorkspaceAttachment> retainAttachmentLocally(String attachmentId) =>
      _mutate(() => _attachments.retainLocally(attachmentId));

  Future<WorkspaceAttachment> retryAttachmentExport(String attachmentId) =>
      _mutate(() => _attachments.export(attachmentId));

  Future<void> _adoptRecording(WorkspaceRecording recording) =>
      _audioQueue.adoptRecording(
        id: recording.id,
        original: File(recording.originalPath),
        sourcePath: recording.sourcePath,
        createdAt: recording.createdAt,
      );

  bool get audioSourcePlaybackAvailable =>
      _recordings.audio is AudioSourcePlayer;
  Future<void> playAudioSource(String id) => _mutate(() async {
    final source = _audioQueue.source(id);
    if (!source.originalSaved || source.metadata == null) {
      throw StateError('此原件尚未通过音频检查，请打开原件核对。');
    }
    await _recordings.playSource(id, source.originalPath);
  });
  Future<void> retryAudioSourceExport(String id) => _mutate(() async {
    await _audioQueue.publish(id);
    final source = _audioQueue.source(id);
    if (source.publicationStatus == AudioPublicationStatus.published &&
        notes.any(
          (n) =>
              n.id == source.outputNoteId && n.status == NoteStatus.localSaved,
        ) &&
        attachments.any((a) => a.id == id)) {
      await _attachments.acknowledgeAudioPublication(id);
    }
  });

  Future<void> resumePendingAudioProcessing() =>
      _audioQueue.run(_mutate, _materializeAudioNote);

  Future<void> retryAudioProcessing(String id) async {
    await _mutate(() => _audioQueue.retry(id));
    await resumePendingAudioProcessing();
  }

  Future<void> _materializeAudioNote(
    WorkspaceAudioSource source,
    AudioOrganizedNote output,
  ) async {
    final id = source.outputNoteId;
    if (!notes.any((note) => note.id == id)) {
      final title = _safeTitle(output.title);
      _database.execute(
        '''INSERT INTO notes
        (id,vault,title,body,created_at,modified_at,note_path,source_path,status,naming_request)
        VALUES (?,?,?,?,?,?,?,?,?,?)''',
        [
          id,
          vaultStorage.identity,
          title,
          output.text,
          source.createdAt.toIso8601String(),
          _clock().toIso8601String(),
          vaultStorage.reference('$title.md'),
          vaultStorage.reference('attachments/note-agent/$id.txt'),
          NoteStatus.exportPending.name,
          jsonEncode({
            'title': title,
            'alternatives': <String>[],
            'allocated': false,
          }),
        ],
      );
    }
    _attachments.adoptAudio(
      id: source.id,
      noteId: id,
      name: source.originalName,
      originalPath: source.originalPath,
      bytes: source.byteLength,
      sourcePath: source.sourcePath,
      published: source.publicationStatus == AudioPublicationStatus.published,
      sourceEntry: _audioSourceEntry(source),
      error: source.publicationError,
    );
    final note = await _retryNoteExport(id);
    if (note.status != NoteStatus.localSaved) {
      throw const AudioProcessingFailure(
        AudioProcessingFailureKind.recoverable,
        '转写与整理已保留，笔记库写入未完成。',
      );
    }
  }

  final Database _database;
  final WorkspaceConnection connection;
  final VaultStorage vaultStorage;

  TaskStatusSync get taskStatusSync => TaskStatusSync.notConnected;

  Future<SyncStorageOverview> inspectSyncStorage() async {
    final storage = vaultStorage;
    if (storage is! DirectoryVaultStorage) {
      return const SyncStorageOverview(localVaultBytes: null);
    }
    var bytes = 0;
    try {
      await for (final entity in storage.directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) bytes += await entity.length();
      }
      return SyncStorageOverview(localVaultBytes: bytes);
    } on FileSystemException {
      return const SyncStorageOverview(localVaultBytes: null);
    }
  }

  /// Compatibility for desktop callers; SAF references are not local paths.
  Directory get vaultDirectory {
    final storage = vaultStorage;
    if (storage is DirectoryVaultStorage) return storage.directory;
    throw UnsupportedError('此笔记库通过系统文档授权访问。');
  }

  final DateTime Function() _clock;
  final String Function() _createId;
  Future<void> _mutations = Future.value();
  int _pendingMutations = 0;
  bool _closing = false;
  Future<void>? _closeFuture;
  final Set<Future<void>> _documentOperations = {};
  final Map<String, DocumentExtractor> _activeDocuments = {};
  final Set<String> _retryingDocuments = {};
  final Set<String> _cancelledDocuments = {};

  static Future<NoteWorkspace> open({
    required Directory localDirectory,
    Directory? vaultDirectory,
    VaultStorage? vaultStorage,
    DateTime Function()? clock,
    String Function()? createId,
    NoteFilePublisher? filePublisher,
    WorkspaceConnection? connection,
    AudioPlatform? audioPlatform,
    AudioSourceInspector? audioInspector,
    AudioProcessor? audioProcessor,
  }) async {
    if (vaultStorage == null) {
      if (vaultDirectory == null || !await vaultDirectory.exists()) {
        throw const FileSystemException('所选笔记库不存在，请重新选择。');
      }
      vaultStorage = DirectoryVaultStorage(
        Directory(await vaultDirectory.resolveSymbolicLinks()),
        filePublisher: filePublisher,
      );
    }
    await localDirectory.create(recursive: true);
    final database = sqlite3.open(
      p.join(localDirectory.path, 'workspace.sqlite3'),
    );
    database.execute('PRAGMA journal_mode = WAL');
    database.execute('PRAGMA synchronous = FULL');
    database.execute('''CREATE TABLE IF NOT EXISTS notes (
      id TEXT PRIMARY KEY,
      vault TEXT NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL,
      note_path TEXT NOT NULL,
      source_path TEXT NOT NULL,
      status TEXT NOT NULL,
      error TEXT
    )''');
    if (!database
        .select('PRAGMA table_info(notes)')
        .any((row) => row['name'] == 'title_collision')) {
      database.execute(
        'ALTER TABLE notes ADD COLUMN title_collision INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!database
        .select('PRAGMA table_info(notes)')
        .any((row) => row['name'] == 'naming_request')) {
      database.execute('ALTER TABLE notes ADD COLUMN naming_request TEXT');
    }
    database.execute('''CREATE TABLE IF NOT EXISTS note_renames (
      note_id TEXT PRIMARY KEY,
      vault TEXT NOT NULL,
      payload TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE IF NOT EXISTS document_imports (
      note_id TEXT PRIMARY KEY, vault TEXT NOT NULL, attachment_id TEXT,
      status TEXT NOT NULL, result TEXT, error TEXT, write_plan TEXT
    )''');
    final workspace = NoteWorkspace._(
      database,
      vaultStorage,
      clock ?? DateTime.now,
      createId ?? _randomId,
      connection ?? WorkspaceConnection.platform(),
    );
    workspace._setup = WorkspaceSetup(database, vaultStorage.identity, workspace._clock);
    workspace._attachments = WorkspaceAttachments(
      database,
      localDirectory,
      vaultStorage,
      workspace._createId,
    );
    workspace._recordings = WorkspaceRecordings(
      database,
      localDirectory,
      vaultStorage,
      audioPlatform,
      clock ?? DateTime.now,
      createId ?? _randomId,
      onFinalized: (recording) => workspace._adoptRecording(recording),
    );
    workspace._audioQueue = WorkspaceAudioQueue(
      database,
      localDirectory,
      vaultStorage,
      audioInspector ??
          (audioPlatform is AudioSourceInspector
              ? audioPlatform as AudioSourceInspector
              : PcmWaveInspector()),
      workspace._clock,
      workspace._createId,
      audioProcessor,
    );
    await workspace._audioQueue.recover();
    if (audioProcessor == null) workspace._audioQueue.markDisconnected();
    await workspace._recordings.recover();
    for (final recording in workspace.recordings.where(
      (r) =>
          r.status == RecordingStatus.localSaved ||
          r.status == RecordingStatus.exportFailed ||
          r.status == RecordingStatus.savePending,
    )) {
      await workspace._adoptRecording(recording);
    }
    await workspace._recoverDocuments();
    for (final note in workspace.notes) {
      if (note.status == NoteStatus.exportPending &&
          (note.document == null || note.document!.result != null)) {
        await workspace.retryNoteExport(note.id);
      }
    }
    for (final row in database.select(
      'SELECT note_id FROM note_renames WHERE vault = ?',
      [vaultStorage.identity],
    )) {
      await workspace._finishRename(row['note_id'] as String);
    }
    await workspace._attachments.recover();
    return workspace;
  }

  List<WorkspaceNote> get notes => List.unmodifiable(
    _database
        .select(
          'SELECT * FROM notes WHERE vault = ? ORDER BY created_at DESC, id DESC',
          [vaultStorage.identity],
        )
        .map(_noteFromRow),
  );

  /// Find durable originals without requiring an exported note or a network.
  /// An empty query returns recent records in the same order as [notes].
  List<WorkspaceNote> search(String query) {
    final keyword = query.trim().toLowerCase();
    final titleKeyword = _normalizeTitlePunctuation(keyword);
    return List.unmodifiable(
      notes.where(
        (note) =>
            keyword.isEmpty ||
            _normalizeTitlePunctuation(note.title.toLowerCase())
                .contains(titleKeyword) ||
            note.text.toLowerCase().contains(keyword),
      ),
    );
  }

  Future<WorkspaceNote> captureText({
    required String title,
    required String text,
    List<String> semanticTitleCandidates = const [],
  }) => _mutate(() async {
    if (text.trim().isEmpty) throw ArgumentError('请输入要保存的文字。');
    final safeTitle = _safeTitle(title);
    final id = _createId();
    final now = _clock();
    final note = WorkspaceNote(
      id: id,
      title: safeTitle,
      text: text,
      createdAt: now,
      modifiedAt: now,
      notePath: vaultStorage.reference('$safeTitle.md'),
      sourcePath: vaultStorage.reference('attachments/note-agent/$id.txt'),
      status: NoteStatus.exportPending,
    );
    _database.execute(
      '''INSERT INTO notes
      (id, vault, title, body, created_at, modified_at, note_path, source_path, status, naming_request)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        vaultStorage.identity,
        safeTitle,
        text,
        now.toIso8601String(),
        now.toIso8601String(),
        note.notePath,
        note.sourcePath,
        NoteStatus.exportPending.name,
        jsonEncode({
          'title': safeTitle,
          'alternatives': semanticTitleCandidates,
          'allocated': false,
        }),
      ],
    );
    return _retryNoteExport(id);
  });

  /// Candidates are semantic alternatives supplied by the organizing service.
  /// This workspace performs no AI calls and invents no semantic alternatives.
  Future<({String title, bool collision})> _chooseTitle(
    String title,
    List<String> alternatives, {
    String? excludingId,
    bool ownsCurrentFile = true,
  }) async {
    final preferred = _safeTitle(title);
    final current = excludingId == null
        ? null
        : notes.firstWhere((note) => note.id == excludingId);
    final currentPath = current == null || !ownsCurrentFile
        ? null
        : vaultStorage.relativePath(current.notePath);
    final occupied = <String>{
      for (final note in notes)
        if (note.id != excludingId)
          _normalizeTitlePunctuation(note.title).toLowerCase(),
    };
    for (final path in await vaultStorage.listNotePaths()) {
      if (path != currentPath) {
        occupied.add(
          _normalizeTitlePunctuation(
            p.posix.basenameWithoutExtension(path.replaceAll('\\', '/')),
          ).toLowerCase(),
        );
      }
    }
    final candidates = <String>[preferred];
    for (final alternative in alternatives) {
      try {
        candidates.add(_safeTitle(alternative));
      } on ArgumentError {
        // An unusable service alternative must not block a valid capture.
      }
    }
    for (final candidate in candidates) {
      if (!occupied.contains(candidate.toLowerCase()) &&
          ('$candidate.md' == currentPath ||
              !await vaultStorage.exists('$candidate.md'))) {
        return (title: candidate, collision: false);
      }
    }
    var number = 2;
    while (occupied.contains('$preferred ($number)'.toLowerCase()) ||
        await vaultStorage.exists('$preferred ($number).md')) {
      number++;
    }
    return (title: '$preferred ($number)', collision: true);
  }

  String _safeTitle(String title) {
    var safe = _normalizeTitlePunctuation(title)
        .trim()
        .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty || safe == '.' || safe == '..') {
      throw ArgumentError('请输入可用的笔记标题。');
    }
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(safe)) {
      safe = '笔记 $safe';
    }
    return safe;
  }

  /// Obsidian reserves these ASCII characters for headings, blocks, aliases,
  /// comments and wiki syntax. Fullwidth forms retain readable punctuation
  /// (including C＃) while producing one linkable title across all entry points.
  String _normalizeTitlePunctuation(String title) => title.replaceAllMapped(
    RegExp(r'[#|^:%\[\]]'),
    (match) => const {
      '#': '＃',
      '|': '｜',
      '^': '＾',
      ':': '：',
      '%': '％',
      '[': '［',
      ']': '］',
    }[match[0]]!,
  );

  Future<T> _mutate<T>(Future<T> Function() action, {bool accepted = false}) {
    if (_closing && !accepted) {
      return Future<T>.error(StateError('工作区正在关闭，请重新打开后再操作。'));
    }
    _pendingMutations++;
    final result = _mutations.then((_) async {
      try {
        return await action();
      } finally {
        _pendingMutations--;
      }
    });
    _mutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Rename without replacing a same-named note. Inbound links are updated
  /// before removing the old file, and a durable plan resumes after restart.
  Future<WorkspaceNote> renameNote(
    String id, {
    required String title,
    List<String> semanticTitleCandidates = const [],
  }) => _mutate(() async {
    if (_renamePlan(id) != null) {
      final recovered = await _finishRename(id);
      if (recovered.status != NoteStatus.localSaved) return recovered;
    }
    final note = notes.firstWhere((note) => note.id == id);
    if (note.status != NoteStatus.localSaved) {
      throw StateError('请先完成笔记库写入，再修改标题。');
    }
    final naming = await _chooseTitle(
      title,
      semanticTitleCandidates,
      excludingId: id,
    );
    if (naming.title == note.title) return note;
    final oldPath = vaultStorage.relativePath(note.notePath);
    final newPath = '${naming.title}.md';
    final original = await vaultStorage.readText(oldPath);
    final now = _clock();
    final sourceTime =
        '\n记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(note.modifiedAt)}\n';
    var renamed = rewriteNoteLinks(original, oldPath, oldPath, newPath);
    if (renamed.endsWith(sourceTime)) {
      renamed =
          '${renamed.substring(0, renamed.length - sourceTime.length)}\n记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(now)}\n';
    }
    final updates = <Map<String, String>>[];
    for (final path in await vaultStorage.listNotePaths()) {
      if (path == oldPath) continue;
      final before = await vaultStorage.readText(path);
      final after = rewriteNoteLinks(before, path, oldPath, newPath);
      if (before != after) {
        updates.add({'path': path, 'before': before, 'after': after});
      }
    }
    final plan = {
      'oldPath': oldPath,
      'newPath': newPath,
      'original': original,
      'renamed': renamed,
      'title': naming.title,
      'collision': naming.collision,
      'modifiedAt': now.toIso8601String(),
      'updates': updates,
    };
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        'INSERT INTO note_renames (note_id, vault, payload) VALUES (?, ?, ?)',
        [id, vaultStorage.identity, jsonEncode(plan)],
      );
      _database.execute(
        'UPDATE notes SET status = ?, error = NULL WHERE id = ?',
        [NoteStatus.renamePending.name, id],
      );
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
    return _finishRename(id);
  });

  Map<String, dynamic>? _renamePlan(String id) {
    final rows = _database.select(
      'SELECT payload FROM note_renames WHERE note_id = ? AND vault = ?',
      [id, vaultStorage.identity],
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
  }

  Future<WorkspaceNote> _finishRename(String id) async {
    final plan = _renamePlan(id)!;
    try {
      await vaultStorage.publishText(
        plan['newPath'] as String,
        plan['renamed'] as String,
        'rename-$id',
      );
      for (final update in plan['updates'] as List<dynamic>) {
        await vaultStorage.replaceText(
          update['path'] as String,
          update['before'] as String,
          update['after'] as String,
          'rename-$id',
        );
        _inboundNoteContentsChanged(
          update['path'] as String,
          update['after'] as String,
        );
      }
      await vaultStorage.deleteText(
        plan['oldPath'] as String,
        plan['original'] as String,
      );
      _database.execute('BEGIN IMMEDIATE');
      try {
        _database.execute(
          'UPDATE notes SET title = ?, note_path = ?, modified_at = ?, title_collision = ?, status = ?, error = NULL WHERE id = ?',
          [
            plan['title'],
            vaultStorage.reference(plan['newPath'] as String),
            plan['modifiedAt'],
            plan['collision'] == true ? 1 : 0,
            NoteStatus.localSaved.name,
            id,
          ],
        );
        _attachments.noteContentsChanged(id, plan['renamed'] as String);
        _database.execute('DELETE FROM note_renames WHERE note_id = ?', [id]);
        _database.execute('COMMIT');
      } catch (_) {
        _database.execute('ROLLBACK');
        rethrow;
      }
    } on FileSystemException catch (error) {
      _database.execute('UPDATE notes SET status = ?, error = ? WHERE id = ?', [
        NoteStatus.renameFailed.name,
        error.message,
        id,
      ]);
    }
    return notes.firstWhere((note) => note.id == id);
  }

  void _inboundNoteContentsChanged(String relativePath, String text) {
    final owners = _database.select(
      'SELECT id FROM notes WHERE vault = ? AND note_path = ?',
      [vaultStorage.identity, vaultStorage.reference(relativePath)],
    );
    if (owners.isEmpty) return;
    _database.execute('BEGIN IMMEDIATE');
    try {
      for (final owner in owners) {
        _attachments.noteContentsChanged(owner['id'] as String, text);
      }
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
    // The parent's durable rename plan stays until every update is complete.
    // If interrupted before this commit, replay acknowledges the same file and
    // repeats this rebase before attachment recovery runs.
  }

  /// Retries publication of an existing durable capture without collecting again.
  Future<WorkspaceNote> retryNoteExport(String id) =>
      _mutate(() => _retryNoteExport(id));

  Future<WorkspaceNote> _retryNoteExport(String id) async {
    if (_renamePlan(id) != null) return _finishRename(id);
    var note = notes.firstWhere((note) => note.id == id);
    if (note.document != null && note.document!.result == null) return note;
    try {
      final rawRequest =
          _database.select('SELECT naming_request FROM notes WHERE id = ?', [
                id,
              ]).single['naming_request']
              as String?;
      if (rawRequest != null) {
        final request = jsonDecode(rawRequest) as Map<String, dynamic>;
        final path = vaultStorage.relativePath(note.notePath);
        final ownsCurrentFile =
            request['allocated'] == true &&
            await vaultStorage.exists(path) &&
            await vaultStorage.readText(path) == _markdown(note);
        if (!ownsCurrentFile) {
          final naming = await _chooseTitle(
            request['title'] as String,
            (request['alternatives'] as List<dynamic>).cast<String>(),
            excludingId: id,
            ownsCurrentFile: false,
          );
          request['allocated'] = true;
          _database.execute(
            'UPDATE notes SET title = ?, note_path = ?, title_collision = ?, naming_request = ? WHERE id = ?',
            [
              naming.title,
              vaultStorage.reference('${naming.title}.md'),
              naming.collision ? 1 : 0,
              jsonEncode(request),
              id,
            ],
          );
          note = notes.firstWhere((note) => note.id == id);
        }
      }
      await vaultStorage.publishText(
        vaultStorage.relativePath(note.sourcePath),
        _audioQueue.sources
                .where((s) => s.outputNoteId == note.id)
                .firstOrNull
                ?.transcript ??
            note.text,
        note.id,
      );
      await vaultStorage.publishText(
        vaultStorage.relativePath(note.notePath),
        _markdown(note),
        note.id,
      );
      _database.execute(
        'UPDATE notes SET status = ?, error = NULL, naming_request = NULL WHERE id = ?',
        [NoteStatus.localSaved.name, id],
      );
      if (note.document != null) {
        final source = attachments.firstWhere(
          (a) => a.id == note.document!.attachmentId,
        );
        if (source.hasLocalOnlyOriginal && source.copyPath == null) {
          await _attachments.writeEntry(
            source,
            source.status == AttachmentStatus.retainedLocal
                ? '${source.originalName}（仅本机保留，未同步）'
                : '${source.originalName}（仅本机保留，超过 Standard 单文件 5 MB）',
          );
        } else {
          await _attachments.export(source.id);
        }
      }
    } on FileSystemException catch (error) {
      _database.execute('UPDATE notes SET status = ?, error = ? WHERE id = ?', [
        NoteStatus.exportFailed.name,
        error.message,
        id,
      ]);
    }
    return notes.firstWhere((note) => note.id == id);
  }

  bool get recordingAvailable => _recordings.audio != null;
  RecordingState get recording => _recordings.state;
  PlaybackState get playback => _recordings.playback;
  List<WorkspaceRecording> get recordings => _recordings.recordings;
  Future<void> startRecording() => _mutate(_recordings.start);
  Future<void> pauseRecording() => _mutate(_recordings.pause);
  Future<void> resumeRecording() => _mutate(_recordings.resume);
  Future<void> refreshRecording() => _recordings.refresh();
  Future<WorkspaceRecording> stopRecording() => _mutate(_recordings.stop);
  Future<WorkspaceRecording> retryRecordingExport(String id) =>
      _mutate(() => _recordings.export(id));
  Future<void> playRecording(String id) => _mutate(() => _recordings.play(id));
  Future<void> refreshPlayback() => _recordings.refreshPlayback();
  Future<void> stopPlayback() => _mutate(_recordings.stopPlayback);

  /// Drain accepted mutations and recording finalization before releasing SQLite.
  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closing = true;
    _audioQueue.stop();
    for (final extractor in _activeDocuments.values) {
      extractor.cancel();
    }
    if (_pendingMutations == 0 &&
        !_recordings.needsClosing &&
        _documentOperations.isEmpty) {
      _database.close();
      return _closeFuture = Future<void>.value();
    }
    return _closeFuture = Future.wait(_documentOperations.toList())
        .then((_) => _mutations)
        .then((_) async {
          try {
            await _recordings.close();
          } finally {
            _database.close();
          }
        });
  }

  WorkspaceNote _noteFromRow(Row row) => WorkspaceNote(
    id: row['id'] as String,
    title: row['title'] as String,
    text: row['body'] as String,
    sourceText: _audioQueue.sources
        .where((s) => s.outputNoteId == row['id'])
        .firstOrNull
        ?.transcript,
    createdAt: DateTime.parse(row['created_at'] as String),
    modifiedAt: DateTime.parse(row['modified_at'] as String),
    notePath: row['note_path'] as String,
    sourcePath: row['source_path'] as String,
    status: NoteStatus.values.byName(row['status'] as String),
    titleCollision: row['title_collision'] == 1,
    error: row['error'] as String?,
    attachments: List.unmodifiable(
      _attachments.attachments.where((item) => item.noteId == row['id']),
    ),
    document: _document(row['id'] as String),
  );

  String _audioSourceEntry(WorkspaceAudioSource source) =>
      source.publicationStatus == AudioPublicationStatus.published
      ? '[${source.originalName}](${Uri(path: vaultStorage.relativePath(source.sourcePath))})'
      : '${source.originalName}（${source.publicationStatus == AudioPublicationStatus.exceedsFileLimit ? '原件仅本机保留' : '原件已保留'}；${source.publicationError ?? '尚未写入笔记库'}）';

  String _markdown(WorkspaceNote note) {
    final audio = _audioQueue.sources
        .where((s) => s.outputNoteId == note.id)
        .firstOrNull;
    final source = audio == null
        ? '[${note.document == null ? '原始文字' : '提取结果'}](attachments/note-agent/${note.id}.txt)${note.document == null ? '' : '\n\n${_documentSummary(note.document!.result)}'}'
        : '[完整转写](attachments/note-agent/${note.id}.txt)\n\n${_audioSourceEntry(audio)}';
    return '''## 正文

${note.text.trimRight()}

## 关联

暂无关联

## 来源

$source

记录：${formatNoteTime(note.createdAt)} · 修改：${formatNoteTime(note.modifiedAt)}
''';
  }

  WorkspaceDocument? _document(String id) {
    final rows = _database.select(
      'SELECT * FROM document_imports WHERE note_id = ? AND vault = ?',
      [id, vaultStorage.identity],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return WorkspaceDocument(
      noteId: id,
      status: DocumentImportStatus.values.byName(row['status'] as String),
      attachmentId: row['attachment_id'] as String?,
      result: row['result'] == null
          ? null
          : DocumentExtraction.fromJson(
              jsonDecode(row['result'] as String) as Map<String, dynamic>,
            ),
      error: row['error'] as String?,
    );
  }

  String _documentSummary(DocumentExtraction? result) => result == null
      ? '尚未提取正文。'
      : [
          result.summary,
          ...result.problems.map(
            (p) =>
                '${p.page == null ? '' : '第 ${p.page}${p.lastPage == null ? '' : '–${p.lastPage}'} 页：'}${p.message}',
          ),
        ].join('\n');

  /// Retains the private original before opening the local PDF engine. Parsing
  /// runs outside the mutation queue so unrelated text captures remain usable.
  Future<WorkspaceNote> importPdf({
    required File original,
    String? title,
    DocumentExtractionOptions options = const DocumentExtractionOptions(),
  }) => importDocument(original: original, title: title, options: options);

  Future<WorkspaceNote> importDocument({
    required File original,
    String? title,
    DocumentExtractionOptions options = const DocumentExtractionOptions(),
  }) {
    options.validate();
    return _trackDocument(() async {
      final id = await _mutate(() async {
        final safeTitle = _safeTitle(
          title ?? p.basenameWithoutExtension(original.path),
        );
        final id = _createId();
        final now = _clock().toIso8601String();
        _database.execute('BEGIN IMMEDIATE');
        try {
          _database.execute(
            'INSERT INTO notes (id, vault, title, body, created_at, modified_at, note_path, source_path, status, naming_request) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [
              id,
              vaultStorage.identity,
              safeTitle,
              '尚未提取正文。',
              now,
              now,
              vaultStorage.reference('$safeTitle.md'),
              vaultStorage.reference('attachments/note-agent/$id.txt'),
              NoteStatus.exportPending.name,
              jsonEncode({
                'title': safeTitle,
                'alternatives': <String>[],
                'allocated': false,
              }),
            ],
          );
          _database.execute(
            'INSERT INTO document_imports (note_id, vault, status) VALUES (?, ?, ?)',
            [
              id,
              vaultStorage.identity,
              DocumentImportStatus.savingOriginal.name,
            ],
          );
          _database.execute('COMMIT');
        } catch (_) {
          _database.execute('ROLLBACK');
          rethrow;
        }
        try {
          final source = await _attachments.attach(
            id,
            original,
            publish: false,
          );
          _database.execute(
            'UPDATE document_imports SET attachment_id = ?, status = ? WHERE note_id = ?',
            [source.id, DocumentImportStatus.extracting.name, id],
          );
        } catch (_) {
          _database.execute(
            'UPDATE document_imports SET status = ?, error = ? WHERE note_id = ?',
            [
              DocumentImportStatus.originalFailed.name,
              '原件保存尚未完成，请重新选择文件。尚未提取正文。',
              id,
            ],
          );
          rethrow;
        }
        return id;
      });
      return _extractDocument(id, options);
    });
  }

  Future<WorkspaceNote> retryDocumentExtraction(
    String noteId, {
    File? original,
    DocumentExtractionOptions options = const DocumentExtractionOptions(),
  }) {
    options.validate();
    if (_activeDocuments.containsKey(noteId) ||
        !_retryingDocuments.add(noteId)) {
      return Future.error(StateError('此文档正在提取。'));
    }
    return _trackDocument(() async {
      final doc = _document(noteId);
      if (doc == null) throw ArgumentError('此笔记没有文档来源。');
      if (_activeDocuments.containsKey(noteId)) throw StateError('此文档正在提取。');
      if (doc.attachmentId == null) {
        if (original == null) throw StateError('原件未保存完成，请重新选择文档。');
        await _mutate(() async {
          final source = await _attachments.attach(
            noteId,
            original,
            publish: false,
          );
          _database.execute(
            'UPDATE document_imports SET attachment_id = ?, status = ?, error = NULL WHERE note_id = ?',
            [source.id, DocumentImportStatus.extracting.name, noteId],
          );
        });
      } else if (original != null) {
        throw ArgumentError('已保留的文档原件不会被替换，请直接重新提取。');
      }
      final plan = _database.select(
        'SELECT write_plan FROM document_imports WHERE note_id = ?',
        [noteId],
      ).single['write_plan'];
      if (plan != null) return _mutate(() => _finishDocumentWrite(noteId));
      final publication = await _mutate(() async {
        final current = notes.firstWhere((n) => n.id == noteId);
        if (doc.result != null && current.status != NoteStatus.localSaved) {
          final published = await _retryNoteExport(noteId);
          if (published.status != NoteStatus.localSaved) return published;
        }
        _database.execute(
          'UPDATE document_imports SET status = ?, error = NULL WHERE note_id = ?',
          [DocumentImportStatus.extracting.name, noteId],
        );
        return null;
      });
      if (publication != null) return publication;
      return _extractDocument(noteId, options);
    }).whenComplete(() => _retryingDocuments.remove(noteId));
  }

  void cancelDocumentExtraction(String noteId) {
    if (_document(noteId)?.status != DocumentImportStatus.extracting) return;
    _cancelledDocuments.add(noteId);
    _activeDocuments[noteId]?.cancel();
  }

  Future<WorkspaceNote> _trackDocument(
    Future<WorkspaceNote> Function() action,
  ) {
    if (_closing) return Future.error(StateError('工作区正在关闭。'));
    final operation = action();
    late Future<void> tracked;
    tracked = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _documentOperations.remove(tracked));
    _documentOperations.add(tracked);
    return operation;
  }

  Future<bool> _isPdf(File file, String name) async {
    final handle = await file.open();
    try {
      final magic = await handle.read(8);
      if (String.fromCharCodes(magic.take(5)) == '%PDF-') return true;
      if (magic.length >= 2 &&
          (magic[0] == 0x50 && magic[1] == 0x4b ||
              magic[0] == 0xd0 && magic[1] == 0xcf)) {
        return false;
      }
      return p.extension(name).toLowerCase() == '.pdf';
    } finally {
      await handle.close();
    }
  }

  Future<WorkspaceNote> _extractDocument(
    String id,
    DocumentExtractionOptions options,
  ) async {
    final doc = _document(id)!;
    final source = attachments.firstWhere((a) => a.id == doc.attachmentId);
    late final DocumentExtraction result;
    try {
      final DocumentExtractor extractor =
          await _isPdf(File(source.originalPath), source.originalName)
          ? LocalPdfExtractor()
          : LocalWordExtractor();
      _activeDocuments[id] = extractor;
      if (_closing || _cancelledDocuments.remove(id)) extractor.cancel();
      result = await extractor.extract(
        File(source.originalPath),
        source.id,
        options,
      );
    } on FileSystemException {
      return _documentSourceUnavailable(id);
    } finally {
      _activeDocuments.remove(id);
      _cancelledDocuments.remove(id);
    }
    if (result.problems.any((p) => p.code == 'fileUnreadable')) {
      return _documentSourceUnavailable(id);
    }
    return _mutate(() async {
      final note = notes.firstWhere((n) => n.id == id);
      final body = result.markdown.isEmpty ? '尚未提取正文。' : result.markdown;
      if (doc.result == null) {
        _database.execute('BEGIN IMMEDIATE');
        try {
          _database.execute(
            'UPDATE document_imports SET result = ?, status = ?, error = NULL WHERE note_id = ?',
            [jsonEncode(result.toJson()), DocumentImportStatus.ready.name, id],
          );
          _database.execute('UPDATE notes SET body = ? WHERE id = ?', [
            body,
            id,
          ]);
          _database.execute('COMMIT');
        } catch (_) {
          _database.execute('ROLLBACK');
          rethrow;
        }
        await _retryNoteExport(id);
        return notes.firstWhere((n) => n.id == id);
      }
      // Compare the known body before changing an already-published note. The
      // source tail (including external associations/attachment links) stays.
      String before;
      try {
        before = await vaultStorage.readText(
          vaultStorage.relativePath(note.notePath),
        );
      } on FileSystemException {
        _database.execute(
          'UPDATE document_imports SET status = ?, error = ? WHERE note_id = ?',
          [
            DocumentImportStatus.interrupted.name,
            '无法读取笔记，请恢复原位置或重新授权后再提取；文档原件仍保留。',
            id,
          ],
        );
        return notes.firstWhere((n) => n.id == id);
      }
      final oldBody = '## 正文\n\n${note.text.trimRight()}\n\n## 关联';
      final oldSummary = _documentSummary(doc.result);
      if (oldBody.allMatches(before).length != 1 ||
          oldSummary.allMatches(before).length != 1) {
        _database.execute(
          'UPDATE document_imports SET status = ?, error = ? WHERE note_id = ?',
          [
            DocumentImportStatus.interrupted.name,
            '笔记内容已在其他位置修改，请核对原件与笔记后再提取。',
            id,
          ],
        );
        return notes.firstWhere((n) => n.id == id);
      }
      final after = before
          .replaceFirst(oldBody, '## 正文\n\n${body.trimRight()}\n\n## 关联')
          .replaceFirst(oldSummary, _documentSummary(result));
      final plan = {
        'before': before,
        'after': after,
        'oldBody': note.text,
        'body': body,
        'result': result.toJson(),
      };
      _database.execute(
        'UPDATE document_imports SET status = ?, write_plan = ? WHERE note_id = ?',
        [DocumentImportStatus.writePending.name, jsonEncode(plan), id],
      );
      return _finishDocumentWrite(id);
    }, accepted: true);
  }

  Future<WorkspaceNote> _documentSourceUnavailable(String id) =>
      _mutate(() async {
        _database.execute(
          'UPDATE document_imports SET status = ?, error = ? WHERE note_id = ?',
          [
            DocumentImportStatus.interrupted.name,
            '当前来源文件无法读取，可能已缺失或不可访问；已有正文与来源身份未改动。请恢复文件或访问权限后重试。',
            id,
          ],
        );
        return notes.firstWhere((n) => n.id == id);
      }, accepted: true);

  Future<WorkspaceNote> _finishDocumentWrite(String id) async {
    final raw =
        _database.select(
              'SELECT write_plan FROM document_imports WHERE note_id = ?',
              [id],
            ).single['write_plan']
            as String;
    final plan = jsonDecode(raw) as Map<String, dynamic>;
    final note = notes.firstWhere((n) => n.id == id);
    try {
      await vaultStorage.replaceText(
        vaultStorage.relativePath(note.sourcePath),
        plan['oldBody'] as String,
        plan['body'] as String,
        'document-$id',
      );
      await vaultStorage.replaceText(
        vaultStorage.relativePath(note.notePath),
        plan['before'] as String,
        plan['after'] as String,
        'document-$id',
      );
      _database.execute('BEGIN IMMEDIATE');
      try {
        _database.execute('UPDATE notes SET body = ? WHERE id = ?', [
          plan['body'],
          id,
        ]);
        _database.execute(
          'UPDATE document_imports SET result = ?, status = ?, write_plan = NULL, error = NULL WHERE note_id = ?',
          [jsonEncode(plan['result']), DocumentImportStatus.ready.name, id],
        );
        _attachments.noteContentsChanged(id, plan['after'] as String);
        _database.execute('COMMIT');
      } catch (_) {
        _database.execute('ROLLBACK');
        rethrow;
      }
    } on FileSystemException catch (error) {
      _database.execute(
        'UPDATE document_imports SET error = ? WHERE note_id = ?',
        [error.message, id],
      );
    }
    return notes.firstWhere((n) => n.id == id);
  }

  Future<void> _recoverDocuments() async {
    for (final row in _database.select(
      'SELECT * FROM document_imports WHERE vault = ?',
      [vaultStorage.identity],
    )) {
      final id = row['note_id'] as String;
      if (row['write_plan'] != null) {
        await _finishDocumentWrite(id);
        continue;
      }
      final status = DocumentImportStatus.values.byName(
        row['status'] as String,
      );
      if (status == DocumentImportStatus.extracting ||
          status == DocumentImportStatus.savingOriginal) {
        final saved = attachments.where((a) => a.noteId == id).firstOrNull;
        _database.execute(
          'UPDATE document_imports SET attachment_id = ?, status = ?, error = ? WHERE note_id = ?',
          [
            saved?.id,
            (saved == null
                    ? DocumentImportStatus.originalFailed
                    : DocumentImportStatus.interrupted)
                .name,
            saved == null ? '原件保存尚未完成，请重新选择文件。' : '上次提取中断，完整原件已保留，可重新提取。',
            id,
          ],
        );
      }
    }
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

String formatNoteTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
