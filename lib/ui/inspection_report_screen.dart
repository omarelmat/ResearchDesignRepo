import 'package:flutter/material.dart';
import 'package:image_classification_mobilenet/models/inspection_session.dart';
import 'package:image_classification_mobilenet/ui/section_detail_screen.dart';

class InspectionReportScreen extends StatelessWidget {
  const InspectionReportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = InspectionSession.instance;
    final counts  = session.defectCounts;
    final score   = session.conditionScore;
    final grade   = session.conditionGrade;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Inspection Report',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        actions: [
          TextButton.icon(
            onPressed: () {
              session.clear();
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.refresh, color: Colors.redAccent),
            label: const Text('New Inspection',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
      body: session.isEmpty
          ? const Center(
              child: Text('No frames captured yet.',
                  style: TextStyle(color: Colors.grey)))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _ScoreCard(score: score, grade: grade),
                const SizedBox(height: 16),

                _SectionHeader('Summary'),
                const SizedBox(height: 8),
                _SummaryRow('Total sections scanned', '${session.count}'),
                _SummaryRow(
                  'Cracks found',
                  '${session.crackCount} (${session.minorCrackCount} minor, ${session.majorCrackCount} major)',
                ),
                const SizedBox(height: 16),

                _SectionHeader('Defect Distribution'),
                const SizedBox(height: 8),
                ...counts.entries
                    .where((e) => e.key.trim() != 'plain')
                    .toList()
                    .reversed
                    .map((e) => _DefectBar(
                          label: e.key,
                          count: e.value,
                          total: session.count,
                        )),
                const SizedBox(height: 16),

                _SectionHeader('Recommendation'),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Text(session.topRecommendation,
                      style: const TextStyle(fontSize: 14, height: 1.5)),
                ),
                const SizedBox(height: 16),

                _SectionHeader('Captured Sections (${session.count})'),
                const SizedBox(height: 8),
                ...session.frames.asMap().entries.map((entry) =>
                    _FrameCard(index: entry.key + 1, frame: entry.value)),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}

// ── Reusable widgets ───────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87));
}

class _SummaryRow extends StatelessWidget {
  final String label, value;
  const _SummaryRow(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(label, style: const TextStyle(color: Colors.black54)),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
      );
}

class _ScoreCard extends StatelessWidget {
  final double score;
  final String grade;
  const _ScoreCard({required this.score, required this.grade});

  Color get _gradeColor {
    if (score < 15) return Colors.green;
    if (score < 35) return Colors.lightGreen;
    if (score < 55) return Colors.orange;
    if (score < 75) return Colors.deepOrange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8)],
      ),
      child: Column(children: [
        const Text('Overall Wall Condition',
            style: TextStyle(fontSize: 14, color: Colors.black54)),
        const SizedBox(height: 12),
        Text(grade,
            style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: _gradeColor)),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: score / 100,
            minHeight: 10,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation<Color>(_gradeColor),
          ),
        ),
        const SizedBox(height: 6),
        Text('Condition score: ${score.toStringAsFixed(0)}/100',
            style: const TextStyle(fontSize: 12, color: Colors.black45)),
      ]),
    );
  }
}

class _DefectBar extends StatelessWidget {
  final String label;
  final int count;
  final int total;
  const _DefectBar(
      {required this.label, required this.count, required this.total});

  Color get _color {
    switch (label.trim()) {
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
    final pct = total > 0 ? count / total : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(label.trim().replaceAll('_', ' '),
              style: const TextStyle(fontSize: 13)),
          const Spacer(),
          Text('$count  (${(pct * 100).toStringAsFixed(0)}%)',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 8,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation<Color>(_color),
          ),
        ),
      ]),
    );
  }
}

class _DepthBadgeInline extends StatelessWidget {
  final String category;
  const _DepthBadgeInline(this.category);

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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _color, width: 1),
        ),
        child: Text(category,
            style: TextStyle(
                color: _color,
                fontSize: 11,
                fontWeight: FontWeight.bold)),
      );
}

class _FrameCard extends StatelessWidget {
  final int index;
  final CapturedFrame frame;
  const _FrameCard({required this.index, required this.frame});

  Color get _labelColor {
    switch (frame.label.trim()) {
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
    final m       = frame.measurement;
    final isCrack = frame.label.trim() == 'minor_crack' ||
                    frame.label.trim() == 'major_crack';

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              SectionDetailScreen(frame: frame, index: index),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: frame.thumbnail != null
                ? Image.memory(frame.thumbnail!,
                    width: 72, height: 72, fit: BoxFit.cover)
                : Container(
                    width: 72,
                    height: 72,
                    color: Colors.grey.shade200,
                    child: const Icon(Icons.image, color: Colors.grey)),
          ),
          const SizedBox(width: 12),

          // Details
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              // Title + badge
              Row(children: [
                Text('Section $index',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _labelColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _labelColor),
                  ),
                  child: Text(
                    frame.displayLabel,
                    style: TextStyle(
                        color: _labelColor,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ]),
              const SizedBox(height: 4),

              // Confidence
              Text(
                'Confidence: ${(frame.confidence * 100).toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),

              // Measurements
              if (m != null) ...[
                const SizedBox(height: 4),
                Text('Coverage: ${m.coverageDisplay}',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.black54)),
                if (isCrack) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Width: ${m.widthDisplay}  ·  Length: ${m.lengthDisplay}',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 4),
                  _DepthBadgeInline(m.depthCategory),
                ],
              ] else ...[
                const SizedBox(height: 4),
                const Text('No measurements available',
                    style: TextStyle(
                        fontSize: 12, color: Colors.black38)),
              ],

              // Tap hint
              const SizedBox(height: 6),
              const Row(children: [
                Spacer(),
                Text('Tap for details & heatmap',
                    style: TextStyle(fontSize: 10, color: Colors.black38)),
                SizedBox(width: 2),
                Icon(Icons.chevron_right, size: 14, color: Colors.black38),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}