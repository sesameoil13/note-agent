import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:pdfium_flutter/pdfium_flutter.dart';

import 'document_extraction.dart';
import 'pdf_native.dart';
import 'pdf_layout.dart';

const _engine = 'pdfium/7811 guarded-text-v2';

/// Owns PDFium on one background isolate at a time. Unlike loadText(), this
/// adapter checks native handles and character counts BEFORE Dart allocation.
/// No rendering, URI opening, remote fonts, JavaScript, OCR or network access.
class LocalPdfExtractor implements DocumentExtractor {
  static Future<void> _queue = Future.value();
  SendPort? _cancelPort;
  bool _cancelled = false;
  @override
  void cancel() {
    _cancelled = true;
    _cancelPort?.send('cancel');
  }

  @override
  Future<DocumentExtraction> extract(
    File original,
    String sourceId,
    DocumentExtractionOptions options,
  ) async {
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    await previous;
    final messages = ReceivePort();
    Isolate? isolate;
    try {
      final result = Completer<DocumentExtraction>();
      final exited = Completer<void>();
      messages.listen((message) {
        if (message is SendPort) {
          _cancelPort = message;
          if (_cancelled) message.send('cancel');
        }
        if (message is DocumentExtraction) result.complete(message);
        if (message == null) exited.complete();
        if ((message is List || message == null) && !result.isCompleted) {
          result.complete(
            const DocumentExtraction(
              engine: _engine,
              completion: DocumentCompletion.failed,
              problems: [
                DocumentProblem(
                  'engineUnavailable',
                  '本机 PDF 引擎未能完成处理，请重试；原件已保留。',
                ),
              ],
            ),
          );
        }
      });
      isolate = await Isolate.spawn(
        _worker,
        (messages.sendPort, original.path, sourceId, options),
        onError: messages.sendPort,
        onExit: messages.sendPort,
        errorsAreFatal: true,
      );
      final extraction = await result.future;
      // Result delivery can precede native finally/DestroyLibrary. Keep the
      // global queue locked until the worker has exited and released PDFium.
      await exited.future;
      return extraction;
    } catch (_) {
      return const DocumentExtraction(
        engine: _engine,
        completion: DocumentCompletion.failed,
        problems: [
          DocumentProblem('engineUnavailable', '本机 PDF 引擎无法启动，请重试；原件已保留。'),
        ],
      );
    } finally {
      _cancelPort = null;
      messages.close();
      isolate?.kill();
      done.complete();
    }
  }
}

