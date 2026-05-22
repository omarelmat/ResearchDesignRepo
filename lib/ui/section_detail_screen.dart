import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_classification_mobilenet/helper/cam_helper.dart';
import 'package:image_classification_mobilenet/models/inspection_session.dart';

class SectionDetailScreen extends StatefulWidget {
  final CapturedFrame frame;
  final int index;

  const SectionDetailScreen({
    super.key,
    required this.frame,
    required this.index,
  });

  @override
  State<SectionDetailScreen> createState() => _SectionDetailScreenState();
}

class _SectionDetailScreenState extends State<SectionDetailScreen> {
  bool _showHeatmap = false;
  Uint8List? _heatmapBytes;
  bool _generatingHeatmap = false;

  @override
  void initState() {
    super.initState();
    _preGenerateHeatmap();
  }

  void _preGenerateHeatmap() {
    // Use croppedImage for heatmap if available, else fullImage
    final sourceImage = widget.frame.croppedImage ?? widget.frame.fullImage;
    if (sourceImage == null) return;
    if (widget.frame.featureMap == null) return;
    setState(() => _generatingHeatmap = true);
    Future.microtask(() {
      final camH = CamHelper();
      camH.loadWeights().then((_) {
        final cam = camH.computeCAM(widget.frame.featureMap!, widget.frame.predClass);
        if (cam == null) {
          if (mounted) setState(() => _generatingHeatmap = false);
          return;
        }
        final result = CamHelper.generateOverlay(sourceImage, cam);
        if (mounted) setState(() { _heatmapBytes = result; _generatingHeatmap = false; });
      });
    });
  }

