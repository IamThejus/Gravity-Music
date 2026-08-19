// installation_id.dart
//
// The anonymous, per-install UUID shared by the features that report something
// to a server (HeartbeatService, FeedbackService).
//
// It identifies an INSTALL, never a person: it is a random v4 UUID generated
// on-device, stored in AppPrefs, and never derived from any device or account
// identifier. It exists so repeat signals from one install can be grouped and
// rate-limited — nothing more. Reinstalling produces a brand-new id.
//
// Kept in one place so the two callers cannot drift onto different Hive keys.

import 'dart:math';

import 'package:hive/hive.dart';

const _idKey = 'installationId';

/// The anonymous installation UUID — created lazily on first use, then
/// permanent for the lifetime of the install.
String installationId() {
  final box = Hive.box('AppPrefs');
  var id = box.get(_idKey) as String?;
  if (id == null || id.isEmpty) {
    id = _uuidV4();
    box.put(_idKey, id);
  }
  return id;
}

/// RFC 4122 version-4 UUID from a cryptographically secure RNG.
String _uuidV4() {
  final rnd = Random.secure();
  final b = List<int>.generate(16, (_) => rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1
  String hex(int start, int end) =>
      b.sublist(start, end).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
