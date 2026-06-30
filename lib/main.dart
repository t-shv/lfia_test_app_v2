import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;

import 'helpers/qr_file.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:gal/gal.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart'
    show SystemChrome, SystemUiOverlayStyle, MethodChannel; //new methodChannel import for opencv connection


import 'live_guide_camera.dart';
import 'learn_more_screen.dart';

/// Valid QR codes issued by the test-strip producer
const validTestStripQRCodes = <String>{
  'TS-0001',
  'COV-19-TS-0000020-1219',
  'COV-19-TS-0000020-0915',
  'COV-19-TS-0000109-1219',
};

// Method channel for opencv connection
const MethodChannel _opencvChannel = MethodChannel('lfia/opencv');

Future<Map<String, dynamic>> _checkImageQualityWithOpenCV(String imagePath) async {
  final result = await _opencvChannel.invokeMethod<Map<dynamic, dynamic>>(
    'checkImageQuality',
    {'imagePath': imagePath},
  );

  return Map<String, dynamic>.from(result ?? {});
}


/// Preprocess image to match CNN input requirements
Future<Float32List> _preprocessImage(String path) async {
  final bytes = await File(path).readAsBytes();
  final image = img.decodeImage(bytes);

  if (image == null) {
    throw StateError('Could not decode image for CNN: $path');
  }

  const int size = 256;
  final grayscale = img.grayscale(image);
  final resized = img.copyResize(grayscale, width: size, height: size);

  final out = Float32List(size * size);
  var idx = 0;

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      out[idx++] = img.getRed(resized.getPixel(x, y)) / 255.0;
    }
  }

  return out;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFFFCFCFE),
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  await Firebase.initializeApp();
  await FirebaseAuth.instance.signInAnonymously();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoApp(
      debugShowCheckedModeBanner: false,
      theme: CupertinoThemeData(
        brightness: Brightness.light,
        primaryColor: CupertinoColors.activeGreen,
        barBackgroundColor: Color(0xFFF8F9FB),
        scaffoldBackgroundColor: Color(0xFFFCFCFE),
        textTheme: CupertinoTextThemeData(
          textStyle: TextStyle(fontSize: 16),
          navTitleTextStyle: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: CupertinoColors.label,
          ),
        ),
      ),
      home: CameraScreen(),
    );
  }
}

