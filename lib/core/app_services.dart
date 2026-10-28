import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';
import 'authority_service.dart';
import 'co_guardian_service.dart';
import 'device_link_service.dart';
import 'evidence_vault_service.dart';
import 'identity_service.dart';
import 'mesh_service.dart';
import 'outbox_service.dart';

// Global logger accessible anywhere
final logger = Logger(
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 5,
    lineLength: 50,
    colors: true,
    printEmojis: true,
  ),
);

class AppServices {
  static Future<void> init() async {
    logger.i("Initializing App Services...");
    await Hive.initFlutter();
    await Hive.openBox('vault_box'); // Our local cache for evidence info
    await Hive.openBox(OutboxService.boxName);
    await Hive.openBox(MeshService.receivedSharesBoxName);
    await Hive.openBox(MeshService.relayBoxName);
    await IdentityService.initializeDevice();
    
    logger.i("Hive, Logger, and Identity Services ready.");
  }

  /// Starts background evidence work. Must run after .env is loaded, since
  /// uploads and anchoring read their config from it.
  static Future<void> startBackgroundWork() async {
    try {
      await EvidenceVaultService.issueMissingGuardianShares();
      await EvidenceVaultService.resumePendingWork();
      // Fabric only: register this phone and keep its guardian list current
      // on the ledger (both no-ops once done).
      await AuthorityService.requestRegistration();
      await AuthorityService.requestGuardianSync();
    } catch (e) {
      logger.e("Resuming pending evidence work failed: $e");
    }
    await OutboxService.start();
    // Key pieces co-guardians and SOS devices sent while the app was closed.
    unawaited(CoGuardianService.fetchMailbox().catchError((Object e) {
      logger.w("Checking the key-piece mailbox failed: $e");
      return 0;
    }));
    // And again every minute while the app is on screen.
    CoGuardianService.startPolling();
    // Keeps a linked SOS device's guardian list current.
    if (AuthorityService.ledgerFeaturesEnabled) {
      unawaited(DeviceLinkService.sendSetup().catchError((Object e) {
        logger.w("Updating the SOS device failed: $e");
      }));
    }
  }
}