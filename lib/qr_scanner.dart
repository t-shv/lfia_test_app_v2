import 'package:mobile_scanner/mobile_scanner.dart';

/// Scans the image at [path] and returns the first QR’s rawValue, or null.
Future<String?> scanQRCode(String path) async {
  final controller = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
  );
  final capture = await controller.analyzeImage(path);
  await controller.dispose();
  // Return the first QR code's rawValue, or null if not found
  return capture?.barcodes.isNotEmpty == true ? capture!.barcodes.first.rawValue : null;
}
