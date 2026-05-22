import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'crack_measurement_helper.dart';

class HeatmapHelper {
  static const double stdMultiplier = 2.0;

  static Uint8List? generateOverlay(Uint8List sourceJpeg) {
    try {
      final source = img.decodeImage(sourceJpeg);
      if (source == null) return null;

      final w = source.width, h = source.height;
      final gray = img.grayscale(source);

      // ── Threshold ────────────────────────────────────────────────────────
      double sum = 0, sumSq = 0;
      final total = (w * h).toDouble();
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final v = gray.getPixel(x, y).r.toDouble();
          sum += v; sumSq += v * v;
        }
      }
      final mean      = sum / total;
      final std       = sqrt((sumSq / total) - (mean * mean));
      final threshold = mean - stdMultiplier * std;
      if (threshold <= 0) return null;

      // ── Build mask ────────────────────────────────────────────────────────
      final mask   = List.generate(h, (y) =>
          List.generate(w, (x) => gray.getPixel(x, y).r.toDouble() < threshold));

      // ── Connected components (DFS) ────────────────────────────────────────
      final labels    = List.generate(h, (_) => List.filled(w, -1));
      final compXs    = <int, List<double>>{};
      final compYs    = <int, List<double>>{};
      int numComps    = 0;

      for (int sy = 0; sy < h; sy++) {
        for (int sx = 0; sx < w; sx++) {
          if (!mask[sy][sx] || labels[sy][sx] != -1) continue;
          final xs = <double>[], ys = <double>[];
          final stack = <int>[sy * w + sx];
          labels[sy][sx] = numComps;
          while (stack.isNotEmpty) {
            final idx = stack.removeLast();
            final cx = idx % w, cy = idx ~/ w;
            xs.add(cx.toDouble()); ys.add(cy.toDouble());
            for (final off in [-w, w, -1, 1]) {
              final ni = idx + off;
              if (ni < 0 || ni >= w * h) continue;
              final nx = ni % w, ny = ni ~/ w;
              if ((off == -1 && cx == 0) || (off == 1 && cx == w - 1)) continue;
              if (mask[ny][nx] && labels[ny][nx] == -1) {
                labels[ny][nx] = numComps;
                stack.add(ni);
              }
            }
          }
          compXs[numComps] = xs;
          compYs[numComps] = ys;
          numComps++;
        }
      }

      if (numComps == 0) return null;

      // ── Pick the best (most elongated) component ──────────────────────────
      int bestLabel = -1;
      double bestScore = 0;

      for (int i = 0; i < numComps; i++) {
        final xs = compXs[i]!;
        if (xs.length < 20) continue;
        final ys  = compYs[i]!;
        final bW  = xs.reduce(max) - xs.reduce(min);
        final bH  = ys.reduce(max) - ys.reduce(min);
        final long  = max(bW, bH);
        final short = min(bW, bH) + 0.001;
        final score = (long / short) * log(xs.length.toDouble());
        if (score > bestScore) { bestScore = score; bestLabel = i; }
      }

      if (bestLabel == -1) return null;

      // ── PCA on best component ─────────────────────────────────────────────
      final bxs = compXs[bestLabel]!;
      final bys = compYs[bestLabel]!;
      final n   = bxs.length.toDouble();
      final cx  = bxs.reduce((a, b) => a + b) / n;
      final cy  = bys.reduce((a, b) => a + b) / n;

      double cxx = 0, cyy = 0, cxy = 0;
      for (int i = 0; i < bxs.length; i++) {
        final dx = bxs[i] - cx, dy = bys[i] - cy;
        cxx += dx * dx; cyy += dy * dy; cxy += dx * dy;
      }
      cxx /= n; cyy /= n; cxy /= n;

      final trace   = cxx + cyy;
      final det     = cxx * cyy - cxy * cxy;
      final disc    = sqrt(max(0.0, (trace * trace / 4) - det));
      final lambda1 = trace / 2 + disc;

      double evx, evy;
      if (cxy.abs() > 1e-6) { evx = lambda1 - cyy; evy = cxy; }
      else                   { evx = 1.0; evy = 0.0; }
      final el = sqrt(evx * evx + evy * evy);
      evx /= el; evy /= el;

