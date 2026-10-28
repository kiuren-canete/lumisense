/// Single source of truth for zone/department display names.
///
/// If departments ever get renamed again, this is the ONLY file that
/// needs to change — everywhere else (Live Zones cards, the floor plan
/// map tooltips, the AI Source Detection card) reads from here instead
/// of hardcoding its own copy of the name.
///
/// IMPORTANT: zoneId (1/2/3) is the real identifier used throughout
/// Supabase (sensor_readings.zone_id, zone_status, noise_events,
/// buzzer_control, audit_logs) and in the physical sensor firmware.
/// Renaming a department here is purely cosmetic — it does NOT change
/// zoneId, does NOT require a database migration, and does NOT require
/// retraining any model.
class ZoneNames {
  ZoneNames._();

  // Physical layout (see floor_plan_widget.dart for exact map coordinates):
  //   Zone 1 = top table       (was "IT Department"   -> now HIGHSCHOOL)
  //   Zone 2 = left-mid table  (was "CS Department"   -> now STEM/HUMSS)
  //   Zone 3 = bottom table    (was "Engineering Department" -> now GAS/TVL)
  // The ESP32 firmware (Lumisense.ino) must use the same numbers:
  //   ZONE_ID 1 = HIGHSCHOOL board, 2 = STEM/HUMSS board, 3 = GAS/TVL board.
  // This also matches the `zones` table in Supabase (1 HIGHSCHOOL, 2 STEM/HUMSS, 3 GAS/TVL).
  static const String zone1 = 'HIGHSCHOOL';
  static const String zone2 = 'STEM/HUMSS';
  static const String zone3 = 'GAS/TVL';

  static const Map<int, String> byZoneId = {1: zone1, 2: zone2, 3: zone3};

  /// The AI Source Detection model was trained before this rename and its
  /// .tflite file still internally outputs its ORIGINAL labels ('IT
  /// Department', 'CS Department', 'Engineering Department', 'none') —
  /// that's baked into the model and doesn't need to change. This map
  /// translates those raw model outputs to the current display name
  /// whenever they're shown to the user. Only update the right-hand side
  /// here if departments are renamed again; only touch the left-hand
  /// side (or retrain) if the physical sensor-to-zone assignment itself
  /// ever changes.
  static const Map<String, String> fromModelLabel = {
    'IT Department': zone1,
    'CS Department': zone2,
    'Engineering Department': zone3,
  };

  static String forZoneId(int zoneId) => byZoneId[zoneId] ?? 'Zone $zoneId';

  static String forModelLabel(String raw) => fromModelLabel[raw] ?? raw;
}
