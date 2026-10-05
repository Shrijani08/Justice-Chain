import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';
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
    } catch (e) {
      logger.e("Resuming pending evidence work failed: $e");
    }
    await OutboxService.start();
  }
}