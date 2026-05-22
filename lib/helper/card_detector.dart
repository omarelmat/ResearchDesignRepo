import 'dart:math';
import 'package:image/image.dart' as img;

/// Result of a credit card detection attempt.
class CardDetectionResult {
  /// True if a card was confidently found.
  final bool found;
  /// Computed scale: pixels per millimetre from the detected card.
  final double pixelsPerMm;
  /// Normalised bounding box of detected card (0–1).
  final double left, top, right, bottom;
  /// Confidence score (0–1).
  final double confidence;

  const CardDetectionResult({
    required this.found,
    required this.pixelsPerMm,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.confidence,
  });

  static const CardDetectionResult notFound = CardDetectionResult(
    found: false, pixelsPerMm: 0.56,
    left: 0, top: 0, right: 0, bottom: 0, confidence: 0,
  );
}

/// Detects a standard credit card in an image and computes the
/// pixels-per-mm scale factor from it.
///
/// Standard credit card: 85.6 mm × 54.0 mm  (ISO/IEC 7810 ID-1)
/// Aspect ratio: 1.585
class CardDetector {
  static const double cardWidthMm  = 85.6;
  static const double cardHeightMm = 54.0;
  static const double cardAspect   = cardWidthMm / cardHeightMm; // 1.585

  /// Detect a credit card in [image].
  /// Returns [CardDetectionResult.notFound] when no card is confidently found.
  static CardDetectionResult detect(img.Image image) {
    final w = image.width;
    final h = image.height;
    final gray = img.grayscale(image);

    // ── 1. Sobel edge magnitude ─────────────────────────────────────────
    final hEdgeRow = List.filled(h, 0.0); // horizontal edge strength per row
    final vEdgeCol = List.filled(w, 0.0); // vertical   edge strength per col

    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final tl = gray.getPixel(x-1, y-1).r.toDouble();
        final t  = gray.getPixel(x,   y-1).r.toDouble();
        final tr = gray.getPixel(x+1, y-1).r.toDouble();
        final l  = gray.getPixel(x-1, y  ).r.toDouble();
        final r  = gray.getPixel(x+1, y  ).r.toDouble();
        final bl = gray.getPixel(x-1, y+1).r.toDouble();
        final b  = gray.getPixel(x,   y+1).r.toDouble();
        final br = gray.getPixel(x+1, y+1).r.toDouble();

        // Gx — responds to vertical edges (left/right card borders)
        final gx = (-tl - 2*l - bl + tr + 2*r + br).abs();
        // Gy — responds to horizontal edges (top/bottom card borders)
        final gy = (-tl - 2*t - tr + bl + 2*b + br).abs();

        hEdgeRow[y] += gy; // horizontal edge contributes to row profile
        vEdgeCol[x] += gx; // vertical   edge contributes to col profile
      }
    }

    // ── 2. Find top-2 peaks in each profile ──────────────────────────────
    // These correspond to the 4 card borders.
    final hPeaks = _topTwoPeaks(hEdgeRow, minGap: h ~/ 8);
    final vPeaks = _topTwoPeaks(vEdgeCol, minGap: w ~/ 8);

    if (hPeaks.length < 2 || vPeaks.length < 2) {
      return CardDetectionResult.notFound;
    }

    final y1 = hPeaks[0], y2 = hPeaks[1];
    final x1 = vPeaks[0], x2 = vPeaks[1];

    final cardH = (y2 - y1).abs().toDouble();
    final cardW = (x2 - x1).abs().toDouble();

    if (cardH < 4 || cardW < 4) return CardDetectionResult.notFound;

    // ── 3. Aspect ratio check ─────────────────────────────────────────────
    final detectedAspect = cardW / cardH;
    final aspectError    = (detectedAspect - cardAspect).abs() / cardAspect;

    // Accept ±30% deviation to handle slight perspective/tilt
    if (aspectError > 0.30) return CardDetectionResult.notFound;

    // ── 4. Confidence: how strong are the 4 border peaks ─────────────────
    final peakStrength = (hEdgeRow[y1] + hEdgeRow[y2] +
                          vEdgeCol[x1] + vEdgeCol[x2]) /
        4.0;
    final maxPossible = hEdgeRow.reduce(max) + vEdgeCol.reduce(max);
    final confidence  = (peakStrength / (maxPossible / 2.0)).clamp(0.0, 1.0);

    if (confidence < 0.20) return CardDetectionResult.notFound;

    // ── 5. Compute scale ──────────────────────────────────────────────────
    // Use the longer dimension (width) for best accuracy.
    // Aspect ratio correction: if card is tilted, effective pixel width < true width.
    // Simple correction: use sqrt(cardW² + cardH²) / diagonal_mm.
    final cardDiagPx = sqrt(cardW * cardW + cardH * cardH);
    final cardDiagMm = sqrt(cardWidthMm * cardWidthMm + cardHeightMm * cardHeightMm);
    final pixelsPerMm = cardDiagPx / cardDiagMm;

    final minX = min(x1, x2), maxX = max(x1, x2);
    final minY = min(y1, y2), maxY = max(y1, y2);

    return CardDetectionResult(
      found:       true,
      pixelsPerMm: pixelsPerMm,
      left:        minX / w,
      top:         minY / h,
      right:       maxX / w,
      bottom:      maxY / h,
      confidence:  confidence,
    );
  }

  /// Returns indices of the two strongest peaks in [profile] that are at
  /// least [minGap] apart.
  static List<int> _topTwoPeaks(List<double> profile, {required int minGap}) {
    final n = profile.length;
    int peak1Idx = 0;
    for (int i = 1; i < n; i++) {
      if (profile[i] > profile[peak1Idx]) peak1Idx = i;
    }

    int peak2Idx = -1;
    for (int i = 0; i < n; i++) {
      if ((i - peak1Idx).abs() < minGap) continue;
      if (peak2Idx == -1 || profile[i] > profile[peak2Idx]) {
        peak2Idx = i;
      }
    }

    if (peak2Idx == -1) return [peak1Idx];
    return [peak1Idx, peak2Idx];
  }
}