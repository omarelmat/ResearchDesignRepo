import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'crack_measurement_helper.dart';

/// Loads the classifier weights and computes Class Activation Maps (CAM)
/// from the dual-output TFLite model's feature maps.
class CamHelper {
  static const int _featureH   = 7;
  static const int _featureW   = 7;
  static const int _featureC   = 1280;
  static const int _numClasses = 7;

  /// Classifier weights: shape [7][1280]
  late final List<List<double>> _weights;
  /// Classifier bias: shape [7]
  late final List<double> _bias;

  bool _loaded = false;

  /// Call once at app start.
  Future<void> loadWeights() async {
    if (_loaded) return;
    final bytes = await rootBundle.load('assets/models/cam_weights.bin');
    final floats = bytes.buffer.asFloat32List();
    // Layout: weights[7×1280] then bias[7]
    _weights = List.generate(_numClasses, (c) =>
        List.generate(_featureC, (k) => floats[c * _featureC + k].toDouble()));
    _bias = List.generate(_numClasses, (c) => floats[_numClasses * _featureC + c].toDouble());
    _loaded = true;
  }

  /// Compute 7×7 normalised CAM for the predicted class.
  /// [featureMap]: flat list of length 7×7×1280 from TFLite output.
  /// Returns null if weights not loaded or map is empty.
  List<List<double>>? computeCAM(List<double> featureMap, int predClass) {
    if (!_loaded || featureMap.length != _featureH * _featureW * _featureC) {
      return null;
    }
    final w = _weights[predClass];

    final cam = List.generate(_featureH, (y) =>
        List.generate(_featureW, (x) {
          double val = _bias[predClass];
          final base = y * _featureW * _featureC + x * _featureC;
          for (int k = 0; k < _featureC; k++) {
            val += featureMap[base + k] * w[k];
          }
          return val;
        }));

    // ReLU + normalise to [0, 1]
    double maxVal = double.negativeInfinity;
    for (final row in cam) for (final v in row) if (v > maxVal) maxVal = v;
    if (maxVal <= 0) return List.generate(_featureH, (_) => List.filled(_featureW, 0.0));

    return cam.map((row) => row.map((v) {
      final relu = v > 0 ? v : 0.0;
      return relu / maxVal;
    }).toList()).toList();
  }

  /// Bilinear upscale of 7×7 CAM to [targetSize]×[targetSize].
  static List<List<double>> upscale(List<List<double>> cam, int targetSize) {
    final s = cam.length.toDouble();
    return List.generate(targetSize, (y) =>
        List.generate(targetSize, (x) {
          final sy = (y / targetSize) * s;
          final sx = (x / targetSize) * s;
          final y0 = sy.floor().clamp(0, cam.length - 1);
          final y1 = (y0 + 1).clamp(0, cam.length - 1);
          final x0 = sx.floor().clamp(0, cam[0].length - 1);
          final x1 = (x0 + 1).clamp(0, cam[0].length - 1);
          final wy = sy - y0, wx = sx - x0;
          return (1 - wy) * (1 - wx) * cam[y0][x0]
               + (1 - wy) * wx       * cam[y0][x1]
               + wy       * (1 - wx) * cam[y1][x0]
               + wy       * wx       * cam[y1][x1];
        }));
  }

  /// Get normalised bounding box [left,top,right,bottom] (0–1) of high-attention region.
  static (double, double, double, double)? getBoundingBox(
      List<List<double>> cam, {double threshold = 0.15}) {
    // Find the maximum attention value in the CAM
    double maxVal = 0;
    for (final row in cam) {
      for (final v in row) {
        if (v > maxVal) maxVal = v;
      }
    }
    if (maxVal <= 0) return null;

    // Use 50% of max for tight box around the core defect region
    // This gives a much tighter box than a fixed threshold
    final tightThreshold = maxVal * 0.50;

    int minY = cam.length, maxY = -1, minX = cam[0].length, maxX = -1;
    for (int y = 0; y < cam.length; y++) {
      for (int x = 0; x < cam[y].length; x++) {
        if (cam[y][x] >= tightThreshold) {
          if (y < minY) minY = y; if (y > maxY) maxY = y;
          if (x < minX) minX = x; if (x > maxX) maxX = x;
        }
      }
    }
    if (maxY < 0 || maxX < 0) return null;
    final s = cam.length.toDouble();
    return (minX / s, minY / s, (maxX + 1) / s, (maxY + 1) / s);
  }

