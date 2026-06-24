import 'ota_fw_catalog.dart';

/// Source-agnostic firmware catalog provider. Lets the backing source (GitHub,
/// or a future alternative) be swapped without touching the picker.
abstract class OtaFwSource {
  Future<OtaFwCatalog> loadCatalog(OtaFwRole role, {bool refresh = false});
}
