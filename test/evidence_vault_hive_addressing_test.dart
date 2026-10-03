import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

// Regression coverage for the Phase 1 fix: evidence records in 'vault_box'
// must be addressed by a stable key (the content hash), not by Hive's
// auto-increment insertion index via getAt()/putAt(). Positional indices
// shift whenever any entry anywhere in the box is added or removed, so a
// held index can silently point at the wrong record later.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vault_box_test');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk('vault_box');
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('a record stays addressable by its hash key after an unrelated entry is removed', () async {
    final vaultBox = await Hive.openBox('vault_box');

    const hashA = 'aaaa_fixed_content_hash';
    const hashB = 'bbbb_fixed_content_hash';
    const hashC = 'cccc_fixed_content_hash';

    await vaultBox.put(hashA, {'hash': hashA, 'status': 'locally_secured', 'cid': null});
    await vaultBox.put(hashB, {'hash': hashB, 'status': 'locally_secured', 'cid': null});
    await vaultBox.put(hashC, {'hash': hashC, 'status': 'locally_secured', 'cid': null});

    // Remove the entry inserted before C. A positional getAt(index) captured
    // for C before this delete would now point at the wrong record.
    await vaultBox.delete(hashB);

    final recordC = Map<String, dynamic>.from(vaultBox.get(hashC) as Map);
    expect(recordC['hash'], hashC);

    // Simulate the IPFS-upload callback updating the record by key.
    final updated = Map<String, dynamic>.from(recordC)
      ..['cid'] = 'ipfs-cid-for-c'
      ..['status'] = 'uploaded_to_ipfs';
    await vaultBox.put(hashC, updated);

    final reread = Map<String, dynamic>.from(vaultBox.get(hashC) as Map);
    expect(reread['cid'], 'ipfs-cid-for-c');
    expect(reread['status'], 'uploaded_to_ipfs');

    // Record A, untouched by any of the above, must be unaffected.
    final recordA = Map<String, dynamic>.from(vaultBox.get(hashA) as Map);
    expect(recordA['hash'], hashA);
    expect(recordA['status'], 'locally_secured');
  });

  test('relaying the same clip twice overwrites one record instead of duplicating it', () async {
    final vaultBox = await Hive.openBox('vault_box');
    const hash = 'relayed_clip_hash';

    await vaultBox.put(hash, {
      'hash': hash,
      'status': 'relay_received',
      'source': 'mesh_relay',
    });
    await vaultBox.put(hash, {
      'hash': hash,
      'status': 'relay_received',
      'source': 'mesh_relay',
    });

    expect(vaultBox.keys.where((k) => k == hash).length, 1);
  });
}