  /// Compute Elongation Index and Severity Score directly from CAM.
  /// These are always available — no PCA or measurement needed.
  static Map<String, double> metricsFromCAM(
      List<List<double>> cam, double confidence) {
    // Find max value
    double maxVal = 0;
    for (final row in cam) {
      for (final v in row) { if (v > maxVal) maxVal = v; }
    }
    if (maxVal <= 0) return {'elongation': 1.0, 'severity': 0.0, 'coverage': 0.0};

    // Coverage — % of cells above 15% of max
    final thresh15 = maxVal * 0.15;
    int hotPixels = 0;
    for (final row in cam) {
      for (final v in row) { if (v >= thresh15) hotPixels++; }
    }
    final totalCells = cam.length * cam[0].length;
    final coverage = (hotPixels / totalCells) * 100.0;

    // Elongation from bounding box of core region (50% of max)
    final bb = getBoundingBox(cam);
    double elongation = 1.0;
    if (bb != null) {
      final bw = (bb.$3 - bb.$1).clamp(0.01, 1.0);
      final bh = (bb.$4 - bb.$2).clamp(0.01, 1.0);
      elongation = bw > bh ? bw / bh : bh / bw;
    }

    // Severity — coverage + confidence + elongation contribution
    final coverageScore = (coverage.clamp(0.0, 100.0) / 100.0) * 40.0;
    final confidenceScore = confidence * 30.0;
    final elongScore = (elongation.clamp(1.0, 8.0) / 8.0) * 30.0;
    final severity = (coverageScore + confidenceScore + elongScore).clamp(0.0, 100.0);

    return {
      'elongation': elongation,
      'severity':   severity,
      'coverage':   coverage,
    };
  }

  /// Derive crack measurements directly from the CAM attention map.
  /// This replaces pixel-thresholding — the model tells us where to measure.
  static CrackMeasurement? measureFromCAM(
      List<List<double>> cam7x7, {
        double threshold = 0.35,
        double pixelsPerMm = 0.56, // default: 224px at ~30cm = 400mm
      }) {
    const int targetSize = 224;

    // Upscale CAM to 224×224
    final camLarge = upscale(cam7x7, targetSize);

    // Collect high-attention pixels
    final List<double> xs = [], ys = [];
    for (int y = 0; y < targetSize; y++) {
      for (int x = 0; x < targetSize; x++) {
        if (camLarge[y][x] >= threshold) {
          xs.add(x.toDouble());
          ys.add(y.toDouble());
        }
      }
    }

    if (xs.length < 20) return null;

    final coveragePercent = (xs.length / (targetSize * targetSize)) * 100.0;

    // PCA on attention pixels
    final n  = xs.length.toDouble();
    final cx = xs.reduce((a, b) => a + b) / n;
    final cy = ys.reduce((a, b) => a + b) / n;

    double cxx = 0, cyy = 0, cxy = 0;
    for (int i = 0; i < xs.length; i++) {
      final dx = xs[i] - cx, dy = ys[i] - cy;
      cxx += dx * dx; cyy += dy * dy; cxy += dx * dy;
    }
    cxx /= n; cyy /= n; cxy /= n;

    final trace  = cxx + cyy;
    final det    = cxx * cyy - cxy * cxy;
    final disc   = sqrt(max(0.0, (trace * trace / 4) - det));
    final lam1   = trace / 2 + disc;

    double evx, evy;
    if (cxy.abs() > 1e-6) { evx = lam1 - cyy; evy = cxy; }
    else                   { evx = 1.0; evy = 0.0; }
    final el = sqrt(evx * evx + evy * evy);
    evx /= el; evy /= el;
    final pvx = -evy, pvy = evx;

    double minL = 1e9, maxL = -1e9, minW = 1e9, maxW = -1e9;
    for (int i = 0; i < xs.length; i++) {
      final dx = xs[i] - cx, dy = ys[i] - cy;
      final pL = dx * evx + dy * evy;
      final pW = dx * pvx + dy * pvy;
      if (pL < minL) minL = pL; if (pL > maxL) maxL = pL;
      if (pW < minW) minW = pW; if (pW > maxW) maxW = pW;
    }

    final lengthPx    = maxL - minL;
    final widthPx     = maxW - minW;
    final aspectRatio = widthPx > 0 ? lengthPx / widthPx : 1.0;
    final isAreaDefect = aspectRatio < 2.0;
    final widthMm     = widthPx  / pixelsPerMm;
    final lengthMm    = lengthPx / pixelsPerMm;

    // Normalised bounding box
    final allX = xs, allY = ys;
    final bLeft   = (allX.reduce(min) / targetSize).clamp(0.0, 1.0);
    final bTop    = (allY.reduce(min) / targetSize).clamp(0.0, 1.0);
    final bRight  = (allX.reduce(max) / targetSize).clamp(0.0, 1.0);
    final bBottom = (allY.reduce(max) / targetSize).clamp(0.0, 1.0);

    String cat, desc;
    if (isAreaDefect) {
      cat = 'Area Defect';
      desc = 'Large surface defect — spalling or delamination';
    } else if (widthMm < 0.2) {
      cat = 'Hairline';
      desc = 'Surface only — cosmetic, no structural concern';
    } else if (widthMm < 1.0) {
      cat = 'Shallow';
      desc = 'Minor depth — monitor and seal with flexible filler';
    } else if (widthMm < 3.0) {
      cat = 'Moderate';
      desc = 'Penetrating — patch with mortar or epoxy injection';
    } else {
      cat = 'Deep / Structural';
      desc = 'Structural concern — professional assessment required';
    }

    // ── Elongation Index (distance-independent) ─────────────────────────
    // Ratio of PCA length to width — characterises crack morphology
    final elongationIndex = widthPx > 0 ? lengthPx / widthPx : 1.0;

    // ── Severity Score 0-100 (distance-independent) ──────────────────────
    // Combines: coverage (how much area) + depth (how serious)
    // Coverage contribution: log scale so small cracks still register
    final coverageScore = (coveragePercent.clamp(0.0, 20.0) / 20.0) * 40.0;
    // Depth contribution: hairline=10, shallow=25, moderate=50, deep=75, area=60
    final depthScore = cat == 'Hairline'      ? 10.0
                     : cat == 'Shallow'       ? 25.0
                     : cat == 'Moderate'      ? 50.0
                     : cat == 'Area Defect'   ? 60.0
                     : 75.0; // Deep / Structural
    // Elongation contribution: higher elongation = more structural concern
    final elongScore = (elongationIndex.clamp(1.0, 10.0) / 10.0) * 20.0;
    final severityScore = (coverageScore + (depthScore * 0.5) + elongScore)
        .clamp(0.0, 100.0);

    return CrackMeasurement(
      widthMm: widthMm, lengthMm: lengthMm,
      depthCategory: cat, depthDescription: desc,
      coveragePercent: coveragePercent, isAreaDefect: isAreaDefect,
      boxLeft: bLeft, boxTop: bTop, boxRight: bRight, boxBottom: bBottom,
      elongationIndex: elongationIndex,
      severityScore:   severityScore,
    );
  }

