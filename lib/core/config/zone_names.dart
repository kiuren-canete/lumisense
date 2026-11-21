
class ZoneNames {
  ZoneNames._();
  static const String zone1 = 'HIGHSCHOOL';
  static const String zone2 = 'STEM/HUMSS';
  static const String zone3 = 'GAS/TVL';

  static const Map<int, String> byZoneId = {1: zone1, 2: zone2, 3: zone3};

  static const Map<String, String> fromModelLabel = {
    'IT Department': zone1,
    'CS Department': zone2,
    'Engineering Department': zone3,
  };

  static String forZoneId(int zoneId) => byZoneId[zoneId] ?? 'Zone $zoneId';

  static String forModelLabel(String raw) => fromModelLabel[raw] ?? raw;
}
