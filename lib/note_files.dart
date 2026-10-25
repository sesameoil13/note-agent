import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

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
/// POSIX hard-link creation and Windows same-volume moves are exclusive. Staging
/// is on the vault's own filesystem, so publication never falls back to copying
/// partial contents into the destination. Retrying can safely rewrite staging.
class AtomicNoteFilePublisher implements NoteFilePublisher {
  static final _link = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Utf8>, Pointer<Utf8>)
      >('link');

  static final _windowsLibrary = DynamicLibrary.open('kernel32.dll');
  static final _moveFile = _windowsLibrary
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('MoveFileExW');
  static final _lastError = _windowsLibrary
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  @override
  Future<void> publish({
    required File destination,
    required File staging,
    required String text,
  }) async {
    if (!Platform.isMacOS &&
        !Platform.isLinux &&
        !Platform.isAndroid &&
        !Platform.isWindows) {
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
    await _commit(destination, staging);
  }

  /// Publishes a finalized binary original without replacing an existing file.
  Future<void> publishFile({
    required File destination,
    required File staging,
    required File original,
  }) async {
    final bytes = await original.readAsBytes();
    final type = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound) {
      if (type == FileSystemEntityType.file) {
        final existing = await destination.readAsBytes();
        if (existing.length == bytes.length) {
          var equal = true;
          for (var index = 0; index < bytes.length; index++) {
            if (existing[index] != bytes[index]) {
              equal = false;
              break;
            }
          }
          if (equal) return;
        }
      }
      throw FileSystemException('已有不同的原音频，保留现有文件及本机原音频。', destination.path);
    }
    if (await FileSystemEntity.type(staging.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException('暂存文件不可使用符号链接。', staging.path);
    }
    await staging.writeAsBytes(bytes, flush: true);
    await _commit(destination, staging);
    final published = await destination.readAsBytes();
    if (published.length != bytes.length) {
      throw FileSystemException('音频写入核对未通过，本机原音频仍保留。', destination.path);
    }
    for (var index = 0; index < bytes.length; index++) {
      if (published[index] != bytes[index]) {
        throw FileSystemException('音频写入核对未通过，本机原音频仍保留。', destination.path);
      }
    }
  }

  Future<void> _commit(File destination, File staging) async {
    if (Platform.isWindows) {
      // Neither REPLACE_EXISTING nor COPY_ALLOWED is set: an existing target
      // survives races, and different volumes fail rather than expose a copy.
      final (result, error) = using((arena) {
        final result = _moveFile(
          _windowsPath(staging).toNativeUtf16(allocator: arena),
          _windowsPath(destination).toNativeUtf16(allocator: arena),
          0x8, // MOVEFILE_WRITE_THROUGH
        );
        return (result, result == 0 ? _lastError() : 0);
      });
      if (result == 0) {
        throw FileSystemException(
          '无法发布完整笔记，请检查目录权限或已有同名文件。',
          destination.path,
          OSError('Windows 文件写入失败', error),
        );
      }
      return;
    }
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

  String _windowsPath(File file) {
    // `\\?\` disables Win32 normalization, so `/` separators and `.` parts
    // must be resolved here first.
    final path = p.normalize(file.absolute.path);
    if (path.startsWith(r'\\?\')) return path;
    if (path.startsWith(r'\\')) return r'\\?\UNC\' + path.substring(2);
    return r'\\?\' + path;
  }
}
