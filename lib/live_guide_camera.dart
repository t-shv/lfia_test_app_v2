// lib/live_guide_camera.dart
import 'dart:async';
import 'dart:math';
import 'dart:ui'; // for ImageFilter and Size

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:camera/camera.dart';

class LockedQr {
  const LockedQr({
    required this.barcode,
    required this.captureSize,
    this.sessionId,
  });

  final Barcode barcode;
  final Size captureSize;
  final int? sessionId;
}

class LiveGuideCamera extends StatefulWidget {
  const LiveGuideCamera({super.key, required this.onShutter});

  final Future<void> Function(String imagePath, LockedQr qr) onShutter;

  @override
  State<LiveGuideCamera> createState() => _LiveGuideCameraState();
}

class _LiveGuideCameraState extends State<LiveGuideCamera> {
  /* ────────── scanner ────────── */
  final _scanner = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.unrestricted,
    detectionTimeoutMs: 0,
    returnImage: false,
  );

  /* distance band */
  static const double _minFill = 0.35;
  static const double _maxFill = 0.75;

  /* auto-capture */
  static const int _framesToLock = 40;
  int _goodFrames = 0;
  bool _auto = false;
  Stopwatch? _validSequenceClock;
  Stopwatch? _fromLockClock;

  /* ui */
  String _main = 'Point at QR';
  String _sub = '';
  bool _ready = false;
  bool _torch = false;

  /* temp */
  LockedQr? _qr;
  bool _paused = false;
  bool _frameLogged = false; // Log only the first live frame for diagnostics.
  double? _nativeConfiguredGuideWidth;
  double? _nativeConfiguredGuideHeight;
  Object? _nativeAcceptanceConfigInFlight;
  DateTime? _nativeAcceptanceLastAttempt;

  /* ────────── build ────────── */
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final guideW = size.width * 0.4;
    final guideH = size.height * 0.7;

    return Stack(
      children: [
        _scannerView(guideW, guideH),
        _GuideOverlay(guideW: guideW, guideH: guideH, highlight: _ready),
        _HintPill(main: _main, sub: _sub, highlight: _ready),
        _flash(),
        if (_ready) _shutter(),
      ],
    );
  }

  /* preview + QR logic */
  Widget _scannerView(double w, double h) => MobileScanner(
    controller: _scanner,
    onDetect: (cap) {
      if (_auto) return;

      _configureNativeAcceptanceGeometry(w, h);

      final eventId = _eventId(cap);
      final sessionId = _sessionId(cap);
      void logAcceptance(bool accepted, double? fill, int sequence) {
        debugPrint(
          '[DART_ACCEPTANCE] session_id=${sessionId ?? -1} '
          'event_id=${eventId ?? -1} accepted=$accepted '
          'fill=${fill ?? "unavailable"} sequence=$sequence',
        );
      }

      // Diagnostic: confirm that mobile_scanner provides image bytes.
      if (!_frameLogged && cap.image != null) {
        _frameLogged = true;
        debugPrint('====== LIVE FRAME RECEIVED ======');
        debugPrint('Image bytes: ${cap.image!.length}');
        debugPrint('Capture size: ${cap.size.width} x ${cap.size.height}');
      }

      Barcode? qr;
      for (final b in cap.barcodes) {
        if (b.rawValue != null) {
          qr = b;
          break;
        }
      }

      if (qr == null) {
        logAcceptance(false, null, 0);
        return _reset('Point at QR');
      }
      if (qr.corners.length < 4) {
        logAcceptance(false, null, 0);
        return _reset('Point at QR');
      }

      final xs = qr.corners.map((p) => p.dx);
      final ys = qr.corners.map((p) => p.dy);

      final qrW = xs.reduce(max) - xs.reduce(min);
      final qrH = ys.reduce(max) - ys.reduce(min);

      if (qrW <= 0 || qrH <= 0) {
        logAcceptance(false, null, 0);
        return _reset('Point at QR');
      }

      final fill = (qrW * qrH) / (w * h);

      if (fill < _minFill) {
        logAcceptance(false, fill, 0);
        return _reset('Move closer');
      }
      if (fill > _maxFill) {
        logAcceptance(false, fill, 0);
        return _reset('Move back');
      }

      _qr = LockedQr(barcode: qr, captureSize: cap.size, sessionId: sessionId);

      _validSequenceClock ??= Stopwatch()..start();
      _goodFrames++;
      logAcceptance(true, fill, _goodFrames);

      if (_goodFrames >= _framesToLock) {
        final validSequenceMs = _validSequenceClock!.elapsedMilliseconds;
        _fromLockClock = Stopwatch()..start();
        debugPrint(
          '[CAMERA_BASELINE] first_valid_to_40th_valid_ms=$validSequenceMs',
        );
        _updateHint('Hold still', dots: _repeat('●', _framesToLock));

        _auto = true;
        HapticFeedback.mediumImpact();
        _snap();
      } else {
        _updateHint('Hold still', dots: _dots(_goodFrames));
      }
    },
  );

  /* flash toggle */
  Widget _flash() => Positioned(
    top: 16,
    right: 16,
    child: CupertinoButton(
      padding: const EdgeInsets.all(12),
      borderRadius: BorderRadius.circular(24),
      color: Colors.black45,
      child: Icon(
        _torch ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt_slash_fill,
        color: CupertinoColors.white,
        size: 24,
      ),
      onPressed: () async {
        await _scanner.toggleTorch();
        if (mounted) {
          setState(() => _torch = !_torch);
        }
      },
    ),
  );

  /* manual shutter */
  Widget _shutter() => Align(
    alignment: Alignment.bottomCenter,
    child: CupertinoButton(
      padding: const EdgeInsets.all(20),
      color: CupertinoColors.activeBlue,
      onPressed: _snap,
      child: const Icon(
        CupertinoIcons.camera,
        color: CupertinoColors.white,
        size: 28,
      ),
    ),
  );

  /* ────────── capture ────────── */
  Future<void> _snap() async {
    if (_qr == null) {
      _auto = false;
      return;
    }

    CameraController? ctrl;

    try {
      final good = _qr!;

      final captureClock = _fromLockClock ?? (Stopwatch()..start());

      String? liveFramePath;
      if (good.sessionId != null) {
        final exportClock = Stopwatch()..start();
        try {
          liveFramePath = await _scanner.exportRetainedFrame(
            sessionId: good.sessionId!,
          );
          exportClock.stop();
          debugPrint(
            '[CAMERA_BASELINE] live_frame_export_ms=${exportClock.elapsedMilliseconds} '
            'success=${liveFramePath != null}',
          );
        } catch (e) {
          exportClock.stop();
          debugPrint(
            '[CAMERA_BASELINE] live_frame_export_ms=${exportClock.elapsedMilliseconds} '
            'success=false error=$e',
          );
        }
      } else {
        debugPrint(
          '[CAMERA_BASELINE] live_frame_export_skipped=true reason=no_session_id',
        );
      }

      final stopClock = Stopwatch()..start();
      await _scanner.stop();
      stopClock.stop();
      debugPrint(
        '[CAMERA_BASELINE] stop_mobile_scanner_ms=${stopClock.elapsedMilliseconds}',
      );
      _paused = true;

      if (liveFramePath != null) {
        debugPrint('[CAMERA_BASELINE] capture_source=retained_live_frame');
        await widget.onShutter(liveFramePath, good);
        debugPrint(
          '[CAMERA_BASELINE] 40th_valid_to_on_shutter_return_ms=${captureClock.elapsedMilliseconds}',
        );
        _reset('Point at QR');
        return;
      }

      debugPrint('[CAMERA_BASELINE] capture_source=separate_still_fallback');

      final camerasClock = Stopwatch()..start();
      final cams = await availableCameras();
      camerasClock.stop();
      debugPrint(
        '[CAMERA_BASELINE] available_cameras_ms=${camerasClock.elapsedMilliseconds}',
      );
      final cam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      // resolution is changed from medium to high
      ctrl = CameraController(cam, ResolutionPreset.high, enableAudio: false);

      final initializeClock = Stopwatch()..start();
      await ctrl.initialize();
      initializeClock.stop();
      debugPrint(
        '[CAMERA_BASELINE] camera_controller_initialize_ms=${initializeClock.elapsedMilliseconds}',
      );

      try {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);

        await ctrl.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (e) {
        debugPrint('Could not lock capture orientation: $e');
      }

      final takePictureClock = Stopwatch()..start();
      final XFile shot = await ctrl.takePicture();
      takePictureClock.stop();
      debugPrint(
        '[CAMERA_BASELINE] take_picture_ms=${takePictureClock.elapsedMilliseconds}',
      );
      debugPrint(
        '[CAMERA_BASELINE] 40th_valid_to_photo_available_ms=${captureClock.elapsedMilliseconds}',
      );

      await widget.onShutter(shot.path, good);
      debugPrint(
        '[CAMERA_BASELINE] 40th_valid_to_on_shutter_return_ms=${captureClock.elapsedMilliseconds}',
      );

      _reset('Point at QR');
    } catch (e, st) {
      debugPrint('====== _snap FAILED ======');
      debugPrint('$e');
      debugPrint('$st');

      try {
        if (_paused) {
          await _scanner.start();
          _paused = false;
        }
      } catch (scannerError) {
        debugPrint('Could not restart scanner after failure: $scannerError');
      }

      if (mounted) {
        await showCupertinoDialog<void>(
          context: context,
          builder:
              (_) => CupertinoAlertDialog(
                title: const Text('Capture failed'),
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

      _reset('Point at QR');
    } finally {
      try {
        await ctrl?.dispose();
      } catch (_) {}

      _auto = false;
    }
  }

  /* resume scanner when we pop back */
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final size = MediaQuery.sizeOf(context);
    _configureNativeAcceptanceGeometry(size.width * 0.4, size.height * 0.7);

    final current = ModalRoute.of(context)?.isCurrent ?? false;
    if (current && _paused) {
      _scanner.start();
      _paused = false;
    }
  }

  void _configureNativeAcceptanceGeometry(double guideW, double guideH) {
    if (_nativeConfiguredGuideWidth == guideW &&
        _nativeConfiguredGuideHeight == guideH) {
      return;
    }
    if (_nativeAcceptanceConfigInFlight != null) {
      return;
    }

    final now = DateTime.now();
    final lastAttempt = _nativeAcceptanceLastAttempt;
    if (lastAttempt != null &&
        now.difference(lastAttempt) < const Duration(seconds: 1)) {
      return;
    }

    final requestToken = Object();
    _nativeAcceptanceConfigInFlight = requestToken;
    _nativeAcceptanceLastAttempt = now;
    unawaited(() async {
      try {
        await _scanner.setAcceptanceGeometry(
          guideWidth: guideW,
          guideHeight: guideH,
          minFill: _minFill,
          maxFill: _maxFill,
        );
        if (identical(_nativeAcceptanceConfigInFlight, requestToken)) {
          _nativeConfiguredGuideWidth = guideW;
          _nativeConfiguredGuideHeight = guideH;
        }
      } catch (error) {
        debugPrint('[DART_ACCEPTANCE] native_config_error=$error');
      } finally {
        if (identical(_nativeAcceptanceConfigInFlight, requestToken)) {
          _nativeAcceptanceConfigInFlight = null;
        }
      }
    }());
  }

  int? _eventId(BarcodeCapture capture) {
    final raw = capture.raw;
    if (raw is! Map) return null;
    final value = raw['eventId'];
    return value is num ? value.toInt() : null;
  }

  int? _sessionId(BarcodeCapture capture) {
    final raw = capture.raw;
    if (raw is! Map) return null;
    final value = raw['sessionId'];
    return value is num ? value.toInt() : null;
  }

  /* ────────── helpers ────────── */
  void _reset(String msg) {
    _goodFrames = 0;
    _auto = false;
    _qr = null;
    _validSequenceClock = null;
    _fromLockClock = null;
    _updateHint(msg);
  }

  String _repeat(String value, int count) {
    if (count <= 0) return '';
    return List.filled(count, value).join();
  }

  String _dots(int filled) {
    final safeFilled = filled.clamp(0, _framesToLock);
    final empty = _framesToLock - filled.clamp(0, _framesToLock);
    return _repeat('●', safeFilled) + _repeat('○', empty);
  }

  void _updateHint(String main, {String dots = ''}) {
    if (!mounted) return;

    setState(() {
      _main = main;
      _sub = dots;
      _ready = main == 'Hold still';
    });
  }

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }
}

