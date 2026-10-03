import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'evidence_player_screen.dart';

/// Lists this device's own encrypted evidence records and lets the user
/// open one for playback. Only the self-wrapped key is used here — this is
/// the victim reviewing their own clips, not a guardian.
class EvidenceViewerScreen extends StatelessWidget {
  const EvidenceViewerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vaultBox = Hive.box('vault_box');

    // Evidence records carry a 'status' field; other box entries (like the
    // trusted-guardians map) don't, so this filters to evidence only.
    final entries = vaultBox
        .toMap()
        .entries
        .where((e) => e.value is Map && e.value['status'] != null)
        .toList()
      ..sort((a, b) {
        final aTime = a.value['timestamp'] as String? ?? '';
        final bTime = b.value['timestamp'] as String? ?? '';
        return bTime.compareTo(aTime);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Evidence'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
      ),
      body: entries.isEmpty
          ? const Center(child: Text('No evidence recorded yet.'))
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final data = Map<String, dynamic>.from(entry.value as Map);
                final hash = data['hash'] as String? ?? entry.key.toString();
                final cipherPath = data['path'] as String?;
                final wrappedKey = data['wrappedKey'] as String?;
                final status = data['status'] as String? ?? 'unknown';
                final timestamp = data['timestamp'] as String? ?? '';
                final canPlay = cipherPath != null && wrappedKey != null;

                return ListTile(
                  leading: Icon(
                    status == 'uploaded_to_ipfs'
                        ? Icons.cloud_done
                        : Icons.lock,
                    color: status == 'uploaded_to_ipfs'
                        ? Colors.green
                        : Colors.orange,
                  ),
                  title: Text(
                    hash.length > 20 ? '${hash.substring(0, 20)}...' : hash,
                  ),
                  subtitle: Text('$status  •  $timestamp'),
                  enabled: canPlay,
                  onTap: !canPlay
                      ? null
                      : () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => EvidencePlayerScreen(
                                cipherPath: cipherPath,
                                wrappedKeyB64: wrappedKey,
                                label: hash.length > 12
                                    ? hash.substring(0, 12)
                                    : hash,
                              ),
                            ),
                          );
                        },
                );
              },
            ),
    );
  }
}
