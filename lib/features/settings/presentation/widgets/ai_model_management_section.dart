import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../core/services/remote_model_loader.dart';
import '../../../../core/theme/app_colors.dart';

/// Settings > AI Model Management.
///
/// Lets an admin upload a replacement sound-type model: ONE .json file made
/// by ai_training/train_sound_model.py (labels and scaler are inside it).
/// The upload goes to Supabase Storage; every device picks up the new model
/// automatically on next app start — no rebuild needed. A file that is not a
/// valid model is ignored and the bundled model keeps running.
/// See lib/core/services/remote_model_loader.dart.
/// (Which-zone detection is a fixed rule now, so it has nothing to upload.)
///
/// NOTE: gated on the same UserRole placeholder used elsewhere in the app
/// (see statistics_report_page.dart). That enum isn't yet wired to a real
/// authenticated session/role lookup — until it is, this section is
/// visible to anyone who reaches Settings. Flagging this so it isn't
/// mistaken for enforced access control.
class AiModelManagementSection extends StatefulWidget {
  const AiModelManagementSection({super.key});

  @override
  State<AiModelManagementSection> createState() => _AiModelManagementSectionState();
}

class _AiModelManagementSectionState extends State<AiModelManagementSection> {
  String? _soundTypeVersion;
  bool _loadingVersions = true;

  @override
  void initState() {
    super.initState();
    _refreshVersions();
  }

  Future<void> _refreshVersions() async {
    setState(() => _loadingVersions = true);
    final soundType = await RemoteModelLoader.currentVersion('sound_type');
    if (!mounted) return;
    setState(() {
      _soundTypeVersion = soundType;
      _loadingVersions = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'AI Model Management',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Replace a trained model without rebuilding the app',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 20),
          _ModelUploadRow(
            title: 'Sound Type Classifier',
            subtitle: 'Per-zone: quiet / talking / clapping / shouting / table dragging / phone',
            currentVersion: _soundTypeVersion,
            loading: _loadingVersions,
            onUpload: () => _pickAndUpload('sound_type'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndUpload(String modelType) async {
    final messenger = ScaffoldMessenger.of(context);

    final modelResult = await FilePicker.pickFiles(
      dialogTitle: 'Select the model .json file (sound_model.json)',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (modelResult == null || modelResult.files.single.path == null) return;

    messenger.showSnackBar(
      const SnackBar(content: Text('Uploading model…')),
    );

    final success = await RemoteModelLoader.upload(
      modelType: modelType,
      modelFile: File(modelResult.files.single.path!),
    );

    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Model uploaded. Devices will pick it up next launch.'
              : 'Upload failed — check the ml-models bucket exists and try again.',
        ),
        backgroundColor: success ? AppColors.success : AppColors.statusCritical,
      ),
    );

    if (success) await _refreshVersions();
  }
}

class _ModelUploadRow extends StatelessWidget {
  const _ModelUploadRow({
    required this.title,
    required this.subtitle,
    required this.currentVersion,
    required this.loading,
    required this.onUpload,
  });

  final String title;
  final String subtitle;
  final String? currentVersion;
  final bool loading;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                ),
                const SizedBox(height: 6),
                Text(
                  loading
                      ? 'Checking current version…'
                      : (currentVersion == null
                          ? 'Using bundled default model'
                          : 'Custom model active (v$currentVersion)'),
                  style: TextStyle(
                    color: currentVersion == null
                        ? AppColors.textSecondary
                        : AppColors.success,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: onUpload,
            icon: const Icon(LucideIcons.upload, size: 14),
            label: const Text('Upload'),
          ),
        ],
      ),
    );
  }
}