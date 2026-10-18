import 'dart:ffi';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:pdfium_flutter/pdfium_flutter.dart';

import 'document_extraction.dart';
import 'pdf_native.dart';

class PdfGlyph {
  const PdfGlyph(this.text, this.box, {this.baseline});
  final String text;
  final List<double>? box;

  /// Text origin Y, independent of a character's painted shape/descent.
  final double? baseline;
  bool get visible => text.trim().isNotEmpty;
}

/// Only complete axis-aligned ruling grids establish tables. Columns of prose,
/// missing rules/merged cells and rotated content remain text with a warning.
/// This deliberately bounded recognizer never guesses cells from whitespace.
({
  List<DocumentBody> body,
  List<DocumentTable> tables,
  List<DocumentProblem> problems,
  bool hasImages,
})
readPdfLayout(
  FPDF_PAGE page,
  List<PdfGlyph> glyphs,
  DocumentLocation location,
  int maximumCells,
) {
  final horizontal = <_Rule>[];
  final vertical = <_Rule>[];
  final problems = <DocumentProblem>[];
  var hasImages = false;
  var unsupported = false;
  var layoutLimited = false;
  final objects = GuardedPdfium.FPDFPage_CountObjects(page);
  if (objects < 0 || objects > 10000) {
    problems.add(
      DocumentProblem(
        'layoutLimit',
        '页面对象超过版面分析上限；保留文字，表格和图片区域尚未核实。',
        page: location.page,
      ),
    );
  } else {
    using((arena) {
      final x = arena<Float>();
      final y = arena<Float>();
      final matrix = arena<FS_MATRIX>();
      final fill = arena<Int>();
      final stroke = arena<FPDF_BOOL>();
      var segmentsRead = 0;
      for (var i = 0; i < objects; i++) {
        final object = GuardedPdfium.FPDFPage_GetObject(page, i);
        if (object == nullptr) {
          unsupported = true;
          continue;
        }
        final type = GuardedPdfium.FPDFPageObj_GetType(object);
        if (type == FPDF_PAGEOBJ_IMAGE || type == FPDF_PAGEOBJ_FORM) {
          hasImages = true;
        }
        if (type != FPDF_PAGEOBJ_PATH) continue;
        final count = GuardedPdfium.FPDFPath_CountSegments(object);
        segmentsRead += count;
        if (count < 0 || count > 1000 || segmentsRead > 50000) {
          layoutLimited = true;
          break;
        }
        if (GuardedPdfium.FPDFPath_GetDrawMode(object, fill, stroke) == 0 ||
            stroke.value == 0 ||
            GuardedPdfium.FPDFPageObj_GetMatrix(object, matrix) == 0) {
          continue;
        }
        (double, double)? previous;
        for (var j = 0; j < count; j++) {
          final segment = GuardedPdfium.FPDFPath_GetPathSegment(object, j);
          if (segment == nullptr ||
              GuardedPdfium.FPDFPathSegment_GetPoint(segment, x, y) == 0) {
            previous = null;
            continue;
          }
          final m = matrix.ref;
          final point = (
            m.a * x.value + m.c * y.value + m.e,
            m.b * x.value + m.d * y.value + m.f,
          );
          final type = GuardedPdfium.FPDFPathSegment_GetType(segment);
          if (type == FPDF_SEGMENT_LINETO && previous != null) {
            final (px, py) = previous;
            if ((point.$2 - py).abs() < .5 && (point.$1 - px).abs() > 8) {
              horizontal.add(
                _Rule(point.$2, math.min(point.$1, px), math.max(point.$1, px)),
              );
            }
            if ((point.$1 - px).abs() < .5 && (point.$2 - py).abs() > 8) {
              vertical.add(
                _Rule(point.$1, math.min(point.$2, py), math.max(point.$2, py)),
              );
            }
            if (horizontal.length + vertical.length > 1024) {
              layoutLimited = true;
              break;
            }
          }
          previous = type == FPDF_SEGMENT_BEZIERTO ? null : point;
        }
        if (layoutLimited) break;
      }
    });
  }
  if (layoutLimited) {
    horizontal.clear();
    vertical.clear();
    problems.add(
      DocumentProblem(
        'layoutLimit',
        '页面线段超过版面分析上限；保留文字，表格区域尚未核实。',
        page: location.page,
      ),
    );
  }
  final grids = <_Grid>[];
  final used = <_Rule>{};
  for (final rule in horizontal) {
    if (used.contains(rule)) continue;
    final matching = horizontal
        .where(
          (h) =>
              (h.start - rule.start).abs() < 1 && (h.end - rule.end).abs() < 1,
        )
        .toList();
    used.addAll(matching);
    final ys = _coordinates(matching.map((h) => h.axis));
    if (ys.length < 3) continue;
    final xs = _coordinates(
      vertical
          .where(
            (v) =>
                (v.start - ys.first).abs() < 1 &&
                (v.end - ys.last).abs() < 1 &&
                v.axis >= rule.start - 1 &&
                v.axis <= rule.end + 1,
          )
          .map((v) => v.axis),
    );
    if (xs.length < 3 ||
        (xs.first - rule.start).abs() > 1 ||
        (xs.last - rule.end).abs() > 1) {
      unsupported = true;
      continue;
    }
    if ((xs.length - 1) * (ys.length - 1) > maximumCells ||
        grids.length >= 32) {
      unsupported = true;
      continue;
    }
    final grid = _Grid(xs, ys);
    if (grids.any((g) => g.overlaps(grid))) {
      unsupported = true;
      continue;
    }
    grids.add(grid);
  }
  if (location.rotation != 0 && grids.isNotEmpty) {
    grids.clear();
    unsupported = true;
  }
  if (horizontal.length >= 2 && vertical.length >= 2 && grids.isEmpty) {
    unsupported = true;
  }
  final tables = <DocumentTable>[];
  final consumed = <int>{};
  var cells = 0;
  for (final grid in grids) {
    final cellCount = (grid.xs.length - 1) * (grid.ys.length - 1);
    if (cells + cellCount > maximumCells) {
      unsupported = true;
      continue;
    }
    final assignments = <(int, int), List<PdfGlyph>>{};
    final indices = <int>[];
    var ambiguous = false;
    for (var index = 0; index < glyphs.length; index++) {
      final glyph = glyphs[index];
      final box = glyph.box;
      if (box == null || glyph.text == '\r' || glyph.text == '\n') continue;
      final x = (box[0] + box[2]) / 2;
      final y = (box[1] + box[3]) / 2;
      if (x <= grid.xs.first ||
          x >= grid.xs.last ||
          y <= grid.ys.first ||
          y >= grid.ys.last) {
        continue;
      }
      final column = _interval(grid.xs, x);
      final row = _interval(grid.ys, y);
      if (box[0] < grid.xs[column] - 1 ||
          box[2] > grid.xs[column + 1] + 1 ||
          box[1] < grid.ys[row] - 1 ||
          box[3] > grid.ys[row + 1] + 1) {
        if (glyph.visible) {
          ambiguous = true;
          break;
        }
        continue;
      }
      if (glyph.baseline == null) {
        ambiguous = true;
        break;
      }
      assignments.putIfAbsent((row, column), () => []).add(glyph);
      indices.add(index);
    }
    if (ambiguous || assignments.isEmpty) {
      unsupported = true;
      continue;
    }
    DocumentLocation at(List<double> box) => DocumentLocation(
      coordinateSpace: location.coordinateSpace,
      sourceId: location.sourceId,
      page: location.page,
      bounds: box,
      rotation: location.rotation,
    );
    final rows = <List<DocumentCell>>[];
    for (var row = grid.ys.length - 2; row >= 0; row--) {
      rows.add([
        for (var col = 0; col < grid.xs.length - 1; col++)
          DocumentCell(
            _cellText(assignments[(row, col)] ?? []),
            at([
              grid.xs[col],
              grid.ys[row],
              grid.xs[col + 1],
              grid.ys[row + 1],
            ]),
          ),
      ]);
    }
    tables.add(
      DocumentTable(
        rows,
        at([grid.xs.first, grid.ys.first, grid.xs.last, grid.ys.last]),
      ),
    );
    consumed.addAll(indices);
    cells += cellCount;
  }
  if (unsupported) {
    problems.add(
      DocumentProblem(
        'unsupportedLayout',
        '部分表格或版面无法可靠还原；相关内容保留为文字，请核对原件。',
        page: location.page,
      ),
    );
  }
  final body = <DocumentBody>[];
  var buffer = StringBuffer();
  List<double>? bounds;
  void flush() {
    final text = buffer
        .toString()
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();
    if (text.isNotEmpty) {
      body.add(
        DocumentBody(
          text,
          DocumentLocation(
            coordinateSpace: location.coordinateSpace,
            sourceId: location.sourceId,
            page: location.page,
            bounds: bounds,
            rotation: location.rotation,
          ),
        ),
      );
    }
    buffer = StringBuffer();
    bounds = null;
  }

  for (var index = 0; index < glyphs.length; index++) {
    final glyph = glyphs[index];
    if (consumed.contains(index)) {
      flush();
      continue;
    }
    buffer.write(glyph.text);
    final box = glyph.box;
    if (glyph.visible && box != null) {
      bounds = bounds == null
          ? List.of(box)
          : [
              math.min(bounds![0], box[0]),
              math.min(bounds![1], box[1]),
              math.max(bounds![2], box[2]),
              math.max(bounds![3], box[3]),
            ];
    }
  }
  flush();
  return (body: body, tables: tables, problems: problems, hasImages: hasImages);
}