Future<void> _worker(
  (SendPort, String, String, DocumentExtractionOptions) input,
) async {
  final (output, path, sourceId, options) = input;
  final cancellation = ReceivePort();
  var cancelled = false;
  cancellation.listen((_) => cancelled = true);
  output.send(cancellation.sendPort);
  var initialized = false;
  final timer = Stopwatch()..start();
  FPDF_DOCUMENT document = nullptr;
  try {
    if (await File(path).length() > options.maximumInputBytes) {
      output.send(
        const DocumentExtraction(
          engine: _engine,
          completion: DocumentCompletion.failed,
          problems: [
            DocumentProblem(
              'inputLimit',
              '超过本机 PDF 提取 32 MiB 上限，未打开解析；完整原件已保留。',
            ),
          ],
        ),
      );
      return;
    }
    GuardedPdfium.FPDF_InitLibrary();
    initialized = true;
    document = using(
      (arena) => GuardedPdfium.FPDF_LoadDocument(
        path.toNativeUtf8(allocator: arena).cast(),
        nullptr,
      ),
    );
    if (document == nullptr) {
      final error = GuardedPdfium.FPDF_GetLastError();
      output.send(
        DocumentExtraction(
          engine: _engine,
          completion: DocumentCompletion.failed,
          problems: [
            DocumentProblem(
              switch (error) {
                FPDF_ERR_PASSWORD => 'passwordRequired',
                FPDF_ERR_SECURITY => 'unsupportedSecurity',
                FPDF_ERR_FILE => 'fileUnreadable',
                FPDF_ERR_FORMAT => 'damagedPdf',
                _ => 'openFailed',
              },
              switch (error) {
                FPDF_ERR_PASSWORD => 'PDF 已加密，需要先在本机工具中解锁后重新导入；本次未尝试密码。',
                FPDF_ERR_SECURITY => '此 PDF 的安全设置暂不支持。',
                FPDF_ERR_FILE => '无法读取本机 PDF 原件。',
                _ => 'PDF 无法打开，可能已损坏或格式不受支持。',
              },
            ),
          ],
        ),
      );
      return;
    }
    final total = GuardedPdfium.FPDF_GetPageCount(document);
    final body = <DocumentBody>[];
    final tables = <DocumentTable>[];
    final unprocessed = <DocumentLocation>[];
    final problems = <DocumentProblem>[];
    var processed = 0;
    var characters = 0;
    var outputCharacters = 0;
    for (var index = 0; index < total; index++) {
      await Future<void>.delayed(Duration.zero);
      if (cancelled ||
          timer.elapsed >= options.timeBudget ||
          index >= options.maximumPages) {
        problems.add(
          DocumentProblem(
            cancelled
                ? 'cancelled'
                : index >= options.maximumPages
                ? 'pageLimit'
                : 'timeLimit',
            cancelled ? '已停止后续页面处理；可重新提取，原件继续保留。' : '达到本机提取上限，后续页面尚未处理。',
            page: index + 1,
            lastPage: total,
          ),
        );
        unprocessed.add(
          DocumentLocation(
            coordinateSpace: 'pdf-points-bottom-left',
            sourceId: sourceId,
            page: index + 1,
            lastPage: total,
          ),
        );
        break;
      }
      final location = DocumentLocation(
        coordinateSpace: 'pdf-points-bottom-left',
        sourceId: sourceId,
        page: index + 1,
      );
      FPDF_PAGE page = nullptr;
      FPDF_TEXTPAGE text = nullptr;
      try {
        page = GuardedPdfium.FPDF_LoadPage(document, index);
        if (page == nullptr) throw const _PageProblem('pageFailed', '此页无法打开。');
        text = GuardedPdfium.FPDFText_LoadPage(page);
        if (text == nullptr) {
          throw const _PageProblem('textPageFailed', '此页文字层无法读取。');
        }
        final count = GuardedPdfium.FPDFText_CountChars(text);
        if (count < 0) {
          throw const _PageProblem('textPageFailed', '此页文字计数失败，未当作空白页。');
        }
        if (count > options.maximumPageCharacters ||
            characters + count > options.maximumCharacters) {
          throw const _PageProblem(
            'characterLimit',
            '此页文字数量超过本机提取上限，未分配全部文字及位置。',
          );
        }
        characters += count;
        final glyphs = <PdfGlyph>[];
        var badUnicode = false;
        using((arena) {
          final left = arena<Double>();
          final right = arena<Double>();
          final bottom = arena<Double>();
          final top = arena<Double>();
          final originX = arena<Double>();
          final originY = arena<Double>();
          for (var char = 0; char < count; char++) {
            final value = GuardedPdfium.FPDFText_GetUnicode(text, char);
            String character;
            if (value == 0 ||
                value > 0x10ffff ||
                (value >= 0xd800 && value <= 0xdfff)) {
              character = '\uFFFD';
              badUnicode = true;
            } else {
              character = String.fromCharCode(value);
            }
            final validBox =
                GuardedPdfium.FPDFText_GetCharBox(
                  text,
                  char,
                  left,
                  right,
                  bottom,
                  top,
                ) !=
                0;
            final box = validBox
                ? [left.value, bottom.value, right.value, top.value]
                : null;
            final hasOrigin =
                GuardedPdfium.FPDFText_GetCharOrigin(
                      text,
                      char,
                      originX,
                      originY,
                    ) !=
                    0 &&
                originY.value.isFinite;
            glyphs.add(
              PdfGlyph(
                character,
                box != null && box.every((v) => v.isFinite) ? box : null,
                baseline: hasOrigin ? originY.value : null,
              ),
            );
          }
        });
        final pageLocation = DocumentLocation(
          coordinateSpace: 'pdf-points-bottom-left',
          sourceId: sourceId,
          page: index + 1,
          rotation: GuardedPdfium.FPDFPage_GetRotation(page) * 90,
        );
        final layout = readPdfLayout(
          page,
          glyphs,
          pageLocation,
          options.maximumTableCells -
              tables.fold(
                0,
                (sum, t) => sum + t.rows.fold(0, (n, r) => n + r.length),
              ),
        );
        final serialized = DocumentExtraction(
          engine: _engine,
          completion: DocumentCompletion.complete,
          body: layout.body,
          tables: layout.tables,
        ).markdown;
        if (outputCharacters +
                serialized.length +
                (outputCharacters == 0 ? 0 : 2) >
            options.maximumCharacters) {
          problems.add(
            DocumentProblem(
              'outputLimit',
              '提取后的文字和表格达到输出上限；此页及后续页面未写入，完整原件已保留。',
              page: index + 1,
              lastPage: total,
            ),
          );
          unprocessed.add(
            DocumentLocation(
              coordinateSpace: 'pdf-points-bottom-left',
              sourceId: sourceId,
              page: index + 1,
              lastPage: total,
              rotation: pageLocation.rotation,
            ),
          );
          break;
        }
        outputCharacters += serialized.length + (outputCharacters == 0 ? 0 : 2);
        body.addAll(layout.body);
        tables.addAll(layout.tables);
        problems.addAll(layout.problems);
        if (layout.problems.isNotEmpty) unprocessed.add(pageLocation);
        if (layout.hasImages) {
          unprocessed.add(pageLocation);
          problems.add(
            DocumentProblem(
              'imageRegion',
              '此页含图片或嵌套内容，尚未 OCR；成功提取的文字仍已保留。',
              page: index + 1,
            ),
          );
        }
        if (badUnicode) {
          problems.add(
            DocumentProblem(
              'unmappedText',
              '此页部分文字缺少有效 Unicode 映射，以替代字符保留位置，请核对原件。',
              page: index + 1,
            ),
          );
          unprocessed.add(location);
        }
        if (layout.body.isEmpty && layout.tables.isEmpty) {
          unprocessed.add(location);
          problems.add(
            DocumentProblem(
              'noText',
              '此页未检测到可提取文字；可能为空白或扫描件，尚未 OCR。',
              page: index + 1,
            ),
          );
        }
        processed++;
      } on _PageProblem catch (error) {
        unprocessed.add(location);
        problems.add(
          DocumentProblem(error.code, error.message, page: index + 1),
        );
      } finally {
        if (text != nullptr) GuardedPdfium.FPDFText_ClosePage(text);
        if (page != nullptr) GuardedPdfium.FPDF_ClosePage(page);
      }
    }
    output.send(
      DocumentExtraction(
        engine: _engine,
        completion: body.isEmpty && tables.isEmpty
            ? problems.every(
                    (p) => p.code == 'noText' || p.code == 'imageRegion',
                  )
                  ? DocumentCompletion.noExtractableText
                  : DocumentCompletion.failed
            : problems.isEmpty
            ? DocumentCompletion.complete
            : DocumentCompletion.partial,
        body: body,
        tables: tables,
        unprocessed: {for (final region in unprocessed) region.page: region}
            .values
            .toList(),
        problems: problems,
        totalPages: total,
        processedPages: processed,
      ),
    );
  } on FileSystemException {
    output.send(
      const DocumentExtraction(
        engine: _engine,
        completion: DocumentCompletion.failed,
        problems: [
          DocumentProblem(
            'fileUnreadable',
            '当前来源文件无法读取，可能已缺失或不可访问；请恢复文件或访问权限后重试。',
          ),
        ],
      ),
    );
  } catch (_) {
    output.send(
      const DocumentExtraction(
        engine: _engine,
        completion: DocumentCompletion.failed,
        problems: [
          DocumentProblem('engineFailed', '本机 PDF 处理失败，原件已保留；可重试或查看原件。'),
        ],
      ),
    );
  } finally {
    if (document != nullptr) GuardedPdfium.FPDF_CloseDocument(document);
    if (initialized) GuardedPdfium.FPDF_DestroyLibrary();
    cancellation.close();
  }
}

class _PageProblem implements Exception {
  const _PageProblem(this.code, this.message);
  final String code;
  final String message;
}