  Color get _labelColor {
    switch (widget.frame.label.trim()) {
      case 'major_crack': return Colors.red;
      case 'minor_crack': return Colors.deepOrange;
      case 'spalling':    return Colors.orange;
      case 'peeling':     return Colors.amber.shade700;
      case 'algae':       return Colors.green;
      case 'stain':       return Colors.blue;
      default:            return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    final m     = frame.measurement;
    final isCrack = frame.label.trim() == 'minor_crack' ||
                    frame.label.trim() == 'major_crack';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('Section ${widget.index}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        actions: [
          // Heatmap toggle — only for cracks or when heatmap is available
          if (_heatmapBytes != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton.icon(
                onPressed: () => setState(() => _showHeatmap = !_showHeatmap),
                icon: Icon(
                  _showHeatmap ? Icons.visibility_off : Icons.visibility,
                  color: Colors.orange,
                  size: 18,
                ),
                label: Text(
                  _showHeatmap ? 'Original' : 'Heatmap',
                  style: const TextStyle(color: Colors.orange),
                ),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(children: [

          // ── Image / Heatmap ─────────────────────────────────────────────
          Container(
            color: Colors.black,
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 380),
            child: _generatingHeatmap
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.orange),
                        SizedBox(height: 12),
                        Text('Generating heatmap…',
                            style: TextStyle(color: Colors.white60)),
                      ],
                    ),
                  )
                : _buildImage(),
          ),

          // ── Heatmap legend ───────────────────────────────────────────────
          if (_showHeatmap && _heatmapBytes != null)
            Container(
              color: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                _legendDot(Colors.red.shade700),
                const SizedBox(width: 6),
                const Text('Detected pixels',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(width: 16),
                _legendLine(Colors.orange),
                const SizedBox(width: 6),
                const Text('Bounding box',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(width: 16),
                _legendLine(Colors.yellow),
                const SizedBox(width: 6),
                const Text('Crack axis',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
              ]),
            ),

          // ── Details card ─────────────────────────────────────────────────
          Container(
            color: const Color(0xFFF5F5F5),
            padding: const EdgeInsets.all(20),
            width: double.infinity,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              // Label + confidence
              Row(children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: _labelColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _labelColor, width: 1.5),
                  ),
                  child: Text(
                    frame.displayLabel.toUpperCase(),
                    style: TextStyle(
                        color: _labelColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        letterSpacing: 0.5),
                  ),
                ),
                const Spacer(),
                Text(
                  '${(frame.confidence * 100).toStringAsFixed(1)}% confidence',
                  style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 13),
                ),
              ]),

              const SizedBox(height: 12),

              // ── Top 3 predictions ────────────────────────────────────
              if (frame.topPredictions.isNotEmpty) ...[
                const Text('ALL DETECTIONS',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.black45,
                        letterSpacing: 1.2)),
                const SizedBox(height: 8),
                ...frame.topPredictions.map((e) {
                  final pct = e.value * 100;
                  final isTop = e.key == frame.label;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      SizedBox(
                        width: 110,
                        child: Text(
                          e.key.replaceAll('_', ' '),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isTop ? FontWeight.bold : FontWeight.normal,
                            color: isTop ? const Color(0xFFE07B39) : Colors.black54,
                          ),
                        ),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: e.value,
                            minHeight: 8,
                            backgroundColor: Colors.grey.shade200,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              isTop ? const Color(0xFFE07B39) : Colors.grey.shade400,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${pct.toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isTop ? FontWeight.bold : FontWeight.normal,
                          color: isTop ? const Color(0xFFE07B39) : Colors.black45,
                        ),
                      ),
                    ]),
                  );
                }),
              ],

              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 12),

              // Measurements section
              if (m != null) ...[
                const Text('MEASUREMENTS',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.black45,
                        letterSpacing: 1.2)),
                const SizedBox(height: 14),

                // ── Primary metrics (distance-independent) ─────────────
                _measureRow('Coverage', m.coverageDisplay,
                    'Percentage of detected area affected'),
                const SizedBox(height: 12),
                _elongationRow(m.elongationIndex, m.elongationLabel),
                const SizedBox(height: 12),
                _severityRow(m.severityScore, m.severityLabel),
                const SizedBox(height: 16),

                // Depth classification
                const Text('DEPTH CLASSIFICATION',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.black45,
                        letterSpacing: 1.2)),
                const SizedBox(height: 10),
                _DepthCard(
                  category:    m.depthCategory,
                  description: m.depthDescription,
                ),

                // ── Secondary metrics (stored, distance-dependent) ──────────
                const SizedBox(height: 16),
                const Text('DIMENSIONAL ESTIMATE',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.black38,
                        letterSpacing: 1.2)),
                const SizedBox(height: 4),
                const Text(
                  'Requires correct distance setting. Stored for future use.',
                  style: TextStyle(fontSize: 11, color: Colors.black38),
                ),
                const SizedBox(height: 8),
                _measureRow('Width',  m.widthDisplay,  'Perpendicular cross-section'),
                const SizedBox(height: 8),
                _measureRow('Length', m.lengthDisplay, 'Extent along principal axis'),
              ] else ...[
                const Text('No measurements available',
                    style: TextStyle(color: Colors.black38)),
              ],

              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),

              // Calibration note
              const Text(
                '📐  Measurements approximate at ~30 cm from wall.\n'
                '    Move closer for finer cracks; ensure phone is parallel to surface.',
                style: TextStyle(fontSize: 11, color: Colors.black38, height: 1.5),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildImage() {
    // Show full image normally; show heatmap (on crop) when toggled
    final displayBytes =
        (_showHeatmap && _heatmapBytes != null) ? _heatmapBytes! : widget.frame.fullImage;

    if (displayBytes == null) {
      return const Center(
        child: Icon(Icons.image_not_supported, color: Colors.white38, size: 64),
      );
    }

    return InteractiveViewer(
      minScale: 1.0,
      maxScale: 5.0,
      child: Image.memory(
        displayBytes,
        fit: BoxFit.contain,
        width: double.infinity,
      ),
    );
  }

  Widget _legendDot(Color color) => Container(
        width: 12, height: 12,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  Widget _legendLine(Color color) => Container(
        width: 16, height: 3,
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(2)),
      );

  Widget _elongationRow(double index, String label) {
    // Determine colour and description based on value
    Color color;
    String description;
    String icon;
    if (index > 5) {
      color = const Color(0xFFDC2626);
      description = 'Long thin crack running in one direction. Likely structural. Professional assessment recommended.';
      icon = '⚠️';
    } else if (index > 2) {
      color = const Color(0xFFEA580C);
      description = 'Crack spreading in multiple directions. Monitor closely and consider sealing.';
      icon = '⚡';
    } else {
      color = const Color(0xFF0369A1);
      description = 'Large area damage such as spalling or peeling. Not a linear crack. Repair surface coating.';
      icon = '🔵';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Elongation Index',
              style: TextStyle(fontSize: 13, color: Colors.black54)),
          const Spacer(),
          Text(
            '$icon  ${index.toStringAsFixed(1)}',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color),
          ),
        ]),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 6),
        Text(description,
            style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ]),
    );
  }

  Widget _severityRow(double score, String label) {
    Color color;
    String description;
    String icon;
    if (score >= 75) {
      color = const Color(0xFFDC2626);
      icon = '🔴';
      description = 'Critical condition. Immediate professional structural assessment is strongly recommended. Do not delay repairs.';
    } else if (score >= 50) {
      color = const Color(0xFFEA580C);
      icon = '🟠';
      description = 'High severity. The defect is significant and should be addressed soon. Schedule a professional inspection.';
    } else if (score >= 25) {
      color = const Color(0xFFF59E0B);
      icon = '🟡';
      description = 'Moderate severity. Monitor the defect regularly. Consider sealing or patching to prevent further deterioration.';
    } else {
      color = const Color(0xFF059669);
      icon = '🟢';
      description = 'Low severity. The defect is minor at this stage. Keep monitoring for any changes over time.';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Severity Score',
              style: TextStyle(fontSize: 13, color: Colors.black54)),
          const Spacer(),
          Text(
            '$icon  ${score.toStringAsFixed(0)}/100',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color),
          ),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: score / 100,
            minHeight: 8,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 6),
        Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 4),
        Text(description,
            style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ]),
    );
  }



  Widget _measureRow(String label, String value, String subtitle) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: const TextStyle(fontSize: 11, color: Colors.black38)),
          ]),
        ),
        Text(value,
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87)),
      ]);
}

class _DepthCard extends StatelessWidget {
  final String category;
  final String description;
  const _DepthCard({required this.category, required this.description});

  Color get _color {
    switch (category) {
      case 'Hairline':    return Colors.green;
      case 'Shallow':     return Colors.orange;
      case 'Moderate':    return Colors.deepOrange;
      case 'Area Defect': return Colors.purple;
      default:            return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _color.withValues(alpha: 0.4), width: 1.5),
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _color,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(category,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(description,
                style: TextStyle(
                    fontSize: 12,
                    color: _color.withValues(alpha: 0.8),
                    height: 1.4)),
          ),
        ]),
      );
}