List<double> _coordinates(Iterable<double> coordinates) {
  final sorted = coordinates.toList()..sort();
  final values = <double>[];
  for (final value in sorted) {
    if (values.isEmpty || value - values.last > 1) values.add(value);
  }
  return values;
}

int _interval(List<double> values, double point) {
  var low = 0;
  var high = values.length - 1;
  while (high - low > 1) {
    final middle = (high + low) ~/ 2;
    if (values[middle] <= point) {
      low = middle;
    } else {
      high = middle;
    }
  }
  return low;
}

String _cellText(List<PdfGlyph> glyphs) {
  final lines = <List<PdfGlyph>>[];
  for (final glyph in glyphs) {
    final line = lines
        .where((line) => (line.first.baseline! - glyph.baseline!).abs() < 3)
        .firstOrNull;
    if (line == null) {
      lines.add([glyph]);
    } else {
      line.add(glyph);
    }
  }
  lines.sort((a, b) => b.first.baseline!.compareTo(a.first.baseline!));
  return lines
      .map((line) {
        line.sort((a, b) => a.box![0].compareTo(b.box![0]));
        return line.map((g) => g.text).join().trim();
      })
      .join('\n');
}

class _Rule {
  const _Rule(this.axis, this.start, this.end);
  final double axis, start, end;
}

class _Grid {
  const _Grid(this.xs, this.ys);
  final List<double> xs, ys;
  bool overlaps(_Grid other) =>
      xs.first < other.xs.last &&
      xs.last > other.xs.first &&
      ys.first < other.ys.last &&
      ys.last > other.ys.first;
}
