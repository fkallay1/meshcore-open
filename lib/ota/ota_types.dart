import 'dart:typed_data';

const int kOtaMagic = 0x07A0;
const int kOtaProtInfV0 = 0x00;
const int kOtaChunkData = 144;
const int kOtaPktHeader = 0x10;
const int kOtaPktChunk = 0x11;
const int kOtaPktApply = 0x12;
const int kOtaPktHdrSig = 0x13;
const int kOtaPktStatus = 0x20;
const int kOtaPktNack = 0x21;
const int kOtaStVerified = 0x04;
const int kOtaStError = 0x80;
const int kGrpDataMaxLen = 165;

/// CRC16/CCITT-FALSE: init 0xFFFF, poly 0x1021, no reflect, no xorout.
int crc16Ccitt(Uint8List data) {
  int crc = 0xFFFF;
  for (final b in data) {
    crc ^= b << 8;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}

enum OtaScope { zerohop, flood, direct }

class OtaJob {
  final Uint8List patch;
  final Uint8List oldSha256;
  final Uint8List newSha256;
  final int oldFwSize;
  final int keyId;
  final Uint8List? presignedMeta; // 102B if pre-signed package
  final Uint8List? presignedSig; // 99B if pre-signed package

  OtaJob({
    required this.patch,
    required this.oldSha256,
    required this.newSha256,
    required this.oldFwSize,
    this.keyId = 1,
    this.presignedMeta,
    this.presignedSig,
  });

  bool get isPresigned => presignedMeta != null && presignedSig != null;
}
