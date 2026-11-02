package dev.steenbakker.mobile_scanner

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.annotation.VisibleForTesting
import androidx.camera.camera2.Camera2Config
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraXConfig
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ExperimentalLensFacing
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.TorchState
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import dev.steenbakker.mobile_scanner.objects.DetectionSpeed
import dev.steenbakker.mobile_scanner.objects.MobileScannerErrorCodes
import dev.steenbakker.mobile_scanner.objects.MobileScannerStartParameters
import dev.steenbakker.mobile_scanner.utils.YuvToRgbConverter
import dev.steenbakker.mobile_scanner.utils.YuvByteBuffer
import dev.steenbakker.mobile_scanner.utils.serialize
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.Executors
import kotlin.math.roundToInt

class MobileScanner(
    private val activity: Activity,
    private val textureRegistry: TextureRegistry,
    private val mobileScannerCallback: MobileScannerCallback,
    private val mobileScannerErrorCallback: MobileScannerErrorCallback,
    private val deviceOrientationListener: DeviceOrientationListener,
    private val barcodeScannerFactory: (options: BarcodeScannerOptions?) -> BarcodeScanner = ::defaultBarcodeScannerFactory,
) {

    init {
        configureCameraProcessProvider()
    }

    /// Internal variables
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var cameraSelector: CameraSelector? = null
    private var preview: Preview? = null
    private var surfaceProducer: TextureRegistry.SurfaceProducer? = null
    private var scanner: BarcodeScanner? = null
    private var lastScanned: List<String?>? = null
    private var scannerTimeout = false
    private var displayListener: DisplayManager.DisplayListener? = null

    /// Configurable variables
    var scanWindow: List<Float>? = null
    private var invertImage: Boolean = false
    private var detectionSpeed: DetectionSpeed = DetectionSpeed.NO_DUPLICATES
    private var detectionTimeout: Long = 250
    private var returnImage = false
    private var isPaused = false
    private val nativeFrameBaselineLogged = AtomicBoolean(false)
    private val nativeBarcodePositiveCount = AtomicInteger(0)
    private val nativeDetectionEventId = AtomicLong(0)
    private val nativeAcceptanceSequence = AtomicInteger(0)
    private val retainedFrameLock = Any()
    private var retainedFrame: RetainedYuvFrame? = null
    private var retentionInProgress = false
    private var retentionSessionId = 0L
    private var retentionSessionActive = false
    private var acceptanceGuideWidth: Double? = null
    private var acceptanceGuideHeight: Double? = null
    private var acceptanceMinFill: Double? = null
    private var acceptanceMaxFill: Double? = null

    private data class RetainedYuvFrame(
        val bytes: ByteArray,
        val width: Int,
        val height: Int,
        val rotationDegrees: Int,
        val sourceFormat: Int,
        val bufferFormat: Int,
        val timestamp: Long,
    )

    private data class AcceptanceConfig(
        val guideWidth: Double?,
        val guideHeight: Double?,
        val minFill: Double?,
        val maxFill: Double?,
    )

    private data class AcceptanceResult(
        val accepted: Boolean,
        val fill: Double?,
        val configured: Boolean,
    )

    companion object {
        // Configure the `ProcessCameraProvider` to only log errors.
        // This prevents the informational log spam from CameraX.
        private fun configureCameraProcessProvider() {
            try {
                val config = CameraXConfig.Builder.fromConfig(Camera2Config.defaultConfig()).apply {
                    setMinimumLoggingLevel(Log.ERROR)
                }
                ProcessCameraProvider.configureInstance(config.build())
            } catch (_: IllegalStateException) {
                // The ProcessCameraProvider was already configured.
                // Do nothing.
            }
        }

        /**
         * Create a barcode scanner from the given options.
         */
        fun defaultBarcodeScannerFactory(options: BarcodeScannerOptions?) : BarcodeScanner {
            return if (options == null) BarcodeScanning.getClient() else BarcodeScanning.getClient(options)
        }
    }

    /**
     * callback for the camera. Every frame is passed through this function.
     */
    @ExperimentalGetImage
    val captureOutput = ImageAnalysis.Analyzer { imageProxy -> // YUV_420_888 format
        val mediaImage = imageProxy.image ?: return@Analyzer

        if (nativeFrameBaselineLogged.compareAndSet(false, true)) {
            val planes = imageProxy.planes
            Log.d(
                "MobileScanner",
                "[NATIVE_FRAME_BASELINE] first_frame " +
                    "width=${imageProxy.width} height=${imageProxy.height} " +
                    "format=${imageProxy.format} " +
                    "rotation_degrees=${imageProxy.imageInfo.rotationDegrees} " +
                    "y_row_stride=${planes.getOrNull(0)?.rowStride} " +
                    "y_pixel_stride=${planes.getOrNull(0)?.pixelStride} " +
                    "u_row_stride=${planes.getOrNull(1)?.rowStride} " +
                    "u_pixel_stride=${planes.getOrNull(1)?.pixelStride} " +
                    "v_row_stride=${planes.getOrNull(2)?.rowStride} " +
                    "v_pixel_stride=${planes.getOrNull(2)?.pixelStride}",
            )
        }

        val inputImage = if (invertImage) {
            invertInputImage(imageProxy)
        } else {
            InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
        }

        if (detectionSpeed == DetectionSpeed.NORMAL && scannerTimeout) {
            imageProxy.close()
            return@Analyzer
        } else if (detectionSpeed == DetectionSpeed.NORMAL) {
            scannerTimeout = true
        }

        scanner?.let {
            val frameSessionId = synchronized(retainedFrameLock) {
                if (retentionSessionActive) retentionSessionId else null
            }

            it.process(inputImage).addOnSuccessListener { barcodes ->
                if (detectionSpeed == DetectionSpeed.NO_DUPLICATES) {
                    val newScannedBarcodes = barcodes.mapNotNull {
                        barcode -> barcode.rawValue
                    }.sorted()

                    if (newScannedBarcodes == lastScanned) {
                        // New scanned is duplicate, returning
                        imageProxy.close()
                        return@addOnSuccessListener
                    }
                    if (newScannedBarcodes.isNotEmpty()) {
                        lastScanned = newScannedBarcodes
                    }
                }

                val barcodeMap: MutableList<Map<String, Any?>> = mutableListOf()
                var firstAcceptedBarcode: Barcode? = null
                var firstFlutterBarcode: Barcode? = null

                for (barcode in barcodes) {
                    if (scanWindow == null) {
                        barcodeMap.add(barcode.data)
                        firstAcceptedBarcode = firstAcceptedBarcode ?: barcode
                        if (firstFlutterBarcode == null && barcode.rawValue != null) {
                            firstFlutterBarcode = barcode
                        }
                        continue
                    }

                    if (isBarcodeInScanWindow(scanWindow!!, barcode, imageProxy)) {
                        barcodeMap.add(barcode.data)
                        firstAcceptedBarcode = firstAcceptedBarcode ?: barcode
                        if (firstFlutterBarcode == null && barcode.rawValue != null) {
                            firstFlutterBarcode = barcode
                        }
                    }
                }

                if (barcodeMap.isEmpty()) {
                    imageProxy.close()
                    return@addOnSuccessListener
                }

                val detectionEventId = nativeDetectionEventId.incrementAndGet()
                val acceptanceConfig = synchronized(retainedFrameLock) {
                    AcceptanceConfig(
                        acceptanceGuideWidth,
                        acceptanceGuideHeight,
                        acceptanceMinFill,
                        acceptanceMaxFill,
                    )
                }
                val nativeAcceptance = evaluateAcceptance(firstFlutterBarcode, acceptanceConfig)
                val nativeSequence = if (nativeAcceptance.accepted) {
                    nativeAcceptanceSequence.incrementAndGet()
                } else {
                    nativeAcceptanceSequence.set(0)
                    0
                }
                Log.d(
                    "MobileScanner",
                    "[NATIVE_ACCEPTANCE] session_id=${frameSessionId ?: -1L} " +
                        "event_id=$detectionEventId configured=${nativeAcceptance.configured} " +
                        "accepted=${nativeAcceptance.accepted} " +
                        "fill=${nativeAcceptance.fill ?: "unavailable"} sequence=$nativeSequence",
                )

                if (frameSessionId != null) {
                    retainFirstYuvFrame(imageProxy, mediaImage, frameSessionId)
                }

                val positiveCount = nativeBarcodePositiveCount.incrementAndGet()
                if (positiveCount % 10 == 0) {
                    val rotationDegrees = imageProxy.imageInfo.rotationDegrees
                    val uprightWidth = if (rotationDegrees == 90 || rotationDegrees == 270) {
                        imageProxy.height.toFloat()
                    } else {
                        imageProxy.width.toFloat()
                    }
                    val uprightHeight = if (rotationDegrees == 90 || rotationDegrees == 270) {
                        imageProxy.width.toFloat()
                    } else {
                        imageProxy.height.toFloat()
                    }
                    val boundingBox = firstAcceptedBarcode?.boundingBox
                    if (boundingBox != null) {
                        Log.d(
                            "MobileScanner",
                            "[NATIVE_FRAME_BASELINE] barcode_positive_count=$positiveCount " +
                                "bbox_width_norm=${boundingBox.width().toFloat() / uprightWidth} " +
                                "bbox_height_norm=${boundingBox.height().toFloat() / uprightHeight} " +
                                "center_x_norm=${boundingBox.centerX().toFloat() / uprightWidth} " +
                                "center_y_norm=${boundingBox.centerY().toFloat() / uprightHeight} " +
                                "image_width=${imageProxy.width} image_height=${imageProxy.height} " +
                                "upright_width=${uprightWidth.toInt()} upright_height=${uprightHeight.toInt()} " +
                                "rotation_degrees=$rotationDegrees",
                        )
                    } else {
                        Log.d(
                            "MobileScanner",
                            "[NATIVE_FRAME_BASELINE] barcode_positive_count=$positiveCount " +
                                "bbox=unavailable image_width=${imageProxy.width} " +
                                "image_height=${imageProxy.height} " +
                                "upright_width=${uprightWidth.toInt()} upright_height=${uprightHeight.toInt()} " +
                                "rotation_degrees=$rotationDegrees",
                        )
                    }
                }

                val portrait = (camera?.cameraInfo?.sensorRotationDegrees ?: 0) % 180 == 0

                if (!returnImage) {
                    mobileScannerCallback(
                        barcodeMap,
                        null,
                        if (portrait) inputImage.width else inputImage.height,
                        if (portrait) inputImage.height else inputImage.width,
                        frameSessionId ?: -1L,
                        detectionEventId)
                    imageProxy.close()
                    return@addOnSuccessListener
                }

                CoroutineScope(Dispatchers.IO).launch {
                    val bitmap = Bitmap.createBitmap(mediaImage.width, mediaImage.height, Bitmap.Config.ARGB_8888)
                    val imageFormat = YuvToRgbConverter(activity.applicationContext)

                    imageFormat.yuvToRgb(mediaImage, bitmap)

                    val bmResult = rotateBitmap(bitmap, camera?.cameraInfo?.sensorRotationDegrees?.toFloat() ?: 90f)

                    val stream = ByteArrayOutputStream()
                    bmResult.compress(Bitmap.CompressFormat.PNG, 100, stream)
                    val byteArray = stream.toByteArray()
                    val bmWidth = bmResult.width
                    val bmHeight = bmResult.height

                    mobileScannerCallback(
                        barcodeMap,
                        byteArray,
                        bmWidth,
                        bmHeight,
                        frameSessionId ?: -1L,
                        detectionEventId
                    )

                    bmResult.recycle()
                    imageProxy.close()
                    imageFormat.release()
                }

            }.addOnFailureListener { e ->
                mobileScannerErrorCallback(
                    e.localizedMessage ?: e.toString()
                )
            }
        }

        if (detectionSpeed == DetectionSpeed.NORMAL) {
            // Set timer and continue
            Handler(Looper.getMainLooper()).postDelayed({
                scannerTimeout = false
            }, detectionTimeout)
        }
    }

    @ExperimentalGetImage
    private fun retainFirstYuvFrame(
        imageProxy: ImageProxy,
        mediaImage: android.media.Image,
        sessionId: Long,
    ) {
        synchronized(retainedFrameLock) {
            if (!retentionSessionActive || retentionSessionId != sessionId ||
                retainedFrame != null || retentionInProgress
            ) {
                return
            }
            retentionInProgress = true
        }

        val copyStartNanos = System.nanoTime()
        var ownedBytes: ByteArray? = null
        var retained = false
        var width = -1
        var height = -1
        var rotationDegrees = -1
        var sourceFormat = -1

        try {
            width = imageProxy.width
            height = imageProxy.height
            rotationDegrees = imageProxy.imageInfo.rotationDegrees
            sourceFormat = imageProxy.format
            val planes = imageProxy.planes

            require(sourceFormat == ImageFormat.YUV_420_888) {
                "unsupported image format $sourceFormat"
            }
            require(width >= 2 && height >= 2 && width % 2 == 0 && height % 2 == 0) {
                "invalid YUV dimensions ${width}x${height}"
            }
            require(planes.size >= 3) {
                "expected 3 YUV planes, got ${planes.size}"
            }
            planes.forEachIndexed { index, plane ->
                require(plane.rowStride > 0 && plane.pixelStride > 0) {
                    "invalid plane $index stride"
                }
                require(plane.buffer.capacity() > 0) {
                    "empty plane $index buffer"
                }
            }

            val yuv = YuvByteBuffer(mediaImage)
            val ownedBuffer = yuv.buffer.duplicate()
            ownedBuffer.rewind()
            val copiedBytes = ByteArray(ownedBuffer.remaining())
            ownedBuffer.get(copiedBytes)
            ownedBytes = copiedBytes

            val retainedFrame = RetainedYuvFrame(
                bytes = copiedBytes,
                width = width,
                height = height,
                rotationDegrees = rotationDegrees,
                sourceFormat = sourceFormat,
                bufferFormat = yuv.type,
                timestamp = imageProxy.imageInfo.timestamp,
            )

            synchronized(retainedFrameLock) {
                if (retentionSessionActive && retentionSessionId == sessionId &&
                    this.retainedFrame == null
                ) {
                    this.retainedFrame = retainedFrame
                    retained = true
                }
            }

            if (!retained) {
                ownedBytes.fill(0)
            }

            val durationMicros = (System.nanoTime() - copyStartNanos) / 1_000L
            Log.d(
                "MobileScanner",
                "[NATIVE_FRAME_RETENTION] " +
                    "success=$retained copy_duration_us=$durationMicros " +
                    "bytes=${copiedBytes.size} width=$width height=$height " +
                    "rotation_degrees=$rotationDegrees " +
                    "source_format=$sourceFormat buffer_format=${yuv.type}",
            )
        } catch (exception: Exception) {
            ownedBytes?.fill(0)
            val durationMicros = (System.nanoTime() - copyStartNanos) / 1_000L
            Log.d(
                "MobileScanner",
                "[NATIVE_FRAME_RETENTION] success=false copy_duration_us=$durationMicros " +
                    "bytes=${ownedBytes?.size ?: 0} width=$width height=$height " +
                    "rotation_degrees=$rotationDegrees source_format=$sourceFormat " +
                    "reason=${exception.message ?: exception.javaClass.simpleName}",
            )
        } finally {
            synchronized(retainedFrameLock) {
                if (retentionSessionId == sessionId) {
                    retentionInProgress = false
                }
            }
        }
    }

    private fun clearRetainedFrameLocked() {
        retainedFrame?.bytes?.fill(0)
        retainedFrame = null
    }

    private fun evaluateAcceptance(
        barcode: Barcode?,
        config: AcceptanceConfig,
    ): AcceptanceResult {
        val guideWidth = config.guideWidth
        val guideHeight = config.guideHeight
        val minFill = config.minFill
        val maxFill = config.maxFill
        if (barcode == null || guideWidth == null || guideHeight == null ||
            minFill == null || maxFill == null || guideWidth <= 0.0 || guideHeight <= 0.0
        ) {
            return AcceptanceResult(false, null, guideWidth != null && guideHeight != null &&
                minFill != null && maxFill != null)
        }

        val corners = barcode.cornerPoints ?: return AcceptanceResult(false, null, true)
        if (corners.size < 4) {
            return AcceptanceResult(false, null, true)
        }

        val qrWidth = corners.maxOf { it.x } - corners.minOf { it.x }
        val qrHeight = corners.maxOf { it.y } - corners.minOf { it.y }
        if (qrWidth <= 0 || qrHeight <= 0) {
            return AcceptanceResult(false, null, true)
        }

        val fill = (qrWidth.toDouble() * qrHeight.toDouble()) / (guideWidth * guideHeight)
        return AcceptanceResult(fill >= minFill && fill <= maxFill, fill, true)
    }

    fun setAcceptanceGeometry(
        guideWidth: Double,
        guideHeight: Double,
        minFill: Double,
        maxFill: Double,
    ) {
        synchronized(retainedFrameLock) {
            acceptanceGuideWidth = guideWidth
            acceptanceGuideHeight = guideHeight
            acceptanceMinFill = minFill
            acceptanceMaxFill = maxFill
        }
    }

    /**
     * Create a {@link Preview.SurfaceProvider} that specifies how to provide a {@link Surface} to a
     * {@code Preview}.
     */
    @VisibleForTesting
    fun createSurfaceProvider(surfaceProducer: TextureRegistry.SurfaceProducer): Preview.SurfaceProvider {
        return Preview.SurfaceProvider {
            request: SurfaceRequest ->
            run {
                // Set the callback for the surfaceProducer to invalidate Surfaces that it produces
                // when they get destroyed.
                surfaceProducer.setCallback(
                    object : TextureRegistry.SurfaceProducer.Callback {
                        override fun onSurfaceAvailable() {
                            // Do nothing. The Preview.SurfaceProvider will handle this
                            // whenever a new Surface is needed.
                        }

                        override fun onSurfaceCleanup() {
                            // Invalidate the SurfaceRequest so that CameraX knows to to make a new request
                            // for a surface.
                            request.invalidate()
                        }
                    }
                )

                // Provide the surface.
                surfaceProducer.setSize(request.resolution.width, request.resolution.height)

                val surface: Surface = surfaceProducer.surface

                // The single thread executor is only used to invoke the result callback.
                // Thus it is safe to use a new executor,
                // instead of reusing the executor that is passed to the camera process provider.
                request.provideSurface(surface, Executors.newSingleThreadExecutor()) {
                    // Handle the result of the request for a surface.
                    // See: https://developer.android.com/reference/androidx/camera/core/SurfaceRequest.Result

                    // Always attempt a release.
                    surface.release()

                    val resultCode: Int = it.resultCode

                    when(resultCode) {
                        SurfaceRequest.Result.RESULT_REQUEST_CANCELLED,
                        SurfaceRequest.Result.RESULT_WILL_NOT_PROVIDE_SURFACE,
                        SurfaceRequest.Result.RESULT_SURFACE_ALREADY_PROVIDED,
                        SurfaceRequest.Result.RESULT_SURFACE_USED_SUCCESSFULLY -> {
                            // Only need to release, do nothing.
                        }
                        SurfaceRequest.Result.RESULT_INVALID_SURFACE -> {
                            // The surface was invalid, so it is not clear how to recover from this.
                        }
                        else -> {
                            // Fallthrough, in case any result codes are added later.
                        }
                    }
                }
            }
        }
    }

    @ExperimentalLensFacing
    private fun getCameraLensFacing(camera: Camera?): Int? {
        return when(camera?.cameraInfo?.lensFacing) {
            CameraSelector.LENS_FACING_BACK -> 1
            CameraSelector.LENS_FACING_FRONT -> 0
            CameraSelector.LENS_FACING_EXTERNAL -> 2
            CameraSelector.LENS_FACING_UNKNOWN -> null
            else -> null
        }
    }

    private fun rotateBitmap(bitmap: Bitmap, degrees: Float): Bitmap {
        val matrix = Matrix()
        matrix.postRotate(degrees)
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    // Scales the scanWindow to the provided inputImage and checks if that scaled
    // scanWindow contains the barcode.
    @VisibleForTesting
    fun isBarcodeInScanWindow(
        scanWindow: List<Float>,
        barcode: Barcode,
        inputImage: ImageProxy
    ): Boolean {
        // TODO: use `cornerPoints` instead, since the bounding box is not bound to the coordinate system of the input image
        // On iOS we do this correctly, so the calculation should match that.
        val barcodeBoundingBox = barcode.boundingBox ?: return false

        try {
            val imageWidth = inputImage.height
            val imageHeight = inputImage.width

            val left = (scanWindow[0] * imageWidth).roundToInt()
            val top = (scanWindow[1] * imageHeight).roundToInt()
            val right = (scanWindow[2] * imageWidth).roundToInt()
            val bottom = (scanWindow[3] * imageHeight).roundToInt()

            val scaledScanWindow = Rect(left, top, right, bottom)

            return scaledScanWindow.contains(barcodeBoundingBox)
        } catch (exception: IllegalArgumentException) {
            // Rounding of the scan window dimensions can fail, due to encountering NaN.
            // If we get NaN, rather than give a false positive, just return false.
            return false
        }
    }

    /**
     * Start barcode scanning by initializing the camera and barcode scanner.
     */
    @ExperimentalLensFacing
    @ExperimentalGetImage
    fun start(
        barcodeScannerOptions: BarcodeScannerOptions?,
        returnImage: Boolean,
        cameraPosition: CameraSelector,
        torch: Boolean,
        detectionSpeed: DetectionSpeed,
        torchStateCallback: TorchStateCallback,
        zoomScaleStateCallback: ZoomScaleStateCallback,
        mobileScannerStartedCallback: MobileScannerStartedCallback,
        mobileScannerErrorCallback: (exception: Exception) -> Unit,
        detectionTimeout: Long,
        cameraResolutionWanted: Size?,
        invertImage: Boolean,
    ) {
        this.detectionSpeed = detectionSpeed
        this.detectionTimeout = detectionTimeout
        this.returnImage = returnImage
        this.invertImage = invertImage
        nativeFrameBaselineLogged.set(false)
        nativeBarcodePositiveCount.set(0)
        nativeDetectionEventId.set(0)
        nativeAcceptanceSequence.set(0)

        if (camera?.cameraInfo != null && preview != null && surfaceProducer != null && !isPaused) {

// TODO: resume here for seamless transition
//            if (isPaused) {
//                resumeCamera()
//                val cameraDirection = getCameraLensFacing(camera)
//                mobileScannerStartedCallback(
//                  MobileScannerStartParameters(
//                    if (portrait) width else height,
//                    if (portrait) height else width,
//                    deviceOrientationListener.getUIOrientation().serialize(),
//                    sensorRotationDegrees,
//                    surfaceProducer!!.handlesCropAndRotation(),
//                    currentTorchState,
//                    surfaceProducer!!.id(),
//                    numberOfCameras ?: 0,
//                    cameraDirection
//                  )
//                )
//                return
//            }
            mobileScannerErrorCallback(AlreadyStarted())

            return
        }

        lastScanned = null
        scanner = barcodeScannerFactory(barcodeScannerOptions)
        synchronized(retainedFrameLock) {
            clearRetainedFrameLocked()
            retentionSessionId += 1
            retentionSessionActive = true
            retentionInProgress = false
        }

        val cameraProviderFuture = ProcessCameraProvider.getInstance(activity)
        val executor = ContextCompat.getMainExecutor(activity)

        cameraProviderFuture.addListener({
            cameraProvider = cameraProviderFuture.get()
            val numberOfCameras = cameraProvider?.availableCameraInfos?.size

            if (cameraProvider == null) {
                mobileScannerErrorCallback(CameraError())

                return@addListener
            }

            cameraProvider?.unbindAll()
            surfaceProducer = surfaceProducer ?: textureRegistry.createSurfaceProducer()
            val surfaceProvider: Preview.SurfaceProvider = createSurfaceProvider(surfaceProducer!!)

            // Preview

            // Build the preview to be shown on the Flutter texture
            val previewBuilder = Preview.Builder()
            preview = previewBuilder.build().apply { setSurfaceProvider(surfaceProvider) }

            // Build the analyzer to be passed on to MLKit
            val analysisBuilder = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            val displayManager = activity.applicationContext.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager

            val cameraResolution =  cameraResolutionWanted ?: Size(1920, 1080)

            val selectorBuilder = ResolutionSelector.Builder()
            selectorBuilder.setResolutionStrategy(
                ResolutionStrategy(
                    cameraResolution,
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                )
            )
            analysisBuilder.setResolutionSelector(selectorBuilder.build()).build()

            if (displayListener == null) {
                displayListener = object : DisplayManager.DisplayListener {
                    override fun onDisplayAdded(displayId: Int) {}

                    override fun onDisplayRemoved(displayId: Int) {}

                    override fun onDisplayChanged(displayId: Int) {
                        val selector = ResolutionSelector.Builder().setResolutionStrategy(
                            ResolutionStrategy(
                                cameraResolution,
                                ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                            )
                        )
                        analysisBuilder.setResolutionSelector(selector.build()).build()
                    }
                }

                displayManager.registerDisplayListener(
                    displayListener, null,
                )
            }

            val analysis = analysisBuilder.build().apply { setAnalyzer(executor, captureOutput) }

            try {
                camera = cameraProvider?.bindToLifecycle(
                    activity as LifecycleOwner,
                    cameraPosition,
                    preview,
                    analysis
                )
                cameraSelector = cameraPosition
            } catch(exception: Exception) {
                mobileScannerErrorCallback(NoCamera())

                return@addListener
            }

            camera?.let {
                // Register the torch listener
                it.cameraInfo.torchState.observe(activity as LifecycleOwner) { state ->
                    // TorchState.OFF = 0; TorchState.ON = 1
                    torchStateCallback(state)
                }

                // Register the zoom scale listener
                it.cameraInfo.zoomState.observe(activity) { state ->
                    zoomScaleStateCallback(state.linearZoom.toDouble())
                }

                // Enable torch if provided
                if (it.cameraInfo.hasFlashUnit()) {
                    it.cameraControl.enableTorch(torch)
                }
            }

            val resolution = analysis.resolutionInfo!!.resolution
            val width = resolution.width.toDouble()
            val height = resolution.height.toDouble()
            val sensorRotationDegrees = camera?.cameraInfo?.sensorRotationDegrees ?: 0
            val portrait = sensorRotationDegrees % 180 == 0
            val cameraDirection = getCameraLensFacing(camera)

            // Start with 'unavailable' torch state.
            var currentTorchState: Int = -1

            camera?.cameraInfo?.let {
                if (!it.hasFlashUnit()) {
                    return@let
                }

                currentTorchState = it.torchState.value ?: -1
            }

            deviceOrientationListener.start()

            mobileScannerStartedCallback(
                MobileScannerStartParameters(
                    if (portrait) width else height,
                    if (portrait) height else width,
                    deviceOrientationListener.getUIOrientation().serialize(),
                    sensorRotationDegrees,
                    surfaceProducer!!.handlesCropAndRotation(),
                    currentTorchState,
                    surfaceProducer!!.id(),
                    numberOfCameras ?: 0,
                    cameraDirection,
                )
            )
        }, executor)

    }

    /**
     * Pause barcode scanning.
     */
    fun pause(force: Boolean = false) {
        if (!force) {
            if (isPaused) {
                throw AlreadyPaused()
            } else if (isStopped()) {
                throw AlreadyStopped()
            }
        }

        deviceOrientationListener.stop()
        pauseCamera()
    }

    /**
     * Stop barcode scanning.
     */
    fun stop(force: Boolean = false) {
        if (!force) {
            if (!isPaused && isStopped()) {
                throw AlreadyStopped()
            }
        }

        deviceOrientationListener.stop()
        releaseCamera()
    }

    private fun pauseCamera() {
        // Pause camera by unbinding all use cases
        cameraProvider?.unbindAll()
        isPaused = true
    }

//    private fun resumeCamera() {
//        // Resume camera by rebinding use cases
//        cameraProvider?.let { provider ->
//            val owner = activity as LifecycleOwner
//            cameraSelector?.let { provider.bindToLifecycle(owner, it, preview) }
//        }
//        isPaused = false
//    }

    private fun releaseCamera() {
        if (displayListener != null) {
            val displayManager = activity.applicationContext.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager

            displayManager.unregisterDisplayListener(displayListener)
            displayListener = null
        }

        val owner = activity as LifecycleOwner
        // Release the camera observers first.
        camera?.cameraInfo?.let {
            it.torchState.removeObservers(owner)
            it.zoomState.removeObservers(owner)
            it.cameraState.removeObservers(owner)
        }

        // Unbind the camera use cases, the preview is a use case.
        // The camera will be closed when the last use case is unbound.
        cameraProvider?.unbindAll()

        // Release the surface for the preview.
        surfaceProducer?.release()
        surfaceProducer = null

        // Release the scanner.
        scanner?.close()
        scanner = null
        lastScanned = null
        synchronized(retainedFrameLock) {
            retentionSessionActive = false
            retentionSessionId += 1
            retentionInProgress = false
            clearRetainedFrameLocked()
        }
    }

    private fun isStopped() = camera == null && preview == null

    /**
     * Toggles the flash light on or off.
     */
    fun toggleTorch() {
        camera?.let {
            if (!it.cameraInfo.hasFlashUnit()) {
                return@let
            }

            when(it.cameraInfo.torchState.value) {
                TorchState.OFF -> it.cameraControl.enableTorch(true)
                TorchState.ON -> it.cameraControl.enableTorch(false)
            }
        }
    }

    /**
     * Inverts the image colours respecting the alpha channel
     */
    @ExperimentalGetImage
    fun invertInputImage(imageProxy: ImageProxy): InputImage {
        val image = imageProxy.image ?: throw IllegalArgumentException("Image is null")

        // Convert YUV_420_888 image to RGB Bitmap
        val bitmap = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
        try {
            val imageFormat = YuvToRgbConverter(activity.applicationContext)
            imageFormat.yuvToRgb(image, bitmap)

            // Create an inverted bitmap
            val invertedBitmap = invertBitmapColors(bitmap)
            imageFormat.release()

            return InputImage.fromBitmap(invertedBitmap, imageProxy.imageInfo.rotationDegrees)
        } finally {
            // Release resources
            bitmap.recycle() // Free up bitmap memory
            imageProxy.close() // Close ImageProxy
        }
    }

    // Efficiently invert bitmap colors using ColorMatrix
    private fun invertBitmapColors(bitmap: Bitmap): Bitmap {
        val colorMatrix = ColorMatrix().apply {
            set(floatArrayOf(
                -1f, 0f, 0f, 0f, 255f,  // Red
                0f, -1f, 0f, 0f, 255f,  // Green
                0f, 0f, -1f, 0f, 255f,  // Blue
                0f, 0f, 0f, 1f, 0f      // Alpha
            ))
        }
        val paint = Paint().apply { colorFilter = ColorMatrixColorFilter(colorMatrix) }

        val invertedBitmap = Bitmap.createBitmap(bitmap.width, bitmap.height, bitmap.config!!)
        val canvas = Canvas(invertedBitmap)
        canvas.drawBitmap(bitmap, 0f, 0f, paint)

        return invertedBitmap
    }

    /**
     * Analyze a single image.
     */
    fun analyzeImage(
        image: Uri,
        scannerOptions: BarcodeScannerOptions?,
        onSuccess: AnalyzerSuccessCallback,
        onError: AnalyzerErrorCallback) {
        val inputImage: InputImage

        try {
            inputImage = InputImage.fromFilePath(activity, image)
        } catch (error: IOException) {
            onError(MobileScannerErrorCodes.ANALYZE_IMAGE_NO_VALID_IMAGE_ERROR_MESSAGE)

            return
        }

        // Use a short lived scanner instance, which is closed when the analysis is done.
        val barcodeScanner: BarcodeScanner = barcodeScannerFactory(scannerOptions)

        barcodeScanner.process(inputImage).addOnSuccessListener { barcodes ->
            val barcodeMap = barcodes.map { barcode -> barcode.data }

            onSuccess(barcodeMap)
        }.addOnFailureListener { e ->
            onError(e.localizedMessage ?: e.toString())
        }.addOnCompleteListener {
            barcodeScanner.close()
        }
    }

    /**
     * Set the zoom rate of the camera.
     */
    fun setScale(scale: Double) {
        if (scale > 1.0 || scale < 0) throw ZoomNotInRange()
        if (camera == null) throw ZoomWhenStopped()
        camera?.cameraControl?.setLinearZoom(scale.toFloat())
    }

    fun setZoomRatio(zoomRatio: Double) {
        if (camera == null) throw ZoomWhenStopped()
        camera?.cameraControl?.setZoomRatio(zoomRatio.toFloat())
    }

    /**
     * Reset the zoom rate of the camera.
     */
    fun resetScale() {
        if (camera == null) throw ZoomWhenStopped()
        camera?.cameraControl?.setZoomRatio(1f)
    }

    /**
     * Dispose of this scanner instance.
     */
    fun dispose() {
        if (isStopped()) {
            synchronized(retainedFrameLock) {
                retentionSessionActive = false
                retentionSessionId += 1
                retentionInProgress = false
                clearRetainedFrameLocked()
            }
            return
        }

        stop() // Defer to the stop method, which disposes all resources anyway.
    }
}