/// ───────────────────────── CameraScreen ─────────────────────────
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  static const double _optimalThreshold = 0.5955;

  Future<void> _processCapture(String imagePath, LockedQr previewQr) async {
    try {
      debugPrint('====== _processCapture START ======');
      debugPrint('imagePath: $imagePath');
      debugPrint(
        'preview capture size: '
        '${previewQr.captureSize.width} x ${previewQr.captureSize.height}',
      );

      /* -------- 0. Location -------- */
      final location = await _getLocationIfAvailable();
      final latitude = location?.latitude;
      final longitude = location?.longitude;

      if (!mounted) return;

      /* -------- 1. Decode and orient the still photo -------- */
      final originalFile = File(imagePath);

      if (!await originalFile.exists()) {
        throw StateError('Captured file does not exist: $imagePath');
      }

      final originalBytes = await originalFile.readAsBytes();

      if (originalBytes.isEmpty) {
        throw StateError('Captured file is empty: $imagePath');
      }

      final decoded = img.decodeImage(originalBytes);

      if (decoded == null) {
        throw StateError('Could not decode captured image.');
      }

      final origImage = img.bakeOrientation(decoded);
      
      //// fixed orientation logic 
img.Image fixedImage = origImage;

if (fixedImage.width > fixedImage.height) {
  fixedImage = img.copyRotate(fixedImage, 90);
}
      // new line ends

      debugPrint(
        'oriented image size: ${origImage.width} x ${origImage.height}',
      );

      final tmpDir = await getTemporaryDirectory();
      final orientedPath =
          '${tmpDir.path}/oriented_${DateTime.now().millisecondsSinceEpoch}.jpg';

// fixed orientation
      await File(orientedPath).writeAsBytes(
        img.encodeJpg(fixedImage, quality: 95),
      );

      /* -------- 2. Re-detect QR on oriented still photo -------- */
      final Barcode? highResQr = await detectQrOnFile(orientedPath);

      final String code =
          (highResQr?.rawValue ?? previewQr.barcode.rawValue ?? '').trim();

      if (!validTestStripQRCodes.contains(code)) {
        await showCupertinoDialog(
          context: context,
          builder: (_) => CupertinoAlertDialog(
            title: const Text('Unrecognized Strip'),
            content: Text('QR code "$code" is not on the approved list.'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        );
        return;
      }

      /* -------- 3. Quick feedback -------- */
      await showCupertinoDialog(
        context: context,
        builder: (_) => CupertinoAlertDialog(
          title: const Text('Valid Strip Detected'),
          content: Text(code),
          actions: [
            CupertinoDialogAction(
              child: const Text('Continue'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      );

      if (!mounted) return;

      /* -------- 4. Choose QR points -------- */
      // fixed orientation to portrait
      final imageSize = Size(
        fixedImage.width.toDouble(),
        fixedImage.height.toDouble(),
      );

      late final List<Offset> qrPoints;
      late final String qrSource;

     if (highResQr != null && highResQr.corners.length >= 4) {
  qrPoints = _pointsFromBarcode(highResQr);
  qrSource = 'high-res still photo';
} else {
  debugPrint('WARNING: highResQr failed. Using safe center crop instead.');

  final safeCrop = _centerCropBox(origImage);

  final cropped = img.copyCrop(
    fixedImage, // fixed orientation
    safeCrop.x,
    safeCrop.y,
    safeCrop.width,
    safeCrop.height,
  );

  final tmpDir = await getTemporaryDirectory();
  final autoPath =
      '${tmpDir.path}/safe_center_crop_${DateTime.now().millisecondsSinceEpoch}.jpg';

  await File(autoPath).writeAsBytes(
    img.encodeJpg(cropped, quality: 95),
  );

  final userCrop = await ImageCropper().cropImage(
    sourcePath: autoPath,
    uiSettings: [
      AndroidUiSettings(
        toolbarTitle: 'Adjust Crop',
        toolbarColor: CupertinoColors.activeBlue,
        activeControlsWidgetColor: CupertinoColors.white,
        lockAspectRatio: false,
        showCropGrid: true,
      ),
      IOSUiSettings(
        title: 'Adjust Crop',
        aspectRatioLockEnabled: false,
      ),
    ],
  );

  final finalPath = userCrop?.path ?? autoPath;


//opencv call starts/////////////////////////////////

final quality = await _checkImageQualityWithOpenCV(finalPath);

debugPrint('OpenCV quality result: $quality');

final usable = quality['usable'] == true;
final contrastExposure = quality['contrastExposure']?.toString() ?? 'Unknown';
final blurriness = quality['blurriness']?.toString() ?? 'Unknown';

if (!usable && mounted) {
  final continueAnyway = await showCupertinoDialog<bool>(
    context: context,
    builder: (_) => CupertinoAlertDialog(
      title: const Text('Image Quality Warning'),
      content: Text(
        'Contrast/Exposure: $contrastExposure\n'
        'Blurriness: $blurriness\n\n'
        'Retaking the photo is recommended.',
      ),
      actions: [
        CupertinoDialogAction(
          isDestructiveAction: true,
          child: const Text('Retake'),
          onPressed: () => Navigator.pop(context, false),
        ),
        CupertinoDialogAction(
          child: const Text('Continue Anyway'),
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    ),
  );

  if (continueAnyway != true) {
    return;
  }
}
// opencv call ends///////////////////////////////

  

  // continue directly to CNN from here
  Interpreter? interpreter;

  try {
    interpreter = await Interpreter.fromAsset(
      'assets/new_large_model.tflite',
    );

    final inputData = await _preprocessImage(finalPath);
    final inputTensor = inputData.reshape([1, 256, 256, 1]);
    final outputTensor = Float32List(1).reshape([1, 1]);

    interpreter.run(inputTensor, outputTensor);

    final prob = outputTensor[0][0];
    final label = prob >= _optimalThreshold ? 'Positive' : 'Negative';
    final conf = (prob * 100).toStringAsFixed(1);

    if (!mounted) return;

    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => AnalysisResultFullScreen(
          imagePath: finalPath,
          result: label,
          confidence: conf,
          latitude: latitude,
          longitude: longitude,
        ),
      ),
    );
  } finally {
    interpreter?.close();
  }

  return;
}


      _validateQrPoints(
        pts: qrPoints,
        imageSize: imageSize,
        source: qrSource,
      );

      /* -------- 5. Auto-crop using your existing crop math -------- */
      final cropBox = _calculateCropUsingYourExistingMath(
        pts: qrPoints,
        image: fixedImage,
      );

      debugPrint('QR source: $qrSource');
      debugPrint('QR points: ${_formatPoints(qrPoints)}');
      debugPrint('cropBox: $cropBox');

      final cropped = img.copyCrop(
        fixedImage,
        cropBox.x,
        cropBox.y,
        cropBox.width,
        cropBox.height,
      );
      

      final autoPath =
          '${tmpDir.path}/crop_${DateTime.now().millisecondsSinceEpoch}.jpg';

      await File(autoPath).writeAsBytes(
        img.encodeJpg(cropped, quality: 95),
      );

      /* -------- 6. Let user tweak crop -------- */
      final userCrop = await ImageCropper().cropImage(
        sourcePath: autoPath,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Adjust Crop',
            toolbarColor: CupertinoColors.activeBlue,
            activeControlsWidgetColor: CupertinoColors.white,
            lockAspectRatio: false,
            showCropGrid: true,
          ),
          IOSUiSettings(
            title: 'Adjust Crop',
            aspectRatioLockEnabled: false,
          ),
        ],
      );

      final finalPath = userCrop?.path ?? autoPath;

//openCV call
  final quality = await _checkImageQualityWithOpenCV(finalPath);

debugPrint('OpenCV quality result: $quality');

final usable = quality['usable'] == true;
final contrastExposure = quality['contrastExposure']?.toString() ?? 'Unknown';
final blurriness = quality['blurriness']?.toString() ?? 'Unknown';

if (!usable && mounted) {
  final continueAnyway = await showCupertinoDialog<bool>(
    context: context,
    builder: (_) => CupertinoAlertDialog(
      title: const Text('Image Quality Warning'),
      content: Text(
        'Contrast/Exposure: $contrastExposure\n'
        'Blurriness: $blurriness\n\n'
        'Retaking the photo is recommended.',
      ),
      actions: [
        CupertinoDialogAction(
          isDestructiveAction: true,
          child: const Text('Retake'),
          onPressed: () => Navigator.pop(context, false),
        ),
        CupertinoDialogAction(
          child: const Text('Continue Anyway'),
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    ),
  );

  if (continueAnyway != true) {
    return;
  }
}

// opencv  call ends <--
      /* -------- 7. Run CNN -------- */
      Interpreter? interpreter;

      try {
        interpreter = await Interpreter.fromAsset(
          'assets/new_large_model.tflite',
        );

        final inputData = await _preprocessImage(finalPath);
        final inputTensor = inputData.reshape([1, 256, 256, 1]);
        final outputTensor = Float32List(1).reshape([1, 1]);

        interpreter.run(inputTensor, outputTensor);

        final prob = outputTensor[0][0];
        final label = prob >= _optimalThreshold ? 'Positive' : 'Negative';
        final conf = (prob * 100).toStringAsFixed(1);

        /* -------- 8. Show result -------- */
        if (!mounted) return;

        Navigator.of(context).push(
          CupertinoPageRoute(
            builder: (_) => AnalysisResultFullScreen(
              imagePath: finalPath,
              result: label,
              confidence: conf,
              latitude: latitude,
              longitude: longitude,
            ),
          ),
        );
      } finally {
        interpreter?.close();
      }
    } catch (e, st) {
      debugPrint('====== _processCapture FAILED ======');
      debugPrint('$e');
      debugPrint('$st');

      if (!mounted) return;

      await showCupertinoDialog<void>(
        context: context,
        builder: (_) => CupertinoAlertDialog(
          title: const Text('Image processing failed'),
          content: Text('$e'),
          actions: [
            CupertinoDialogAction(
              child: const Text('OK'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      );
    }
  }

  Future<_LatLng?> _getLocationIfAvailable() async {
    try {
      var perm = await Geolocator.checkPermission();

      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }

      if (perm == LocationPermission.whileInUse ||
          perm == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );

        return _LatLng(
          latitude: pos.latitude,
          longitude: pos.longitude,
        );
      }
    } catch (e) {
      debugPrint('Location unavailable: $e');
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: LiveGuideCamera(onShutter: _processCapture),
            ),
            Positioned(
              bottom: 16,
              right: 16,
              child: CupertinoButton(
                padding: const EdgeInsets.all(8),
                borderRadius: BorderRadius.circular(24),
                color: CupertinoColors.white,
                child: const Icon(CupertinoIcons.folder, size: 28),
                onPressed: () {
                  Navigator.of(context).push(
                    CupertinoPageRoute(
                      builder: (_) => const SavedTestsScreen(),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ────────── QR/crop helpers ────────── */

class _LatLng {
  const _LatLng({
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;
}

class _CropBox {
  const _CropBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  @override
  String toString() {
    return 'x=$x, y=$y, width=$width, height=$height';
  }
}

List<Offset> _pointsFromBarcode(Barcode barcode) {
  if (barcode.corners.length < 4) {
    throw StateError(
      'Barcode has ${barcode.corners.length} corners instead of 4.',
    );
  }

  return barcode.corners
      .map((p) => Offset(p.dx.toDouble(), p.dy.toDouble()))
      .toList();
}

List<Offset> _scalePreviewQrToImage({
  required LockedQr previewQr,
  required Size imageSize,
}) {
  final captureSize = previewQr.captureSize;

  if (captureSize.width <= 0 || captureSize.height <= 0) {
    throw StateError(
      'Cannot use preview fallback because BarcodeCapture.size is invalid: '
      '$captureSize',
    );
  }

  final corners = previewQr.barcode.corners;

  if (corners.length < 4) {
    throw StateError(
      'Cannot use preview fallback because preview QR has '
      '${corners.length} corners instead of 4.',
    );
  }

  final scaleX = imageSize.width / captureSize.width;
  final scaleY = imageSize.height / captureSize.height;

  debugPrint('fallback scaleX=$scaleX scaleY=$scaleY');

  return corners
      .map((p) => Offset(p.dx * scaleX, p.dy * scaleY))
      .toList();
}

_CropBox _centerCropBox(img.Image image) {
  final cropW = (image.width * 0.7).round();
  final cropH = (image.height * 0.7).round();

  final cropX = ((image.width - cropW) / 2).round();
  final cropY = ((image.height - cropH) / 2).round();

  return _CropBox(
    x: cropX,
    y: cropY,
    width: cropW,
    height: cropH,
  );
}


_CropBox _calculateCropUsingYourExistingMath({
  required List<Offset> pts,
  required img.Image image,
}) {
  final xs = pts.map((p) => p.dx).toList();
  final ys = pts.map((p) => p.dy).toList();

  final minX = xs.reduce(math.min);
  final maxX = xs.reduce(math.max);
  final minY = ys.reduce(math.min);
  final maxY = ys.reduce(math.max);

  final w = maxX - minX;
  final h = maxY - minY;

  if (w <= 0 || h <= 0) {
    throw StateError(
      'Invalid QR box: width=$w height=$h points=${_formatPoints(pts)}',
    );
  }

  // Keeping your original crop logic exactly.
  const double topF = -1.3;
  const double bottomF = 2.5;
  const double horizF = 0.1;

  final extTop = (h * topF).round();
  final extBottom = (h * bottomF).round();
  final extX = (w * horizF).round();

  final cropX = (minX.round() - extX).clamp(0, image.width).toInt();

  final cropW = (w.round() + 2 * extX)
      .clamp(0, image.width - cropX)
      .toInt();

  final cropY = (minY.round() - extTop).clamp(0, image.height).toInt();

  final cropH = ((maxY.round() + extBottom) - cropY)
      .clamp(0, image.height - cropY)
      .toInt();

  if (cropW <= 0 || cropH <= 0) {
    throw StateError(
      'Invalid crop size. '
      'cropX=$cropX cropY=$cropY cropW=$cropW cropH=$cropH '
      'image=${image.width}x${image.height} '
      'QR points=${_formatPoints(pts)}',
    );
  }

  if (cropW < 20 || cropH < 20) {
    throw StateError(
      'Crop is suspiciously small. '
      'cropX=$cropX cropY=$cropY cropW=$cropW cropH=$cropH '
      'image=${image.width}x${image.height}',
    );
  }

  return _CropBox(
    x: cropX,
    y: cropY,
    width: cropW,
    height: cropH,
  );
}

void _validateQrPoints({
  required List<Offset> pts,
  required Size imageSize,
  required String source,
}) {
  if (pts.length < 4) {
    throw StateError('$source QR has fewer than 4 points.');
  }

  for (final p in pts) {
    if (!p.dx.isFinite || !p.dy.isFinite) {
      throw StateError('$source QR has invalid point: $p');
    }
  }

  final xs = pts.map((p) => p.dx).toList();
  final ys = pts.map((p) => p.dy).toList();

  final minX = xs.reduce(math.min);
  final maxX = xs.reduce(math.max);
  final minY = ys.reduce(math.min);
  final maxY = ys.reduce(math.max);

  debugPrint(
    '$source QR bbox: '
    'minX=$minX maxX=$maxX minY=$minY maxY=$maxY '
    'image=${imageSize.width}x${imageSize.height}',
  );

  final completelyOutside = maxX < 0 ||
      maxY < 0 ||
      minX > imageSize.width ||
      minY > imageSize.height;

  if (completelyOutside) {
    throw StateError(
      '$source QR points are completely outside the image. '
      'This usually means preview coordinates were not scaled correctly '
      'or the photo orientation does not match the preview. '
      'points=${_formatPoints(pts)} image=$imageSize',
    );
  }
}

String _formatPoints(List<Offset> pts) {
  return pts
      .map((p) => '(${p.dx.toStringAsFixed(1)}, ${p.dy.toStringAsFixed(1)})')
      .join(', ');
}

/// Full-screen view of the analysis result.
class AnalysisResultFullScreen extends StatelessWidget {
  final String imagePath;
  final String result;
  final String confidence;
  final double? latitude;
  final double? longitude;

  const AnalysisResultFullScreen({
    super.key,
    required this.imagePath,
    required this.result,
    required this.confidence,
    this.latitude,
    this.longitude,
  });

  Future<void> _save(BuildContext ctx) async {
    final prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${dir.path}/saved_tests');

    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final fname = 'test_$ts.jpg';
    final newPath = '${saveDir.path}/$fname';

    await File(imagePath).copy(newPath);

    try {
      await Gal.putImage(newPath, album: 'LFIA Tests');
    } catch (e) {
      debugPrint('Failed to save to gallery: $e');
    }

    final entry = {
      'path': newPath,
      'result': result,
      'timestamp': ts,
      'latitude': latitude,
      'longitude': longitude,
    };

    final raw = prefs.getStringList('saved_tests') ?? [];
    raw.add(jsonEncode(entry));
    await prefs.setStringList('saved_tests', raw);

    try {
      await FirebaseFirestore.instance.collection('test_results').add({
        'result': result,
        'timestamp': Timestamp.now(),
        'latitude': latitude,
        'longitude': longitude,
      });
    } catch (e) {
      debugPrint('Firestore save failed: $e');
    }

    await showCupertinoDialog(
      context: ctx,
      builder: (_) => CupertinoAlertDialog(
        title: const Text('Saved'),
        content: const Text('Image, result & location saved.'),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double? lat = latitude;
    final double? lon = longitude;

    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Result')),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                height: 300,
                child: Image.file(File(imagePath), fit: BoxFit.contain),
              ),
              const SizedBox(height: 24),
              Text(
                result,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: CupertinoColors.label,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Confidence: $confidence%',
                style: const TextStyle(color: CupertinoColors.systemGrey),
              ),
              const SizedBox(height: 8),
              if (lat != null && lon != null) ...[
                Text(
                  'Location: ${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}',
                  style: const TextStyle(color: CupertinoColors.systemGrey),
                ),
                const SizedBox(height: 16),
              ],
              CupertinoButton.filled(
                child: const Text('Save Photo & Result'),
                onPressed: () => _save(context),
              ),
              const SizedBox(height: 8),
              CupertinoButton(
                child: const Text('View Saved Tests'),
                onPressed: () {
                  Navigator.of(context).push(
                    CupertinoPageRoute(
                      builder: (_) => const SavedTestsScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              CupertinoButton(
                child: const Text('Back'),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(height: 8),
              CupertinoButton(
                child: const Text('Learn More'),
                onPressed: () {
                  Navigator.of(context).push(
                    CupertinoPageRoute(
                      builder: (_) => const LearnMoreScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              Image.asset(
                'assets/strip_reference.png',
                width: double.infinity,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// AnalysisResultScreen without location data.
class AnalysisResultScreen extends StatelessWidget {
  final String imagePath;
  final String result;
  final String confidence;

  const AnalysisResultScreen({
    super.key,
    required this.imagePath,
    required this.result,
    required this.confidence,
  });

  Future<void> _save(BuildContext ctx) async {
    final prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${dir.path}/saved_tests');

    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final fname = 'test_$ts.jpg';
    final newPath = '${saveDir.path}/$fname';

    await File(imagePath).copy(newPath);

    final entry = {
      'path': newPath,
      'result': result,
      'timestamp': ts,
    };

    final raw = prefs.getStringList('saved_tests') ?? [];
    raw.add(jsonEncode(entry));
    await prefs.setStringList('saved_tests', raw);

    try {
      await FirebaseFirestore.instance.collection('test_results').add({
        'result': result,
        'timestamp': Timestamp.now(),
      });
    } catch (e) {
      debugPrint('Firestore save failed: $e');
    }

    await showCupertinoDialog(
      context: ctx,
      builder: (_) => CupertinoAlertDialog(
        title: const Text('Saved'),
        content: const Text('Image & result saved.'),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Result')),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 300,
                child: Image.file(File(imagePath), fit: BoxFit.contain),
              ),
              const SizedBox(height: 24),
              Text(
                result,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: CupertinoColors.label,
                ),
              ),
              const SizedBox(height: 16),
              CupertinoButton.filled(
                child: const Text('Save Photo & Result'),
                onPressed: () => _save(context),
              ),
              const SizedBox(height: 8),
              CupertinoButton(
                child: const Text('Back'),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// DisplayPictureScreen manual crop + analyze.
class DisplayPictureScreen extends StatefulWidget {
  final String imagePath;

  const DisplayPictureScreen({super.key, required this.imagePath});

  @override
  _DisplayPictureScreenState createState() => _DisplayPictureScreenState();
}

class _DisplayPictureScreenState extends State<DisplayPictureScreen> {
  Interpreter? _interpreter;
  String _result = '';
  bool _busy = false;
  String? _croppedPath;
  final double _optimalThreshold = 0.5955;

  @override
  void dispose() {
    _interpreter?.close();
    super.dispose();
  }

  Future<void> _saveResult() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${dir.path}/saved_tests');

    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final fname = 'test_$ts.jpg';
    final newPath = '${saveDir.path}/$fname';

    final pathToSave = _croppedPath ?? widget.imagePath;
    await File(pathToSave).copy(newPath);

    double? lat;
    double? lon;

    try {
      var perm = await Geolocator.checkPermission();

      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }

      if (perm == LocationPermission.whileInUse ||
          perm == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );

        lat = pos.latitude;
        lon = pos.longitude;
      }
    } catch (_) {}

    final entry = {
      'path': newPath,
      'result': _result,
      'timestamp': ts,
      'latitude': lat,
      'longitude': lon,
    };

    final raw = prefs.getStringList('saved_tests') ?? [];
    raw.add(jsonEncode(entry));
    await prefs.setStringList('saved_tests', raw);

    try {
      await FirebaseFirestore.instance.collection('test_results').add({
        'result': _result,
        'timestamp': Timestamp.now(),
        'latitude': lat,
        'longitude': lon,
      });
    } catch (e) {
      debugPrint('Firestore save failed: $e');
    }

    if (!mounted) return;

    showCupertinoDialog(
      context: context,
      builder: (_) => CupertinoAlertDialog(
        title: const Text('Saved'),
        content: const Text('Image, result & location saved.'),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Future<void> _onCropPressed() async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: widget.imagePath,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop Your Test Strip',
          toolbarColor: CupertinoColors.activeBlue,
          activeControlsWidgetColor: CupertinoColors.white,
          hideBottomControls: true,
          lockAspectRatio: false,
          showCropGrid: true,
          aspectRatioPresets: [
            CropAspectRatioPreset.original,
            CropAspectRatioPreset.square,
            CropAspectRatioPreset.ratio4x3,
          ],
        ),
        IOSUiSettings(
          title: 'Crop Your Test Strip',
          aspectRatioLockEnabled: false,
        ),
      ],
    );

    if (cropped != null) {
      setState(() {
        _croppedPath = cropped.path;
        _result = '';
      });
    }
  }

  Future<void> _runModel(String path) async {
    setState(() => _busy = true);

    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/new_large_model.tflite',
      );

      final inputData = await _preprocessImage(path);
      final input = inputData.reshape([1, 256, 256, 1]);
      final output = Float32List(1).reshape([1, 1]);

      _interpreter!.run(input, output);

      final prob = output[0][0];
      final conf = (prob * 100).toStringAsFixed(1);
      final label = prob >= _optimalThreshold ? 'Positive' : 'Negative';
      final lowC =
          prob > _optimalThreshold - 0.1 && prob < _optimalThreshold + 0.1;

      setState(() {
        _result =
            lowC ? '$label\n(Low confidence: $conf%)' : '$label\n($conf%)';
        _busy = false;
      });
    } catch (e) {
      debugPrint('Manual model failed: $e');

      setState(() {
        _result = 'Error analyzing image';
        _busy = false;
      });
    } finally {
      _interpreter?.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          child: const Icon(CupertinoIcons.back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: const Text('Test Result'),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(widget.imagePath),
                    height: 300,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 24),
                if (_busy)
                  const Column(
                    children: [
                      CupertinoActivityIndicator(),
                      SizedBox(height: 16),
                      Text('Analyzing test strip...'),
                    ],
                  )
                else if (_result.isNotEmpty) ...[
                  Text(
                    _result,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                CupertinoButton.filled(
                  onPressed: _onCropPressed,
                  child: const Icon(CupertinoIcons.crop),
                ),
                const SizedBox(height: 12),
                CupertinoButton.filled(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  onPressed: (_croppedPath != null && !_busy)
                      ? () => _runModel(_croppedPath!)
                      : null,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.chart_bar,
                        size: 20,
                        color: CupertinoColors.white,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Analyze',
                        style: TextStyle(color: CupertinoColors.white),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                CupertinoButton(
                  onPressed: _result.isNotEmpty && !_busy ? _saveResult : null,
                  child: const Text('Save Result'),
                ),
                const SizedBox(height: 12),
                CupertinoButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Retake Photo'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────
// Detail view for full photo.
// ───────────────────────────────────────────────────────────────
class SavedTestDetailScreen extends StatelessWidget {
  final Map<String, dynamic> entry;

  const SavedTestDetailScreen({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final ts = entry['timestamp'] as int;
    final date = DateTime.fromMillisecondsSinceEpoch(ts);
    final formatted =
        "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} "
        "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";

    final double? lat = entry['latitude'] as double?;
    final double? lon = entry['longitude'] as double?;

    final path = (entry['path'] as String?) ?? '';
    final file = File(path);

    Widget bigImage;

    if (path.isEmpty || !file.existsSync()) {
      bigImage = const _MissingFilePlaceholder();
    } else {
      bigImage = Image.file(
        file,
        fit: BoxFit.contain,
        width: double.infinity,
        gaplessPlayback: true,
        errorBuilder: (ctx, err, stack) => const _MissingFilePlaceholder(),
      );
    }

    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Test Detail'),
        transitionBetweenRoutes: false,
      ),
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: bigImage,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                children: [
                  Text(
                    entry['result'].toString(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    formatted,
                    style: const TextStyle(color: CupertinoColors.systemGrey),
                  ),
                  if (lat != null && lon != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Location: ${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}',
                      style:
                          const TextStyle(color: CupertinoColors.systemGrey),
                    ),
                  ],
                ],
              ),
            ),
            CupertinoButton(
              child: const Text('Back'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────
// Screen listing saved tests.
// ───────────────────────────────────────────────────────────────
class SavedTestsScreen extends StatefulWidget {
  const SavedTestsScreen({super.key});

  @override
  _SavedTestsScreenState createState() => _SavedTestsScreenState();
}

class _SavedTestsScreenState extends State<SavedTestsScreen> {
  List<Map<String, dynamic>> _entries = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('saved_tests') ?? [];

    setState(() {
      _entries = raw
          .map((e) => jsonDecode(e) as Map<String, dynamic>)
          .toList();
    });
  }

  Future<void> _delete(int i) async {
    final prefs = await SharedPreferences.getInstance();

    final path = (_entries[i]['path'] as String?) ?? '';

    if (path.isNotEmpty) {
      final f = File(path);

      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }

    _entries.removeAt(i);

    final raw = _entries.map(jsonEncode).toList();
    await prefs.setStringList('saved_tests', raw);

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Saved Results'),
        transitionBetweenRoutes: false,
      ),
      child: SafeArea(
        child: _entries.isEmpty
            ? const Center(child: Text('No saved tests.'))
            : ListView.builder(
                itemCount: _entries.length,
                itemBuilder: (context, i) {
                  final e = _entries[i];

                  final ts = e['timestamp'] as int;
                  final date = DateTime.fromMillisecondsSinceEpoch(ts);

                  final formattedDate =
                      "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} "
                      "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";

                  final double? lat = e['latitude'] as double?;
                  final double? lon = e['longitude'] as double?;

                  final subtitleText = (lat != null && lon != null)
                      ? '$formattedDate · (${lat.toStringAsFixed(3)}, ${lon.toStringAsFixed(3)})'
                      : formattedDate;

                  return GestureDetector(
                    onTap: () async {
                      final path = (e['path'] as String?) ?? '';

                      if (path.isEmpty || !File(path).existsSync()) {
                        await showCupertinoDialog(
                          context: context,
                          builder: (_) => CupertinoAlertDialog(
                            title: const Text('File not found'),
                            content: const Text(
                              'This saved image is missing or unreadable.',
                            ),
                            actions: [
                              CupertinoDialogAction(
                                isDestructiveAction: true,
                                child: const Text('Remove entry'),
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await _delete(i);
                                },
                              ),
                              CupertinoDialogAction(
                                child: const Text('Cancel'),
                                onPressed: () => Navigator.pop(context),
                              ),
                            ],
                          ),
                        );
                        return;
                      }

                      Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) => SavedTestDetailScreen(entry: e),
                        ),
                      );
                    },
                    child: CupertinoListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.file(
                          File(e['path']),
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                          errorBuilder: (ctx, err, stack) =>
                              const _ThumbFallback(),
                        ),
                      ),
                      title: Text(e['result'].toString().split('\n').first),
                      subtitle: Text(subtitleText),
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        child: const Icon(CupertinoIcons.delete),
                        onPressed: () => _delete(i),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

// ────────────────── helpers ──────────────────
class _MissingFilePlaceholder extends StatelessWidget {
  const _MissingFilePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F3F5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x11000000)),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            CupertinoIcons.photo_fill,
            size: 36,
            color: CupertinoColors.systemGrey,
          ),
          SizedBox(height: 8),
          Text(
            'Image unavailable',
            style: TextStyle(color: CupertinoColors.systemGrey),
          ),
        ],
      ),
    );
  }
}

class _ThumbFallback extends StatelessWidget {
  const _ThumbFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 50,
      height: 50,
      color: const Color(0xFFE9ECEF),
      alignment: Alignment.center,
      child: const Icon(
        CupertinoIcons.photo,
        size: 22,
        color: CupertinoColors.systemGrey2,
      ),
    );
  }
}