import 'dart:ffi' as ffi;

import 'package:pdfium_flutter/pdfium_flutter.dart';

// Resolve the bundled native asset through Dart, including Flutter tests.
// The package loader searches an obsolete native_assets.yaml in host tests.
class GuardedPdfium {
  @ffi.Native<ffi.Void Function()>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDF_InitLibrary',
  )
  external static void FPDF_InitLibrary();

  @ffi.Native<ffi.Void Function()>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDF_DestroyLibrary',
  )
  external static void FPDF_DestroyLibrary();

  @ffi.Native<FPDF_DOCUMENT Function(FPDF_STRING, FPDF_BYTESTRING)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDF_LoadDocument',
  )
  external static FPDF_DOCUMENT FPDF_LoadDocument(
    FPDF_STRING file_path,
    FPDF_BYTESTRING password,
  );

  @ffi.Native<ffi.UnsignedLong Function()>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDF_GetLastError',
  )
  external static int FPDF_GetLastError();

  @ffi.Native<ffi.Int Function(FPDF_DOCUMENT)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDF_GetPageCount',
  )
  external static int FPDF_GetPageCount(FPDF_DOCUMENT document);

  @ffi.Native<ffi.Void Function(FPDF_DOCUMENT)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDF_CloseDocument',
  )
  external static void FPDF_CloseDocument(FPDF_DOCUMENT document);

  @ffi.Native<FPDF_PAGE Function(FPDF_DOCUMENT, ffi.Int)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDF_LoadPage',
  )
  external static FPDF_PAGE FPDF_LoadPage(
    FPDF_DOCUMENT document,
    int page_index,
  );

  @ffi.Native<ffi.Void Function(FPDF_PAGE)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDF_ClosePage',
  )
  external static void FPDF_ClosePage(FPDF_PAGE page);

  @ffi.Native<FPDF_TEXTPAGE Function(FPDF_PAGE)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFText_LoadPage',
  )
  external static FPDF_TEXTPAGE FPDFText_LoadPage(FPDF_PAGE page);

  @ffi.Native<ffi.Void Function(FPDF_TEXTPAGE)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFText_ClosePage',
  )
  external static void FPDFText_ClosePage(FPDF_TEXTPAGE text_page);

  @ffi.Native<ffi.Int Function(FPDF_TEXTPAGE)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFText_CountChars',
  )
  external static int FPDFText_CountChars(FPDF_TEXTPAGE text_page);

  @ffi.Native<ffi.UnsignedInt Function(FPDF_TEXTPAGE, ffi.Int)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFText_GetUnicode',
  )
  external static int FPDFText_GetUnicode(FPDF_TEXTPAGE text_page, int index);

  @ffi.Native<
    FPDF_BOOL Function(
      FPDF_TEXTPAGE,
      ffi.Int,
      ffi.Pointer<ffi.Double>,
      ffi.Pointer<ffi.Double>,
      ffi.Pointer<ffi.Double>,
      ffi.Pointer<ffi.Double>,
    )
  >(assetId: 'package:pdfium_dart/libpdfium', symbol: 'FPDFText_GetCharBox')
  external static int FPDFText_GetCharBox(
    FPDF_TEXTPAGE text_page,
    int index,
    ffi.Pointer<ffi.Double> left,
    ffi.Pointer<ffi.Double> right,
    ffi.Pointer<ffi.Double> bottom,
    ffi.Pointer<ffi.Double> top,
  );

  @ffi.Native<ffi.Int Function(FPDF_PAGE)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFPage_GetRotation',
  )
  external static int FPDFPage_GetRotation(FPDF_PAGE page);

  @ffi.Native<ffi.Int Function(FPDF_PAGE)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFPage_CountObjects',
  )
  external static int FPDFPage_CountObjects(FPDF_PAGE page);

  @ffi.Native<FPDF_PAGEOBJECT Function(FPDF_PAGE, ffi.Int)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFPage_GetObject',
  )
  external static FPDF_PAGEOBJECT FPDFPage_GetObject(FPDF_PAGE page, int index);

  @ffi.Native<ffi.Int Function(FPDF_PAGEOBJECT)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFPageObj_GetType',
  )
  external static int FPDFPageObj_GetType(FPDF_PAGEOBJECT page_object);

  @ffi.Native<FPDF_BOOL Function(FPDF_PAGEOBJECT, ffi.Pointer<FS_MATRIX>)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFPageObj_GetMatrix',
  )
  external static int FPDFPageObj_GetMatrix(
    FPDF_PAGEOBJECT page_object,
    ffi.Pointer<FS_MATRIX> matrix,
  );

  @ffi.Native<ffi.Int Function(FPDF_PAGEOBJECT)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFPath_CountSegments',
  )
  external static int FPDFPath_CountSegments(FPDF_PAGEOBJECT path);

  @ffi.Native<FPDF_PATHSEGMENT Function(FPDF_PAGEOBJECT, ffi.Int)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFPath_GetPathSegment',
  )
  external static FPDF_PATHSEGMENT FPDFPath_GetPathSegment(
    FPDF_PAGEOBJECT path,
    int index,
  );

  @ffi.Native<
    FPDF_BOOL Function(
      FPDF_PATHSEGMENT,
      ffi.Pointer<ffi.Float>,
      ffi.Pointer<ffi.Float>,
    )
  >(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFPathSegment_GetPoint',
  )
  external static int FPDFPathSegment_GetPoint(
    FPDF_PATHSEGMENT segment,
    ffi.Pointer<ffi.Float> x,
    ffi.Pointer<ffi.Float> y,
  );

  @ffi.Native<ffi.Int Function(FPDF_PATHSEGMENT)>(
    assetId: 'package:pdfium_dart/libpdfium',
    symbol: 'FPDFPathSegment_GetType',
  )
  external static int FPDFPathSegment_GetType(FPDF_PATHSEGMENT segment);

  @ffi.Native<
    FPDF_BOOL Function(
      FPDF_PAGEOBJECT,
      ffi.Pointer<ffi.Int>,
      ffi.Pointer<FPDF_BOOL>,
    )
  >(assetId: 'package:pdfium_dart/libpdfium', symbol: 'FPDFPath_GetDrawMode')
  external static int FPDFPath_GetDrawMode(
    FPDF_PAGEOBJECT path,
    ffi.Pointer<ffi.Int> fillmode,
    ffi.Pointer<FPDF_BOOL> stroke,
  );
}
