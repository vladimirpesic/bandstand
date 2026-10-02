import 'package:bandstand/bridge/frb_generated.dart';
import 'package:bandstand/io/harmony_assets.dart';
import 'package:bandstand/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await installHarmonyAssets();
  await RustLib.init();
  runApp(const ProviderScope(child: BandstandApp()));
}
