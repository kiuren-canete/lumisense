
abstract class MlInferenceRepository {
  Future<void> syncModelMetadata();
  Future<List<String>> fetchSupportedSoundClasses();
}