/* hint pill */
class _HintPill extends StatelessWidget {
  const _HintPill({
    required this.main,
    required this.sub,
    required this.highlight,
  });

  final String main, sub;
  final bool highlight;

  @override
  Widget build(BuildContext ctx) {
    final size = MediaQuery.of(ctx).size;

    return Positioned(
      top: size.height * .05,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 60),
          offset: highlight ? Offset.zero : const Offset(.015, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .25),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .08),
                    width: 1,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOut,
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                        color:
                            highlight
                                ? CupertinoColors.systemGreen
                                : CupertinoColors.white,
                        shadows: const [
                          Shadow(blurRadius: 6, color: Colors.black54),
                        ],
                      ),
                      child: Text(main),
                    ),
                    if (sub.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        sub,
                        style: const TextStyle(
                          fontSize: 20,
                          color: CupertinoColors.white,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/* white / green guide rectangle with feathered bands */
class _GuideOverlay extends StatelessWidget {
  const _GuideOverlay({
    required this.guideW,
    required this.guideH,
    required this.highlight,
  });

  final double guideW, guideH;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: Column(
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black54, Colors.transparent],
              ),
            ),
          ),
        ),
        Container(
          width: guideW,
          height: guideH,
          decoration: BoxDecoration(
            border: Border.all(
              color:
                  highlight
                      ? CupertinoColors.systemGreen
                      : CupertinoColors.white,
              width: 3,
            ),
          ),
        ),
        Expanded(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black54, Colors.transparent],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
