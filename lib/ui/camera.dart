import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_classification_mobilenet/helper/image_classification_helper.dart';
import 'package:image_classification_mobilenet/helper/crack_measurement_helper.dart';
import 'package:image_classification_mobilenet/helper/cam_helper.dart';
import 'package:image_classification_mobilenet/helper/inspection_guide_helper.dart';
import 'package:image_classification_mobilenet/image_utils.dart';
import 'package:image_classification_mobilenet/models/inspection_session.dart';
import 'package:image_classification_mobilenet/ui/inspection_report_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.camera});
  final CameraDescription camera;
  @override
  State<StatefulWidget> createState() => CameraScreenState();
}

class CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  late CameraController        cameraController;
  late ImageClassificationHelper imageClassificationHelper;

  Map<String, double>? classification;
  CrackMeasurement?    measurement;
  Rect?                _detectionBox; // normalised 0-1 in preview space
  InspectionGuidance?  guidance;
  CameraImage?         _lastFrame;
  List<double>?        _featureMap;
  int?                 _predClass;
  final double _pixelsPerMm = 0.56; // fixed scale
  bool _isProcessing = false;

  static const _crackLabels = {'minor_crack', 'major_crack'};

  // ── Camera init ─────────────────────────────────────────────────────────
  void initCamera() {
    cameraController = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    cameraController.initialize().then((_) {
      cameraController.startImageStream(imageAnalysis);
      if (mounted) setState(() {});
    });
  }

  // ── Per-frame analysis ───────────────────────────────────────────────────
  Future<void> imageAnalysis(CameraImage cameraImage) async {
    if (_isProcessing) return;
    _isProcessing = true;
    _lastFrame = cameraImage;

    final result =
        await imageClassificationHelper.inferenceCameraFrame(cameraImage);
    classification = result.classification;
    _featureMap    = result.featureMap;
    _predClass     = result.predClass;

    measurement = null;
    _detectionBox = null;
    if (classification != null) {
      final sorted = classification!.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final topLabel = sorted.first.key.toLowerCase().trim();
      final topScore = sorted.first.value;
      if (topScore >= 0.5 && topLabel != 'plain') {
        // CAM-driven measurement — model tells us where AND how big
        if (_featureMap != null) {
          final cam = imageClassificationHelper.camHelper
              .computeCAM(_featureMap!, _predClass!);
          if (cam != null) {
            // Measurements from CAM attention region
            measurement = CamHelper.measureFromCAM(cam, pixelsPerMm: _pixelsPerMm);
            // Bounding box from CAM
            final bb = CamHelper.getBoundingBox(cam);
            if (bb != null) {
              final (l, t, r, b) = bb;
              _detectionBox = Rect.fromLTRB(l, t, r, b);
            }
          }
        }
        // Fallback to pixel-based if CAM unavailable
        measurement ??= _measureFromCameraImage(cameraImage);
      }
    }

    guidance = InspectionGuideHelper.analyze(
      cameraImage:   cameraImage,
      crackCoverage: measurement?.coveragePercent,
    );


    _isProcessing = false;
    if (mounted) setState(() {});
  }

  CrackMeasurement? _measureFromCameraImage(CameraImage cameraImage) {
    try {
      img.Image? converted = ImageUtils.convertCameraImage(cameraImage);
      if (converted == null) return null;
      if (Platform.isAndroid) {
        converted = img.copyRotate(converted, angle: 90);
      }
      return CrackMeasurementHelper.measure(
          img.copyResize(converted, width: 224, height: 224));
    } catch (_) {
      return null;
    }
  }

  // ── Capture current frame into session ───────────────────────────────────
  void _captureFrame() {
    if (_lastFrame == null || classification == null) return;

    final sorted = classification!.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topEntry = sorted.first;

    Uint8List? thumbnail;
    Uint8List? fullImage;
    Uint8List? croppedImage;
    CrackMeasurement? finalMeasurement = measurement;

    try {
      img.Image? converted = ImageUtils.convertCameraImage(_lastFrame!);
      if (converted != null) {
        if (Platform.isAndroid) {
          converted = img.copyRotate(converted, angle: 90);
        }

        // ── Always save the full frame for display in the report ──────────
        final fullResized = img.copyResize(converted, width: 448, height: 448);
        fullImage = Uint8List.fromList(img.encodeJpg(fullResized, quality: 88));
        thumbnail = Uint8List.fromList(
            img.encodeJpg(img.copyResize(fullResized, width: 120, height: 120), quality: 75));

        // ── Crop to detected region for measurements ──────────────────────
        img.Image imageForReport = img.copyResize(converted, width: 448, height: 448);

        if (_detectionBox != null) {
          final bw = imageForReport.width;
          final bh = imageForReport.height;

          // Add 5% padding around the detection box
          const pad = 0.10; // 10% padding to capture full crack extent
          final left   = (((_detectionBox!.left   - pad) * bw).round()).clamp(0, bw - 1);
          final top    = (((_detectionBox!.top    - pad) * bh).round()).clamp(0, bh - 1);
          final right  = (((_detectionBox!.right  + pad) * bw).round()).clamp(left + 1, bw);
          final bottom = (((_detectionBox!.bottom + pad) * bh).round()).clamp(top  + 1, bh);
          final cropW  = right  - left;
          final cropH  = bottom - top;

          if (cropW > 10 && cropH > 10) {
            // Crop to the detected defect region
            imageForReport = img.copyCrop(
              imageForReport,
              x: left, y: top,
              width: cropW, height: cropH,
            );

            // ── Measurement on the tight crop ────────────────────────────
            // The crop covers cropW pixels of the 448px image.
            // Physical width of crop = cropW / _pixelsPerMm  (in mm)
            // When we resize crop to 224px:
            //   new pixelsPerMm = 224 / (cropW / _pixelsPerMm)
            //                   = 224 * _pixelsPerMm / cropW
            final croppedPixelsPerMm = (224.0 * _pixelsPerMm) / cropW;

            // Resize crop to 224×224 for measurement
            final cropFor224 = img.copyResize(
                imageForReport, width: 224, height: 224);

            // Run pixel thresholding on the tight crop —
            // the defect fills most of the frame so detection is clean
            final cropMeasurement = CrackMeasurementHelper.measure(cropFor224);

            if (cropMeasurement != null) {
              // Rebuild measurement with the correct scaled pixelsPerMm
              finalMeasurement = CrackMeasurement(
                widthMm: cropMeasurement.widthMm *
                    (0.56 / croppedPixelsPerMm), // rescale
                lengthMm: cropMeasurement.lengthMm *
                    (0.56 / croppedPixelsPerMm),
                depthCategory:    cropMeasurement.depthCategory,
                depthDescription: cropMeasurement.depthDescription,
                coveragePercent:  cropMeasurement.coveragePercent,
                isAreaDefect:     cropMeasurement.isAreaDefect,
                boxLeft:   0.0,
                boxTop:    0.0,
                boxRight:  1.0,
                boxBottom: 1.0,
              );
            }
          }
        }

        // Encode the (possibly cropped) image
        // Save cropped region for heatmap overlay
        croppedImage = Uint8List.fromList(img.encodeJpg(imageForReport, quality: 90));
      }
    } catch (_) {}

    // ── Always compute metrics from CAM directly ──────────────────────
    // This ensures elongation and severity are always available
    // regardless of whether pixel measurement succeeded
    if (_featureMap != null && _predClass != null) {
      final cam = imageClassificationHelper.camHelper
          .computeCAM(_featureMap!, _predClass!);
      if (cam != null) {
        final metrics = CamHelper.metricsFromCAM(cam, topEntry.value);
        final elong   = metrics['elongation'] ?? 1.0;
        final sev     = metrics['severity']   ?? 0.0;
        final cov     = metrics['coverage']   ?? 0.0;

        // Determine depth category from elongation
        String depthCat, depthDesc;
        if (elong > 5) {
          depthCat  = 'Deep / Structural';
          depthDesc = 'Structural concern — professional assessment required';
        } else if (elong > 2) {
          depthCat  = 'Moderate';
          depthDesc = 'Penetrating — patch with mortar or epoxy injection';
        } else {
          depthCat  = 'Area Defect';
          depthDesc = 'Surface damage — repair surface coating';
        }

        // Merge with any existing measurement or create from CAM metrics
        final existing = finalMeasurement;
        finalMeasurement = CrackMeasurement(
          widthMm:          existing?.widthMm          ?? 0.0,
          lengthMm:         existing?.lengthMm         ?? 0.0,
          depthCategory:    depthCat,
          depthDescription: depthDesc,
          coveragePercent:  cov,
          isAreaDefect:     elong < 2,
          boxLeft:   existing?.boxLeft   ?? 0.0,
          boxTop:    existing?.boxTop    ?? 0.0,
          boxRight:  existing?.boxRight  ?? 1.0,
          boxBottom: existing?.boxBottom ?? 1.0,
          elongationIndex: elong,
          severityScore:   sev,
        );
      }
    }

    InspectionSession.instance.add(CapturedFrame(
      label:          topEntry.key,
      confidence:     topEntry.value,
      measurement:    finalMeasurement,
      timestamp:      DateTime.now(),
      thumbnail:      thumbnail,
      fullImage:      fullImage,
      croppedImage:   croppedImage,
      featureMap:     _featureMap,
      predClass:      _predClass ?? 0,
      allPredictions: classification, // store all 7 scores for top-3 display
    ));

    setState(() {});

    // Brief confirmation snackbar
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        '📸  Section ${InspectionSession.instance.count} captured — '
        '${topEntry.key.replaceAll('_', ' ')} '
        '(${(topEntry.value * 100).toStringAsFixed(0)}%)',
      ),
      duration: const Duration(seconds: 2),
      backgroundColor: Colors.black87,
    ));
  }

  // ── Finish inspection → open report ─────────────────────────────────────
  void _finishInspection() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const InspectionReportScreen()),
    ).then((_) => setState(() {}));
  }

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    initCamera();
    imageClassificationHelper = ImageClassificationHelper();
    imageClassificationHelper.initHelper();
    super.initState();
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.paused:
        cameraController.stopImageStream();
        break;
      case AppLifecycleState.resumed:
        if (!cameraController.value.isStreamingImages) {
          await cameraController.startImageStream(imageAnalysis);
        }
        break;
      default:
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    cameraController.dispose();
    imageClassificationHelper.close();
    super.dispose();
  }

  Widget _cameraWidget(BuildContext context) {
    final camera = cameraController.value;
    final size   = MediaQuery.of(context).size;
    var scale    = size.aspectRatio * camera.aspectRatio;
    if (scale < 1) scale = 1 / scale;
    return Transform.scale(
      scale: scale,
      child: Center(child: CameraPreview(cameraController)),
    );
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final session      = InspectionSession.instance;
    final captureCount = session.count;

    return SafeArea(
      child: Stack(children: [

        // ── Camera feed ────────────────────────────────────────────────────
        SizedBox(
          child: !cameraController.value.isInitialized
              ? Container()
              : _cameraWidget(context),
        ),

        // ── Bounding box overlay ──────────────────────────────────────────
        if (_detectionBox != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _BoundingBoxPainter(
                  box: _detectionBox!,
                  label: classification != null
                      ? (classification!.entries.toList()
                            ..sort((a, b) => b.value.compareTo(a.value)))
                          .first
                          .key
                          .replaceAll('_', ' ')
                      : '',
                  measurement: measurement,
                ),
              ),
            ),
          ),

        // ── Top guidance bar ───────────────────────────────────────────────
        Positioned(
          top: 0, left: 0, right: 0,
          child: Container(
            color: Colors.black.withValues(alpha: 0.60),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              if (guidance != null) ...[
                _guidanceDot(_lightingOk,  '🔆'),
                const SizedBox(width: 6),
                _guidanceDot(_sharpnessOk, '📷'),
                const SizedBox(width: 6),
                _guidanceDot(_distanceOk,  '📏'),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    guidance!.primaryMessage,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Expanded(
                  child: Text('Initialising…',
                      style: TextStyle(color: Colors.white70, fontSize: 11)),
                ),


              // Section counter badge
              if (captureCount > 0)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0x40FFFFFF),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$captureCount ${captureCount == 1 ? 'section' : 'sections'} saved',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                ),
            ]),
          ),
        ),

        // ── Bottom panel ───────────────────────────────────────────────────
        Align(
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [

              // Classification + measurement results
              if (classification != null)
                _ResultsPanel(
                  classification: classification!,
                  measurement:    measurement,
                  crackLabels:    _crackLabels,
                ),

              // Action buttons
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(children: [

                  // ── Capture button ────────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _captureFrame,
                      icon:  const Icon(Icons.camera_alt),
                      label: const Text('Capture Section',
                          style: TextStyle(fontSize: 15,
                              fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: guidance?.readyToCapture == true
                            ? Colors.amber[800]
                            : Colors.grey.shade400,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),

                  // ── "I'm Done" button — appears once ≥1 section captured ──
                  if (captureCount >= 1) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _finishInspection,
                        icon:  const Icon(Icons.check_circle_outline),
                        label: Text(
                          "I'm Done — View Report ($captureCount sections)",
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green[700],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ]),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  // ── Small helpers ─────────────────────────────────────────────────────────
  bool get _lightingOk  => guidance?.lighting  == LightingStatus.good;
  bool get _sharpnessOk => guidance?.sharpness == SharpnessStatus.good;
  bool get _distanceOk  =>
      guidance?.distance == DistanceStatus.good ||
      guidance?.distance == DistanceStatus.unknown;

  Widget _guidanceDot(bool ok, String icon) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 2),
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ok ? Colors.greenAccent : Colors.redAccent,
            ),
          ),
        ],
      );
}

