import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Checks Supabase for an admin-uploaded replacement sound model and
/// downloads it into local app storage if it's newer than what's already
/// cached on disk. This lets the client swap the model without a new app
/// build — the bundled `assets/models/sound_model.json` is always the
/// fallback if nothing has been uploaded yet, or if the download fails
/// or the file is not a valid model.
///
/// A model is ONE .json file (made by ai_training/train_sound_model.py).
class RemoteModelLoader {
  static const _bucket = 'ml-models';

  /// Returns the local path of the downloaded model .json if a remote
  /// model is available (or already cached), otherwise null — callers
  /// then fall back to the bundled model.
  static Future<String?> fetch(String modelType) async {
    try {
      final client = Supabase.instance.client;
      final row = await client
          .from('ml_model_versions')
          .select()
          .eq('model_type', modelType)
          .maybeSingle();

      if (row == null) return null;

      final supportDir = await getApplicationSupportDirectory();
      final modelDir = Directory('${supportDir.path}/ml_models/$modelType');
      await modelDir.create(recursive: true);

      final modelPath = '${modelDir.path}/model.json';
      final versionMarker = File('${modelDir.path}/.version_json');
      final versionTag = row['version_tag'] as String;

      final alreadyCached = await versionMarker.exists() &&
          (await versionMarker.readAsString()).trim() == versionTag &&
          await File(modelPath).exists();

      if (!alreadyCached) {
        final bytes = await client.storage
            .from(_bucket)
            .download(row['storage_path'] as String);
        await File(modelPath).writeAsBytes(bytes);
        await versionMarker.writeAsString(versionTag);
      }

      return modelPath;
    } catch (_) {
      // Offline, bucket not set up yet, corrupt row, etc. — never let a
      // bad remote model prevent the app from starting.
      return null;
    }
  }

  /// Uploads a replacement model (one .json file) and marks it as the
  /// current version for [modelType]. Every device picks it up the next
  /// time [fetch] runs (app startup), no rebuild required.
  static Future<bool> upload({
    required String modelType,
    required File modelFile,
    String? uploadedBy,
  }) async {
    try {
      final client = Supabase.instance.client;
      final versionTag = DateTime.now().millisecondsSinceEpoch.toString();
      final path = '$modelType/$versionTag/model.json';

      await client.storage.from(_bucket).uploadBinary(
            path,
            await modelFile.readAsBytes(),
            fileOptions: const FileOptions(upsert: true),
          );

      // ml_model_versions still has labels_path / scaler_path columns that
      // cannot be empty. The labels and scaler now live inside the one JSON
      // file, so all three columns point at it.
      await client.from('ml_model_versions').upsert({
        'model_type': modelType,
        'storage_path': path,
        'labels_path': path,
        'scaler_path': path,
        'version_tag': versionTag,
        'uploaded_by': uploadedBy,
        'updated_at': DateTime.now().toIso8601String(),
      });

      return true;
    } catch (_) {
      return false;
    }
  }

  /// The currently-active version tag for [modelType], or null if no
  /// custom model has been uploaded (still using the bundled model).
  static Future<String?> currentVersion(String modelType) async {
    try {
      final row = await Supabase.instance.client
          .from('ml_model_versions')
          .select('version_tag, uploaded_by, updated_at')
          .eq('model_type', modelType)
          .maybeSingle();
      return row == null ? null : row['version_tag'] as String;
    } catch (_) {
      return null;
    }
  }
}
