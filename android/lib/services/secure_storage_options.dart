// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// All clients share the default Android storage namespace. A failed read or
// migration must not erase other secrets stored there.
const secureStorageAndroidOptions = AndroidOptions(
  resetOnError: false,
  migrateOnAlgorithmChange: true,
  migrateWithBackup: true,
  keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
  storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
);

/// The app's Keystore-backed secret store (DATA_MODEL.md §2): extension
/// `secret` settings today; the stem key and MyMemory email later.
const secureStorage = FlutterSecureStorage(
  aOptions: secureStorageAndroidOptions,
);