// ── Results panel (extracted widget for clarity) ──────────────────────────
class _ResultsPanel extends StatelessWidget {
  final Map<String, double> classification;
  final CrackMeasurement?   measurement;
  final Set<String>         crackLabels;

  const _ResultsPanel({
    required this.classification,
    required this.measurement,
    required this.crackLabels,
  });

  @override
  Widget build(BuildContext context) {
    const double confidenceThreshold = 0.5;

    final sorted = (classification.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value)))
        .reversed
        .toList();

    final topScore = sorted.first.value;
    final topLabel = sorted.first.key.toLowerCase().trim();

    return Column(children: [

      // Scores
      if (topScore < confidenceThreshold || topLabel == 'plain')
        _row('No defect detected', '–')
      else
        ...sorted
            .where((e) => e.value >= 0.05)
            .take(3)
            .map((e) => _row(
                  e.key.replaceAll('_', ' '),
                  '${(e.value * 100).toStringAsFixed(1)}%',
                  bold: e == sorted.first,
                )),

      // Measurement card
      if (crackLabels.contains(topLabel) && measurement != null) ...[
        const Divider(height: 1, color: Color(0xFFE0E0E0)),
        Container(
          width: double.infinity,
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('📏 Crack Measurements',
                style:
                    TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const Text('approx. at ~30 cm from wall',
                style: TextStyle(fontSize: 10, color: Colors.black38)),
            const SizedBox(height: 6),
            Row(children: [
              _tile('Coverage',  measurement!.coverageDisplay),
              const SizedBox(width: 16),
              _tile('Elongation', measurement!.elongationIndex.toStringAsFixed(1)),
              const SizedBox(width: 16),
              _tile('Severity', '${measurement!.severityScore.toStringAsFixed(0)}/100'),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              _depthBadge(measurement!.depthCategory),
              const SizedBox(width: 8),
              Expanded(
                child: Text(measurement!.depthDescription,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.black54)),
              ),
            ]),
            const SizedBox(height: 6),
          ]),
        ),
      ],

      if (crackLabels.contains(topLabel) && measurement == null)
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: const Row(children: [
            Icon(Icons.straighten, size: 14, color: Colors.grey),
            SizedBox(width: 6),
            Text('Hold steady for measurements…',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
        ),
    ]);
  }

  Widget _row(String label, String value, {bool bold = false}) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: Colors.white,
        child: Row(children: [
          Text(label,
              style: TextStyle(
                  fontWeight:
                      bold ? FontWeight.bold : FontWeight.normal)),
          const Spacer(),
          Text(value,
              style: TextStyle(
                  fontWeight:
                      bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );

  Widget _tile(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.black54)),
          Text(value,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold)),
        ],
      );

  Widget _depthBadge(String category) {
    Color color;
    switch (category) {
      case 'Hairline':    color = Colors.green; break;
      case 'Shallow':     color = Colors.orange; break;
      case 'Moderate':    color = Colors.deepOrange; break;
      case 'Area Defect': color = Colors.purple; break;
      default:            color = Colors.red;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(category,
          style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold)),
    );
  }
}

