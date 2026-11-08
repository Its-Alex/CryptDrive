import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

const _seed = Color(0xFF1A73E8);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
      constraints: const BoxConstraints(minHeight: 48, maxHeight: 48),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: EdgeInsets.zero,
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      height: 68,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      elevation: 1,
    ),
    bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}

/// Colour and icon of a file type, like the tiles of a files app.
({IconData icon, Color color}) fileTypeStyle(ColorScheme scheme, {required bool isDir, String? mimeType}) {
  final mime = mimeType ?? '';
  if (isDir) return (icon: Icons.folder_rounded, color: scheme.primary);
  if (mime.startsWith('image/')) return (icon: Icons.image_rounded, color: const Color(0xFFE37400));
  if (mime.startsWith('video/')) return (icon: Icons.movie_rounded, color: const Color(0xFFD93025));
  if (mime.startsWith('audio/')) return (icon: Icons.audiotrack_rounded, color: const Color(0xFF9334E6));
  if (mime == 'application/pdf') return (icon: Icons.picture_as_pdf_rounded, color: const Color(0xFFD93025));
  if (mime.startsWith('text/') || mime == 'application/json') {
    return (icon: Icons.description_rounded, color: const Color(0xFF1E8E3E));
  }
  if (mime.contains('zip') || mime.contains('compressed')) {
    return (icon: Icons.folder_zip_rounded, color: const Color(0xFF5F6368));
  }
  return (icon: Icons.insert_drive_file_rounded, color: scheme.outline);
}
