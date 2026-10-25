import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/document_extraction.dart';

void main() {
  test('unpaginated source blocks preserve mixed body/table order and locators through JSON', () {
    final result = DocumentExtraction.fromJson(
      jsonDecode('''{
      "completion":"complete", "engine":"unpaginated-test", "totalPages":0, "processedPages":0,
      "body":[
        {"text":"结尾", "order":2, "location":{"sourceId":"source", "part":"word/document.xml", "blockIndex":2}},
        {"text":"引言", "order":0, "location":{"sourceId":"source", "part":"word/document.xml", "blockIndex":0}}
      ],
      "tables":[{"order":1, "location":{"sourceId":"source", "part":"word/document.xml", "blockIndex":1}, "rows":[
        [{"text":"项目", "location":{"sourceId":"source", "part":"word/document.xml", "blockIndex":1}}],
        [{"text":"原文", "location":{"sourceId":"source", "part":"word/document.xml", "blockIndex":1}}]
      ]}],
      "unprocessed":[], "problems":[]
    }''') as Map<String, dynamic>,
    );
    final restored = DocumentExtraction.fromJson(
      jsonDecode(jsonEncode(result.toJson())) as Map<String, dynamic>,
    );
    expect(restored.markdown, '引言\n\n| 项目 |\n| --- |\n| 原文 |\n\n结尾');
    expect(restored.body.first.location.page, isNull);
    expect(restored.body.first.location.toJson()['coordinates'], isNull);
    expect(
      restored.tables.single.location.toJson()['part'],
      'word/document.xml',
    );
    expect(restored.tables.single.location.toJson()['blockIndex'], 1);
    expect(restored.tables.single.toJson()['order'], 1);
    expect(restored.summary, isNot(contains('0/0')));
  });

  test(
    'legacy PDF JSON retains page coordinates and body/table reading order',
    () {
      final result = DocumentExtraction.fromJson(
        jsonDecode('''{
      "completion":"complete", "engine":"pdfium/7811 guarded-text-v1", "totalPages":1, "processedPages":1,
      "body":[
        {"text":"结尾", "location":{"sourceId":"source", "page":1, "bounds":[40,500,200,520], "rotation":0, "coordinates":"pdf-points-bottom-left"}},
        {"text":"引言", "location":{"sourceId":"source", "page":1, "bounds":[40,710,200,730], "rotation":0, "coordinates":"pdf-points-bottom-left"}}
      ],
      "tables":[{"location":{"sourceId":"source", "page":1, "bounds":[40,560,400,680], "rotation":0, "coordinates":"pdf-points-bottom-left"}, "rows":[
        [{"text":"项目", "location":{"sourceId":"source", "page":1, "coordinates":"pdf-points-bottom-left"}}],
        [{"text":"原文", "location":{"sourceId":"source", "page":1, "coordinates":"pdf-points-bottom-left"}}]
      ]}],
      "unprocessed":[], "problems":[]
    }''') as Map<String, dynamic>,
      );
      final restored = DocumentExtraction.fromJson(
        jsonDecode(jsonEncode(result.toJson())) as Map<String, dynamic>,
      );
      expect(restored.markdown, '引言\n\n| 项目 |\n| --- |\n| 原文 |\n\n结尾');
      expect(restored.tables.single.location.page, 1);
      expect(
        restored.tables.single.location.toJson()['coordinates'],
        'pdf-points-bottom-left',
      );
      expect(restored.tables.single.location.bounds, [40, 560, 400, 680]);
      expect(restored.summary, '已提取文字及可识别的规则表格（1/1 页）；图片未做 OCR。');
    },
  );
}