// ── Bounding box overlay painter ─────────────────────────────────────────────
class _BoundingBoxPainter extends CustomPainter {
  final Rect box;
  final String label;
  final CrackMeasurement? measurement;

  const _BoundingBoxPainter({
    required this.box,
    required this.label,
    required this.measurement,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Map normalised box coords → screen pixels
    final left   = box.left   * size.width;
    final top    = box.top    * size.height;
    final right  = box.right  * size.width;
    final bottom = box.bottom * size.height;
    final rect   = Rect.fromLTRB(left, top, right, bottom);

    // ── Box border ──────────────────────────────────────────────────────────
    final borderPaint = Paint()
      ..color  = const Color(0xFFFF8C00)   // orange
      ..style  = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawRect(rect, borderPaint);

    // ── Corner accents (L-shaped) ───────────────────────────────────────────
    final cornerPaint = Paint()
      ..color  = Colors.white
      ..style  = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    const cl = 14.0; // corner length

    // Top-left
    canvas.drawLine(Offset(left, top + cl), Offset(left, top), cornerPaint);
    canvas.drawLine(Offset(left, top), Offset(left + cl, top), cornerPaint);
    // Top-right
    canvas.drawLine(Offset(right - cl, top), Offset(right, top), cornerPaint);
    canvas.drawLine(Offset(right, top), Offset(right, top + cl), cornerPaint);
    // Bottom-left
    canvas.drawLine(Offset(left, bottom - cl), Offset(left, bottom), cornerPaint);
    canvas.drawLine(Offset(left, bottom), Offset(left + cl, bottom), cornerPaint);
    // Bottom-right
    canvas.drawLine(Offset(right, bottom - cl), Offset(right, bottom), cornerPaint);
    canvas.drawLine(Offset(right, bottom), Offset(right - cl, bottom), cornerPaint);

    // ── Label tag at top-left of box ────────────────────────────────────────
    final tagText = measurement != null
        ? '$label  Sev:${measurement!.severityScore.toStringAsFixed(0)}  E:${measurement!.elongationIndex.toStringAsFixed(1)}'
        : label;

    final tp = TextPainter(
      text: TextSpan(
        text: ' $tagText ',
        style: const TextStyle(
          color:      Colors.white,
          fontSize:   12,
          fontWeight: FontWeight.bold,
          backgroundColor: Color(0xCC000000),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Position tag above the box; clamp so it doesn't go off-screen
    final tagY = (top - tp.height - 2).clamp(0.0, size.height - tp.height);
    tp.paint(canvas, Offset(left, tagY));
  }

  @override
  bool shouldRepaint(_BoundingBoxPainter old) =>
      old.box != box || old.label != label;
}