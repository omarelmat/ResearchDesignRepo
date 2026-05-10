class DefectResult {
  final String label;
  final String severity;
  final double minPricePerSqm;
  final double maxPricePerSqm;
  final String repairMethod;
  final String priceBreakdown;
  final double areaM2;

  DefectResult({
    required this.label,
    required this.severity,
    required this.minPricePerSqm,
    required this.maxPricePerSqm,
    required this.repairMethod,
    required this.priceBreakdown,
    required this.areaM2,
  });

  double get minTotal => 80 + (minPricePerSqm * areaM2); // €80 call-out
  double get maxTotal => 80 + (maxPricePerSqm * areaM2);

  String get priceRange =>
      '€${minTotal.toStringAsFixed(0)} – €${maxTotal.toStringAsFixed(0)}';
}

class DefectPricing {
  static const double callOut = 80.0;

  static DefectResult calculate(String label, double areaM2) {
    switch (label.toLowerCase().trim()) {

      case 'algae':
        return DefectResult(
          label: label, severity: 'Low', areaM2: areaM2,
          minPricePerSqm: 15, maxPricePerSqm: 30,
          repairMethod: 'Biocide spray treatment and surface wash.',
          priceBreakdown:
              'Call-out €80 + €15–€30/m² × ${areaM2.toStringAsFixed(2)} m² '
              '= €${(80 + 15 * areaM2).toStringAsFixed(0)}–€${(80 + 30 * areaM2).toStringAsFixed(0)}.',
        );

      case 'minor_crack':
        return DefectResult(
          label: label, severity: 'Medium', areaM2: areaM2,
          minPricePerSqm: 40, maxPricePerSqm: 80,
          repairMethod: 'Surface crack filling with flexible sealant or mortar.',
          priceBreakdown:
              'Call-out €80 + €40–€80/m² × ${areaM2.toStringAsFixed(2)} m² '
              '= €${(80 + 40 * areaM2).toStringAsFixed(0)}–€${(80 + 80 * areaM2).toStringAsFixed(0)}.',
        );

      case 'major_crack':
        return DefectResult(
          label: label, severity: 'High', areaM2: areaM2,
          minPricePerSqm: 120, maxPricePerSqm: 250,
          repairMethod: 'Structural repointing, crack injection, and reinforcement.',
          priceBreakdown:
              'Call-out €80 + €120–€250/m² × ${areaM2.toStringAsFixed(2)} m² '
              '= €${(80 + 120 * areaM2).toStringAsFixed(0)}–€${(80 + 250 * areaM2).toStringAsFixed(0)}. '
              'Structural assessment recommended.',
        );

      case 'peeling':
        return DefectResult(
          label: label, severity: 'Low–Medium', areaM2: areaM2,
          minPricePerSqm: 25, maxPricePerSqm: 55,
          repairMethod: 'Strip peeling coat, prime, and repaint surface.',
          priceBreakdown:
              'Call-out €80 + €25–€55/m² × ${areaM2.toStringAsFixed(2)} m² '
              '= €${(80 + 25 * areaM2).toStringAsFixed(0)}–€${(80 + 55 * areaM2).toStringAsFixed(0)}.',
        );

      case 'spalling':
        return DefectResult(
          label: label, severity: 'High', areaM2: areaM2,
          minPricePerSqm: 90, maxPricePerSqm: 180,
          repairMethod: 'Remove loose concrete, apply patch mortar, seal.',
          priceBreakdown:
              'Call-out €80 + €90–€180/m² × ${areaM2.toStringAsFixed(2)} m² '
              '= €${(80 + 90 * areaM2).toStringAsFixed(0)}–€${(80 + 180 * areaM2).toStringAsFixed(0)}.',
        );

      case 'stain':
        return DefectResult(
          label: label, severity: 'Low', areaM2: areaM2,
          minPricePerSqm: 10, maxPricePerSqm: 25,
          repairMethod: 'Chemical cleaning with appropriate surface solvent.',
          priceBreakdown:
              'Call-out €80 + €10–€25/m² × ${areaM2.toStringAsFixed(2)} m² '
              '= €${(80 + 10 * areaM2).toStringAsFixed(0)}–€${(80 + 25 * areaM2).toStringAsFixed(0)}.',
        );

      case 'plain':
      default:
        return DefectResult(
          label: label, severity: 'None', areaM2: areaM2,
          minPricePerSqm: 0, maxPricePerSqm: 0,
          repairMethod: 'No defect detected. No repair needed.',
          priceBreakdown: 'Surface appears to be in good condition.',
        );
    }
  }
}