  /// Generate a jet-colormap heatmap overlay PNG from [source] + CAM.
  /// Returns PNG bytes or null.
  static Uint8List? generateOverlay(Uint8List sourceJpeg, List<List<double>> cam7x7) {
    try {
      final source = img.decodeImage(sourceJpeg);
      if (source == null) return null;
      final w = source.width, h = source.height;

      // Upscale CAM to image dimensions
      final camLarge = upscale(cam7x7, max(w, h));

      final out = source.clone();

      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final val = camLarge[y.clamp(0, camLarge.length - 1)]
                               [x.clamp(0, camLarge[0].length - 1)];
          if (val < 0.15) continue; // leave low-attention pixels untouched

          // Jet colormap: blue→cyan→green→yellow→red
          final (jr, jg, jb) = _jet(val);

          final orig = out.getPixel(x, y);
          final alpha = (val * 0.7).clamp(0.0, 0.7);
          out.setPixelRgba(x, y,
            ((orig.r.toInt() * (1 - alpha)) + (jr * 255 * alpha)).toInt().clamp(0, 255),
            ((orig.g.toInt() * (1 - alpha)) + (jg * 255 * alpha)).toInt().clamp(0, 255),
            ((orig.b.toInt() * (1 - alpha)) + (jb * 255 * alpha)).toInt().clamp(0, 255),
            255);
        }
      }

      // Draw bounding box
      final bb = getBoundingBox(cam7x7);
      if (bb != null) {
        final (bl, bt, br, bb2) = bb;
        _drawRect(out,
          (bl * w).round(), (bt * h).round(),
          (br * w).round(), (bb2 * h).round(),
          255, 255, 0);
      }

      return Uint8List.fromList(img.encodePng(out));
    } catch (_) {
      return null;
    }
  }

  // Jet colormap: val [0,1] → (r,g,b) [0,1]
  static (double, double, double) _jet(double v) {
    final r = (1.5 - (4 * (v - 0.75)).abs()).clamp(0.0, 1.0);
    final g = (1.5 - (4 * (v - 0.50)).abs()).clamp(0.0, 1.0);
    final b = (1.5 - (4 * (v - 0.25)).abs()).clamp(0.0, 1.0);
    return (r, g, b);
  }

  static void _drawRect(img.Image im, int x1, int y1, int x2, int y2,
      int r, int g, int b) {
    for (int x = x1; x <= x2; x++) {
      _sp(im, x, y1, r, g, b); _sp(im, x, y1+1, r, g, b);
      _sp(im, x, y2, r, g, b); _sp(im, x, y2-1, r, g, b);
    }
    for (int y = y1; y <= y2; y++) {
      _sp(im, x1, y, r, g, b); _sp(im, x1+1, y, r, g, b);
      _sp(im, x2, y, r, g, b); _sp(im, x2-1, y, r, g, b);
    }
  }

  static void _sp(img.Image im, int x, int y, int r, int g, int b) {
    if (x >= 0 && x < im.width && y >= 0 && y < im.height) {
      im.setPixelRgba(x, y, r, g, b, 255);
    }
  }
}