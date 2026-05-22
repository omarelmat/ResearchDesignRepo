import 'package:camera/camera.dart';

enum LightingStatus { tooDark, tooBright, flatLighting, good }
enum SharpnessStatus { blurry, good }
enum DistanceStatus { tooClose, tooFar, unknown, good }

class InspectionGuidance {
  final LightingStatus lighting;
  final SharpnessStatus sharpness;
  final DistanceStatus distance;
  final bool readyToCapture;
  final String primaryMessage;
  final double meanBrightness;
  final double sharpnessScore;

  const InspectionGuidance({
    required this.lighting,
    required this.sharpness,
    required this.distance,
    required this.readyToCapture,
    required this.primaryMessage,
    required this.meanBrightness,
    required this.sharpnessScore,
  });

  static InspectionGuidance unknown() => const InspectionGuidance(
        lighting: LightingStatus.good,
        sharpness: SharpnessStatus.good,
        distance: DistanceStatus.unknown,
        readyToCapture: false,
        primaryMessage: 'Initialising camera…',
        meanBrightness: 128,
        sharpnessScore: 0,
      );
}

class InspectionGuideHelper {
  /// Analyses a CameraImage directly on the Y (luma) plane — no full
  /// colour conversion needed, so this runs in microseconds.
  static InspectionGuidance analyze({
    required CameraImage cameraImage,
    required double? crackCoverage, // from measurement result; null = no crack
  }) {
    final yPlane     = cameraImage.planes[0].bytes;
    final rowStride  = cameraImage.planes[0].bytesPerRow;
    final pixStride  = cameraImage.planes[0].bytesPerPixel ?? 1;
    final w          = cameraImage.width;
    final h          = cameraImage.height;

    // Sample every 8th pixel for speed
    const step = 8;
    double sum = 0, sumSq = 0, lapSumSq = 0;
    int count = 0, lapCount = 0;

    for (int y = step; y < h - step; y += step) {
      for (int x = step; x < w - step; x += step) {
        final idx = y * rowStride + x * pixStride;
        if (idx < 0 || idx >= yPlane.length) continue;
        final v = yPlane[idx].toDouble();
        sum   += v;
        sumSq += v * v;
        count++;

        // Laplacian: 4·center − 4 neighbours
        final iL = y * rowStride + (x - step) * pixStride;
        final iR = y * rowStride + (x + step) * pixStride;
        final iU = (y - step) * rowStride + x * pixStride;
        final iD = (y + step) * rowStride + x * pixStride;
        if (iL >= 0 && iR < yPlane.length && iU >= 0 && iD < yPlane.length) {
          final lap = 4 * v
              - yPlane[iL].toDouble()
              - yPlane[iR].toDouble()
              - yPlane[iU].toDouble()
              - yPlane[iD].toDouble();
          lapSumSq += lap * lap;
          lapCount++;
        }
      }
    }

    if (count == 0) return InspectionGuidance.unknown();

    final meanBrightness = sum / count;
    final variance       = (sumSq / count) - (meanBrightness * meanBrightness);
    final sharpnessScore = lapCount > 0 ? lapSumSq / lapCount : 0.0;

    // ── Lighting ────────────────────────────────────────────────────────────
    LightingStatus lighting;
    if (meanBrightness < 55) {
      lighting = LightingStatus.tooDark;
    } else if (meanBrightness > 215) {
      lighting = LightingStatus.tooBright;
    } else if (variance < 120) {
      lighting = LightingStatus.flatLighting; // no contrast → cracks invisible
    } else {
      lighting = LightingStatus.good;
    }

    // ── Sharpness (Laplacian variance) ──────────────────────────────────────
    // Threshold tuned for 30cm wall shots with a phone camera
    final SharpnessStatus sharpness =
        sharpnessScore < 40 ? SharpnessStatus.blurry : SharpnessStatus.good;

    // ── Distance (from crack coverage %) ────────────────────────────────────
    DistanceStatus distance;
    if (crackCoverage == null) {
      distance = DistanceStatus.unknown;
    } else if (crackCoverage > 25) {
      distance = DistanceStatus.tooClose;
    } else if (crackCoverage < 0.3) {
      distance = DistanceStatus.tooFar;
    } else {
      distance = DistanceStatus.good;
    }

    // ── Ready? ───────────────────────────────────────────────────────────────
    final readyToCapture = lighting == LightingStatus.good &&
        sharpness == SharpnessStatus.good &&
        distance != DistanceStatus.tooClose &&
        distance != DistanceStatus.tooFar;

    // ── Primary guidance message ─────────────────────────────────────────────
    String msg;
    if (lighting == LightingStatus.tooDark) {
      msg = '🔦 Too dark — move to brighter area or turn on torch';
    } else if (lighting == LightingStatus.tooBright) {
      msg = '☀️ Too bright — avoid direct sunlight or strong glare';
    } else if (lighting == LightingStatus.flatLighting) {
      msg = '💡 Low contrast — use angled light to reveal cracks';
    } else if (sharpness == SharpnessStatus.blurry) {
      msg = '📷 Blurry — hold phone steady, brace against your body';
    } else if (distance == DistanceStatus.tooClose) {
      msg = '↔️ Too close — step back to ~30 cm from the wall';
    } else if (distance == DistanceStatus.tooFar) {
      msg = '🔍 Too far — move closer, ~30 cm from the wall';
    } else if (distance == DistanceStatus.unknown) {
      msg = '📐 Hold phone ~30 cm from the wall, parallel to surface';
    } else {
      msg = '✅ Good — tap Capture to record this section';
    }

    return InspectionGuidance(
      lighting:        lighting,
      sharpness:       sharpness,
      distance:        distance,
      readyToCapture:  readyToCapture,
      primaryMessage:  msg,
      meanBrightness:  meanBrightness,
      sharpnessScore:  sharpnessScore,
    );
  }
}