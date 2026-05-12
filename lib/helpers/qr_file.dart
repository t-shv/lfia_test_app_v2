// lib/helpers/qr_file.dart
import 'dart:io';
import 'dart:ui' show Offset;                                   // <-- add
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart'
    as mlkit;
import 'package:mobile_scanner/mobile_scanner.dart'
    show Barcode, BarcodeFormat;

/// Scan a JPEG/PNG on disk and return the first QR `Barcode` (or `null`)
Future<Barcode?> detectQrOnFile(String path) async {
  // ❶ use mlkit’s own enum, NOT `.index`
  final scanner = mlkit.BarcodeScanner(
    formats: [mlkit.BarcodeFormat.qrCode],
  );

  final input = mlkit.InputImage.fromFilePath(path);
  final list  = await scanner.processImage(input);
  await scanner.close();

  if (list.isEmpty) return null;

  final ml = list.first; // ml is a mlkit.Barcode

  return Barcode(
  rawValue: ml.rawValue,
  corners: ml.cornerPoints == null
      ? <Offset>[]
      : ml.cornerPoints!
          .map((p) => Offset(p.x.toDouble(), p.y.toDouble()))
          .toList(),
  format:  BarcodeFormat.qrCode,
);
}
