import 'dart:typed_data';
import 'package:image_classification_mobilenet/helper/crack_measurement_helper.dart';

class CapturedFrame {
  final String label;
  final double confidence;
  final CrackMeasurement? measurement;
  final DateTime timestamp;
  final Uint8List? thumbnail;
  final Uint8List? fullImage;
  final Uint8List? croppedImage;
  final List<double>? featureMap;
  final int predClass;
  /// All 7 class probabilities — used to show top 3 predictions
  final Map<String, double>? allPredictions;

  const CapturedFrame({
    required this.label,
    required this.confidence,
    this.measurement,
    required this.timestamp,
    this.thumbnail,
    this.fullImage,
    this.croppedImage,
    this.featureMap,
    this.predClass = 0,
    this.allPredictions,
  });

  String get displayLabel => label.replaceAll('_', ' ');

  /// Top 3 predictions sorted by confidence descending
  List<MapEntry<String, double>> get topPredictions {
    if (allPredictions == null) return [];
    final sorted = allPredictions!.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(3).where((e) => e.value > 0.05).toList();
  }
}

class InspectionSession {
  static final InspectionSession instance = InspectionSession._();
  InspectionSession._();

  final List<CapturedFrame> frames = [];

  void add(CapturedFrame frame) => frames.add(frame);
  void clear() => frames.clear();
  int get count => frames.length;
  bool get isEmpty => frames.isEmpty;

  // ── Defect counts ─────────────────────────────────────────────────────────
  Map<String, int> get defectCounts {
    final counts = <String, int>{};
    for (final f in frames) {
      counts[f.label] = (counts[f.label] ?? 0) + 1;
    }
    return counts;
  }

  // ── Crack count (minor + major) ───────────────────────────────────────────
  int get crackCount => frames
      .where((f) => f.label == 'minor_crack' || f.label == 'major_crack')
      .length;

  int get majorCrackCount =>
      frames.where((f) => f.label == 'major_crack').length;

  int get minorCrackCount =>
      frames.where((f) => f.label == 'minor_crack').length;

  // ── Overall condition score (0 = perfect, 100 = critical) ─────────────────
  static const Map<String, int> _severity = {
    'plain':       0,
    'algae':       10,
    'stain':       15,
    'peeling':     25,
    'minor_crack': 40,
    'spalling':    50,
    'major_crack': 65,
  };

  double get conditionScore {
    if (frames.isEmpty) return 0;
    final total = frames.fold<int>(
        0, (sum, f) => sum + (_severity[f.label.toLowerCase()] ?? 20));
    final maxPossible = frames.length * 65;
    return (total / maxPossible) * 100;
  }

  String get conditionGrade {
    final s = conditionScore;
    if (s < 15) return 'Excellent';
    if (s < 35) return 'Good';
    if (s < 55) return 'Fair';
    if (s < 75) return 'Poor';
    return 'Critical';
  }

  // ── Top recommendation based on worst defect found ────────────────────────
  String get topRecommendation {
    final counts = defectCounts;
    if (counts.containsKey('major_crack')) {
      return 'Major structural cracks detected. Engage a structural engineer before any repair work.';
    }
    if (counts.containsKey('spalling')) {
      return 'Spalling present. Remove loose material, apply bonding agent, and patch with repair mortar.';
    }
    if (counts.containsKey('minor_crack')) {
      return 'Minor cracks present. Fill with flexible sealant or epoxy injection. Monitor quarterly.';
    }
    if (counts.containsKey('peeling')) {
      return 'Peeling paint detected. Strip surface, prime, and repaint. Check for moisture ingress.';
    }
    if (counts.containsKey('algae')) {
      return 'Biological growth detected. Apply biocide treatment and improve drainage or ventilation.';
    }
    if (counts.containsKey('stain')) {
      return 'Surface staining present. Chemical cleaning recommended.';
    }
    return 'Surface appears to be in good condition. Continue regular inspection.';
  }
}