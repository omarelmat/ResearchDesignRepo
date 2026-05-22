import 'dart:math';
import 'package:image/image.dart' as img;

class CrackMeasurement {
  final double widthMm;
  final double lengthMm;
  final String depthCategory;
  final String depthDescription;
  final double coveragePercent;
  final bool isAreaDefect;
  /// Normalised bounding box (0.0–1.0) in image space — use to draw overlay
  final double boxLeft, boxTop, boxRight, boxBottom;
  /// Elongation Index = lengthPx / widthPx — distance-independent crack shape metric.
  /// > 5 = linear structural crack, 2-5 = spreading, < 2 = area defect.
  final double elongationIndex;
  /// Severity Score 0-100 — novel metric combining coverage + depth classification.
  /// Distance-independent. Higher = more severe.
  final double severityScore;

  const CrackMeasurement({
    required this.widthMm,
    required this.lengthMm,
    required this.depthCategory,
    required this.depthDescription,
    required this.coveragePercent,
    required this.isAreaDefect,
    required this.boxLeft,
    required this.boxTop,
    required this.boxRight,
    required this.boxBottom,
    this.elongationIndex = 1.0,
    this.severityScore   = 0.0,
  });

  String get widthDisplay {
    if (widthMm >= 10.0) return '${(widthMm / 10).toStringAsFixed(1)} cm';
    return '${widthMm.toStringAsFixed(1)} mm';
  }

  String get lengthDisplay {
    if (lengthMm >= 10.0) return '${(lengthMm / 10).toStringAsFixed(1)} cm';
    return '${lengthMm.toStringAsFixed(1)} mm';
  }

  String get coverageDisplay => '${coveragePercent.toStringAsFixed(1)}%';

  /// Elongation label for display
  String get elongationLabel {
    if (elongationIndex > 5)   return 'Linear — structural crack';
    if (elongationIndex > 2)   return 'Spreading crack';
    return 'Area defect';
  }

  /// Severity label for display
  String get severityLabel {
    if (severityScore >= 75) return 'Critical';
    if (severityScore >= 50) return 'High';
    if (severityScore >= 25) return 'Moderate';
    return 'Low';
  }
}

class CrackMeasurementHelper {
  /// At ~30 cm, 224 px ≈ 400 mm → 0.56 px/mm
  static const double pixelsPerMm    = 0.56;
  static const int    windowRadius   = 10;  // 21×21 adaptive window
  static const double localDelta     = 18.0; // px must be this much darker than local mean
  static const int    dilateRadius   = 1;   // connect fragmented crack pixels
  static const int    minSize        = 15;

