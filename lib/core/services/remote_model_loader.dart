import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RemoteModelLoader {
  static const _bucket = 'ml-models';

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
      return null;
    }
  }


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
