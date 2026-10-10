import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../widgets/crop_canvas.dart';

/// One page of a batch capture: drag the four corners onto this bill, pick a
/// rotation, confirm. Deliberately not inside any scrollable — the crop
/// canvas needs the whole screen to itself so a drag near an edge never gets
/// mistaken for a page scroll.
class CropScreen extends StatefulWidget {
  final Uint8List imageBytes;
  // 1-based position of this photo within the bill being captured — >1 only
  // when the caller is already mid multi-page capture (see CaptureScreen),
  // so the confirm button and page hint can reflect that.
  final int pageNumber;
  const CropScreen({super.key, required this.imageBytes, this.pageNumber = 1});

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class CropResult {
  final List<Offset> corners;
  final int rotationDegrees;
  // True when the user tapped "+ Add another page" instead of finishing —
  // the caller should stash this page and immediately capture the next one
  // for the SAME bill rather than treating it as done.
  final bool addAnotherPage;
  CropResult({required this.corners, required this.rotationDegrees, this.addAnotherPage = false});
}

class _CropScreenState extends State<CropScreen> {
  List<Offset> _corners = [];
  int _rotationDegrees = 0;

  /// Confirming before the photo has loaded used to return no corners, which
  /// every caller reads as "cancelled" — the photo was silently dropped.
  bool get _ready => _corners.length == 4;

  void _finish({required bool addAnotherPage}) {
    Navigator.of(context).pop(
      CropResult(corners: _corners, rotationDegrees: _rotationDegrees, addAnotherPage: addAnotherPage),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isContinuedPage = widget.pageNumber > 1;
    return Scaffold(
      appBar: AppBar(title: const Text('Adjust corners')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                isContinuedPage
                    ? 'Page ${widget.pageNumber} of this bill — drag the four handles onto its corners.'
                    : 'Drag the four handles onto the bill\'s corners.',
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                // RotatedBox (not Transform.rotate) so this is a real layout
                // rotation: it reflows the box for 90/270 (swaps the width/
                // height CropCanvas fits into) and transforms touch
                // hit-testing along with it, so corner-dragging still works
                // correctly. Without this the preview always showed the
                // original orientation, so 90/270 looked like they did
                // nothing even though the server was rotating correctly.
                child: RotatedBox(
                  quarterTurns: _rotationDegrees ~/ 90,
                  child: CropCanvas(
                    imageBytes: widget.imageBytes,
                    onCornersChanged: (corners, _) {
                      // The first report is the photo having loaded: only now
                      // is there anything to confirm. Later ones are drags,
                      // which need no rebuild here.
                      if (_corners.isEmpty) {
                        setState(() => _corners = corners);
                      } else {
                        _corners = corners;
                      }
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Rotation (applied after cropping)', style: Theme.of(context).textTheme.labelMedium),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('0°')),
                      ButtonSegment(value: 90, label: Text('90°')),
                      ButtonSegment(value: 180, label: Text('180°')),
                      ButtonSegment(value: 270, label: Text('270°')),
                    ],
                    selected: {_rotationDegrees},
                    onSelectionChanged: (s) => setState(() => _rotationDegrees = s.first),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _ready ? () => _finish(addAnotherPage: true) : null,
                    icon: const Icon(Icons.note_add_outlined),
                    label: const Text('+ Add another page to this bill'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _ready ? () => _finish(addAnotherPage: false) : null,
                    child: Text(isContinuedPage ? 'Confirm bill (${widget.pageNumber} pages)' : 'Confirm this page'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
