import 'fota_fw_catalog.dart';

/// Source-agnostic firmware catalog provider. Lets the backing source (GitHub,
/// or a future alternative) be swapped without touching the picker.
abstract class FotaFwSource {
  Future<FotaFwCatalog> loadCatalog(FotaFwRole role, {bool refresh = false});
}
