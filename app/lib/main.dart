import 'package:bandstand/bridge/frb_generated.dart';
import 'package:bandstand/io/harmony_assets.dart';
import 'package:bandstand/state/library.dart';
import 'package:bandstand/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await installHarmonyAssets();
  await RustLib.init();
  // The library's platform pieces (directories, the API gateway) resolve
  // here, once, before the first frame — everything downstream is
  // synchronous wiring.
  final services = await LibraryServices.create();
  runApp(
    ProviderScope(
      overrides: [libraryServicesProvider.overrideWithValue(services)],
      child: const BandstandApp(),
    ),
  );
}