      final minXb = bxs.reduce(min), maxXb = bxs.reduce(max);
      final minYb = bys.reduce(min), maxYb = bys.reduce(max);
      final halfLen =
          max(maxXb - minXb, maxYb - minYb) / 2.0;

      final ax1 = (cx - evx * halfLen).round().clamp(0, w - 1);
      final ay1 = (cy - evy * halfLen).round().clamp(0, h - 1);
      final ax2 = (cx + evx * halfLen).round().clamp(0, w - 1);
      final ay2 = (cy + evy * halfLen).round().clamp(0, h - 1);

      // ── Draw overlay ──────────────────────────────────────────────────────
      final out = source.clone();

      // 1. ALL dark pixels: faint yellow tint (shows full dark region map)
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          if (mask[y][x]) {
            final orig = out.getPixel(x, y);
            final r = ((orig.r.toInt() * 0.5) + (200 * 0.5)).toInt().clamp(0, 255);
            final g = ((orig.g.toInt() * 0.5) + (180 * 0.5)).toInt().clamp(0, 255);
            final b = ((orig.b.toInt() * 0.5) + (0   * 0.5)).toInt().clamp(0, 255);
            out.setPixelRgba(x, y, r, g, b, 255);
          }
        }
      }

      // 2. Best component: strong red-orange overlay
      for (int i = 0; i < bxs.length; i++) {
        final x = bxs[i].round(), y = bys[i].round();
        if (x >= 0 && x < w && y >= 0 && y < h) {
          final orig = out.getPixel(x, y);
          final r = ((orig.r.toInt() * 0.2) + (255 * 0.8)).toInt().clamp(0, 255);
          final g = ((orig.g.toInt() * 0.2) + (80  * 0.8)).toInt().clamp(0, 255);
          final bv = 0;
          out.setPixelRgba(x, y, r, g, bv, 255);
        }
      }

      // 3. Orange bounding box
      _drawRect(out, minXb.round(), minYb.round(),
          maxXb.round(), maxYb.round(), r: 255, g: 140, b: 0);

      // 4. Yellow PCA axis line
      _drawLine(out, ax1, ay1, ax2, ay2, r: 255, g: 235, b: 0);

      // 5. White centroid dot
      _fillCircle(out, cx.round(), cy.round(), 4, r: 255, g: 255, b: 255);

      return Uint8List.fromList(img.encodePng(out));
    } catch (_) {
      return null;
    }
  }

  static void _drawRect(img.Image image, int x1, int y1, int x2, int y2,
      {required int r, required int g, required int b}) {
    for (int x = x1; x <= x2; x++) {
      for (int t = 0; t < 2; t++) {
        _sp(image, x, y1 + t, r, g, b);
        _sp(image, x, y2 - t, r, g, b);
      }
    }
    for (int y = y1; y <= y2; y++) {
      for (int t = 0; t < 2; t++) {
        _sp(image, x1 + t, y, r, g, b);
        _sp(image, x2 - t, y, r, g, b);
      }
    }
  }

  static void _drawLine(img.Image image, int x1, int y1, int x2, int y2,
      {required int r, required int g, required int b}) {
    int dx = (x2 - x1).abs(), dy = (y2 - y1).abs();
    int sx = x1 < x2 ? 1 : -1, sy = y1 < y2 ? 1 : -1;
    int err = dx - dy, x = x1, y = y1;
    while (true) {
      for (int t = -1; t <= 1; t++) {
        _sp(image, x + t, y, r, g, b);
        _sp(image, x, y + t, r, g, b);
      }
      if (x == x2 && y == y2) break;
      final e2 = 2 * err;
      if (e2 > -dy) { err -= dy; x += sx; }
      if (e2 <  dx) { err += dx; y += sy; }
    }
  }

  static void _fillCircle(img.Image image, int cx, int cy, int radius,
      {required int r, required int g, required int b}) {
    for (int dy = -radius; dy <= radius; dy++) {
      for (int dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dy * dy <= radius * radius) {
          _sp(image, cx + dx, cy + dy, r, g, b);
        }
      }
    }
  }

  static void _sp(img.Image image, int x, int y, int r, int g, int b) {
    if (x >= 0 && x < image.width && y >= 0 && y < image.height) {
      image.setPixelRgba(x, y, r, g, b, 255);
    }
  }
}