import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/app_settings.dart';


class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  final ValueNotifier<AppSettings> settings =
      ValueNotifier<AppSettings>(const AppSettings());

  bool _loaded = false;

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final client = Supabase.instance.client;
      final rows = await client
          .from('settings')
          .select()
          .eq('id', 1)
          .limit(1);

      if (rows.isNotEmpty) {
        settings.value = AppSettings.fromMap(rows.first);
      }
      _loaded = true;
    } catch (_) {
    }
  }

  Future<bool> save(AppSettings newSettings) async {
    try {
      final client = Supabase.instance.client;
      await client.from('settings').upsert(newSettings.toMap());
      settings.value = newSettings;
      return true;
    } catch (_) {
      return false;
    }
  }
}