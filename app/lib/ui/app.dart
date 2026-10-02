import 'package:bandstand/ui/screens/audio_engine_screen.dart';
import 'package:bandstand/ui/screens/library_screen.dart';
import 'package:bandstand/ui/screens/playlists_screen.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:flutter/material.dart';

/// The application shell.
class BandstandApp extends StatelessWidget {
  const BandstandApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bandstand',
      debugShowCheckedModeBanner: false,
      theme: BandstandTheme.light(),
      darkTheme: BandstandTheme.dark(),
      // Dark by default: the app is read on a stand, in a dark room, from two
      // metres away (§8.1). The light theme is the exception, not the default.
      themeMode: ThemeMode.dark,
      home: const BandstandHome(),
    );
  }
}

/// The screens the app is made of, and how you get between them (§8.2).
///
/// A rail on a desktop or a tablet in landscape, a bottom bar on a phone. The
/// reading mode of M3 takes the whole screen and has no chrome at all, so it
/// does not appear here.
class BandstandHome extends StatefulWidget {
  const BandstandHome({super.key});

  @override
  State<BandstandHome> createState() => _BandstandHomeState();
}

class _BandstandHomeState extends State<BandstandHome> {
  int _index = 0;

  static const List<({String label, IconData icon, IconData selectedIcon})>
  _destinations = <({String label, IconData icon, IconData selectedIcon})>[
    (
      label: 'Library',
      icon: Icons.library_music_outlined,
      selectedIcon: Icons.library_music,
    ),
    (
      label: 'Sets',
      icon: Icons.queue_music_outlined,
      selectedIcon: Icons.queue_music,
    ),
    (
      label: 'Audio',
      icon: Icons.graphic_eq_outlined,
      selectedIcon: Icons.graphic_eq,
    ),
  ];

  Widget _screenAt(int index) => switch (index) {
    0 => const LibraryScreen(),
    1 => const PlaylistsScreen(),
    _ => const AudioEngineScreen(),
  };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final body = _screenAt(_index);
        if (constraints.maxWidth < 640) {
          return Scaffold(
            body: body,
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (index) => setState(() => _index = index),
              destinations: <Widget>[
                for (final destination in _destinations)
                  NavigationDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: destination.label,
                  ),
              ],
            ),
          );
        }
        return Scaffold(
          body: Row(
            children: <Widget>[
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (index) =>
                    setState(() => _index = index),
                labelType: NavigationRailLabelType.all,
                leading: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Icon(Icons.music_note),
                ),
                destinations: <NavigationRailDestination>[
                  for (final destination in _destinations)
                    NavigationRailDestination(
                      icon: Icon(destination.icon),
                      selectedIcon: Icon(destination.selectedIcon),
                      label: Text(destination.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ],
          ),
        );
      },
    );
  }
}
