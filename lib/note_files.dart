import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// File-system boundary. Staging files belong exclusively to this capture.
abstract interface class NoteFilePublisher {
  Future<void> publish({
    required File destination,
    required File staging,
    required String text,
  });
}

/// Publishes complete files without replacing a pre-existing destination.
///
/// POSIX hard-link creation is atomic and exclusive. Staging is on the vault's
/// own filesystem, so a process interruption leaves either no destination or a
/// complete one. Retrying can safely rewrite our staging file. Other platforms
/// provide their own atomic, no-replacement publisher through this boundary.
class AtomicNoteFilePublisher implements NoteFilePublisher {
  static final _link = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Utf8>)
      >('link');

  @override
  Future<void> publish({
    required File destination,
    required File staging,
    required String text,
  }) async {
    if (!Platform.isMacOS && !Platform.isLinux && !Platform.isAndroid) {
      throw const FileSystemException('此平台的原子笔记写入尚未接入。');
    }
    final targetType = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound) {
      if (targetType == FileSystemEntityType.file &&
          await destination.readAsString() == text) {
        return;
      }
      throw FileSystemException('已有同名文件，保留现有文件及本机原文。', destination.path);
    }
    if (await FileSystemEntity.type(staging.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException('暂存文件不可使用符号链接。', staging.path);
    }
    await staging.writeAsString(text, flush: true);
    final result = using(
      (arena) => _link(
        staging.path.toNativeUtf8(allocator: arena),
        destination.path.toNativeUtf8(allocator: arena),
      ),
    );
    if (result != 0) {
      throw FileSystemException('无法发布完整笔记，请检查目录权限或已有同名文件。', destination.path);
    }
  }
}
