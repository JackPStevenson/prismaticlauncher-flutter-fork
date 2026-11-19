// Port of src/Nexus_fetchList/main.cpp: a command-line tool that prints the ten most
// recently updated Stardew Valley mods with their details.
//
// Run with: NEXUS_API_KEY=... dart run bin/nexus_fetch_list.dart

import 'dart:async';
import 'dart:io';

import 'package:prismatic_launcher/nexus_fetch_list/nexus_fetch_list.dart';

/// @brief Prints every field of one mod's details to standard output.
void printModDetails(NexusModDetails mod) {
  stdout
    ..writeln('Mod ${mod.id} : ${mod.name}')
    ..writeln('  Summary: ${mod.summary}')
    ..writeln('  Version: ${mod.version} Author: ${mod.author}')
    ..writeln('  Uploaded by: ${mod.uploadedBy} Category: ${mod.category}')
    ..writeln('  Endorsements: ${mod.endorsementCount} Downloads: ${mod.downloadCount} '
        'Unique downloads: ${mod.uniqueDownloadCount}')
    ..writeln('  Created: ${mod.createdAt} Updated: ${mod.updatedAt}')
    ..writeln('  Adult content: ${mod.adultContent} Available: ${mod.available}')
    ..writeln('  Page URL: ${mod.pageUrl} Picture URL: ${mod.pictureUrl}')
    ..writeln('  Description: ${mod.description}');
}

/// @brief Fetches the mod list, then fetches and prints details one mod at a time.
Future<void> main() async {
  final client = NexusModClient(Platform.environment['NEXUS_API_KEY'] ?? '');
  var exitCode = 0;
  // Port note: the C++ version chained requests through signal handlers inside an event
  // loop. With async/await the same sequence reads top to bottom.
  final failures = client.requestFailed.listen((error) {
    stderr
        .writeln('Failed to fetch Nexus data: ${error.message} (HTTP status ${error.httpStatus})');
    exitCode = 1;
  });

  final modsFuture = client.modListFetched.first;
  await client.fetchModList();
  if (exitCode != 0) {
    modsFuture.ignore();
    await failures.cancel();
    client.dispose();
    exit(exitCode);
  }
  final mods = await modsFuture;
  stdout.writeln('Fetched ${mods.length} mods.');

  final detailIds = mods.take(10).map((mod) => mod.id).toList();
  if (detailIds.isNotEmpty) stdout.writeln('Fetching details for ${detailIds.length} mods.');
  for (final id in detailIds) {
    final detailsFuture = client.modDetailsFetched.first;
    await client.fetchModDetails(id);
    if (exitCode != 0) {
      // No details event will arrive; closing the client must not surface as a crash.
      detailsFuture.ignore();
      break;
    }
    printModDetails(await detailsFuture);
  }

  await failures.cancel();
  client.dispose();
  exit(exitCode);
}
