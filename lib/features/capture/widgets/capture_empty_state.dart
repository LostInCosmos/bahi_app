import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/dastavez_logo.dart';

/// What the capture screen shows before any bill has been added.
class CaptureEmptyState extends StatelessWidget {
  final VoidCallback onTakePhoto;
  final VoidCallback onPickFromGallery;

  const CaptureEmptyState({super.key, required this.onTakePhoto, required this.onPickFromGallery});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              height: 200,
              decoration: BoxDecoration(
                color: AppColors.spotSurface,
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: const Center(child: DastavezLogoTile(size: 96)),
            ),
            const SizedBox(height: Spacing.xl),
            Text('Scan your first bill', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Spacing.xs),
            Text(
              "Add one or more bill photos. You can adjust every page's corners before processing them together.",
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.l),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.m, vertical: Spacing.s),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.chip),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.menu_book_outlined, size: 16, color: colors.onSurfaceVariant),
                  const SizedBox(width: Spacing.xs),
                  Flexible(
                    child: Text(
                      'Long bill? Add as many pages as you need.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Spacing.xl),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onTakePhoto,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Take photo'),
              ),
            ),
            const SizedBox(height: Spacing.s),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onPickFromGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Choose from Gallery'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