  static CrackMeasurement? measure(img.Image image) {
    final w = image.width, h = image.height;
    final gray = img.grayscale(image);

    // ── 1. Integral image for fast local mean ────────────────────────────
    final intg = _buildIntegral(gray, w, h);

    // ── 2. Adaptive local threshold mask ────────────────────────────────
    final mask = _adaptiveMask(gray, intg, w, h);

    // ── 3. Dilate to connect fragmented crack pixels ─────────────────────
    final dilated = _dilate(mask, w, h, dilateRadius);

    // ── 4. Connected components ──────────────────────────────────────────
    final components = _findComponents(dilated, w, h);
    if (components.isEmpty) return null;

    // ── 5. Pick best (most elongated) component ──────────────────────────
    final best = components.reduce(
        (a, b) => _score(a) >= _score(b) ? a : b);
    if (best.length < minSize) return null;

    return _computeMeasurement(best, w * h, w, h);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal helpers (also used by HeatmapHelper via static methods)
  // ─────────────────────────────────────────────────────────────────────────

  static List<List<int>> _buildIntegral(img.Image gray, int w, int h) {
    final intg = List.generate(h + 1, (_) => List.filled(w + 1, 0));
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        intg[y + 1][x + 1] = gray.getPixel(x, y).r.toInt()
            + intg[y][x + 1]
            + intg[y + 1][x]
            - intg[y][x];
      }
    }
    return intg;
  }

  static List<List<bool>> _adaptiveMask(
      img.Image gray, List<List<int>> intg, int w, int h) {
    final r = windowRadius;
    return List.generate(h, (y) => List.generate(w, (x) {
      final x1 = max(0, x - r), y1 = max(0, y - r);
      final x2 = min(w, x + r + 1), y2 = min(h, y + r + 1);
      final area = (x2 - x1) * (y2 - y1);
      final sum  = intg[y2][x2] - intg[y1][x2]
                 - intg[y2][x1] + intg[y1][x1];
      final localMean = sum / area;
      return gray.getPixel(x, y).r.toDouble() < localMean - localDelta;
    }));
  }

  static List<List<bool>> _dilate(
      List<List<bool>> mask, int w, int h, int r) {
    final out = List.generate(h, (_) => List.filled(w, false));
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        outer:
        for (int dy = -r; dy <= r; dy++) {
          for (int dx = -r; dx <= r; dx++) {
            final ny = y + dy, nx = x + dx;
            if (ny >= 0 && ny < h && nx >= 0 && nx < w && mask[ny][nx]) {
              out[y][x] = true;
              break outer;
            }
          }
        }
      }
    }
    return out;
  }

  static List<List<_Pt>> _findComponents(
      List<List<bool>> mask, int w, int h) {
    final labels = List.generate(h, (_) => List.filled(w, -1));
    final result = <List<_Pt>>[];
    int numC = 0;

    for (int sy = 0; sy < h; sy++) {
      for (int sx = 0; sx < w; sx++) {
        if (!mask[sy][sx] || labels[sy][sx] != -1) continue;
        final pts = <_Pt>[];
        final stack = <int>[sy * w + sx];
        labels[sy][sx] = numC;
        while (stack.isNotEmpty) {
          final idx = stack.removeLast();
          final cx = idx % w, cy = idx ~/ w;
          pts.add(_Pt(cx, cy));
          for (final off in [-w, w, -1, 1]) {
            final ni = idx + off;
            if (ni < 0 || ni >= w * h) continue;
            final nx = ni % w, ny = ni ~/ w;
            if ((off == -1 && cx == 0) || (off == 1 && cx == w - 1)) continue;
            if (mask[ny][nx] && labels[ny][nx] == -1) {
              labels[ny][nx] = numC;
              stack.add(ni);
            }
          }
        }
        result.add(pts);
        numC++;
      }
    }
    return result;
  }

  static double _score(List<_Pt> pts) {
    if (pts.length < minSize) return 0;
    int minX = 9999, maxX = 0, minY = 9999, maxY = 0;
    for (final p in pts) {
      if (p.x < minX) minX = p.x; if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y; if (p.y > maxY) maxY = p.y;
    }
    final bW = (maxX - minX).toDouble();
    final bH = (maxY - minY).toDouble();
    final long  = max(bW, bH);
    final short = min(bW, bH) + 0.001;
    return (long / short) * log(pts.length.toDouble());
  }

  static CrackMeasurement _computeMeasurement(
      List<_Pt> pts, int totalPixels, int imgW, int imgH) {
    final n  = pts.length.toDouble();
    final cx = pts.fold<int>(0, (s, p) => s + p.x) / n;
    final cy = pts.fold<int>(0, (s, p) => s + p.y) / n;

    double cxx = 0, cyy = 0, cxy = 0;
    for (final p in pts) {
      final dx = p.x - cx, dy = p.y - cy;
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
    for (final p in pts) {
      final dx = p.x - cx, dy = p.y - cy;
      final pL = dx * evx + dy * evy;
      final pW = dx * pvx + dy * pvy;
      if (pL < minL) minL = pL; if (pL > maxL) maxL = pL;
      if (pW < minW) minW = pW; if (pW > maxW) maxW = pW;
    }

    final lengthPx    = maxL - minL;
    final widthPx     = maxW - minW;
    final aspect      = widthPx > 0 ? lengthPx / widthPx : 1.0;
    final isAreaDefect = aspect < 2.0;
    final widthMm     = widthPx  / pixelsPerMm;
    final lengthMm    = lengthPx / pixelsPerMm;
    final coverage    = (pts.length / totalPixels) * 100.0;

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

    // Bounding box normalised to [0,1] in image space
    final bLeft   = (pts.map((p) => p.x).reduce(min) / imgW).clamp(0.0, 1.0);
    final bTop    = (pts.map((p) => p.y).reduce(min) / imgH).clamp(0.0, 1.0);
    final bRight  = (pts.map((p) => p.x).reduce(max) / imgW).clamp(0.0, 1.0);
    final bBottom = (pts.map((p) => p.y).reduce(max) / imgH).clamp(0.0, 1.0);

    return CrackMeasurement(
      widthMm: widthMm, lengthMm: lengthMm,
      depthCategory: cat, depthDescription: desc,
      coveragePercent: coverage, isAreaDefect: isAreaDefect,
      boxLeft: bLeft, boxTop: bTop, boxRight: bRight, boxBottom: bBottom,
    );
  }
}

class _Pt { final int x, y; const _Pt(this.x, this.y); }