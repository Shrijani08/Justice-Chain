import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';

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
    logger.i("Hive and Logger ready.");
  }
}