import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData get light {
    const primary = Color(0xFF6558A6);
    const background = Color(0xFFF7F6FC);
    const text = Color(0xFF26232D);
    const secondaryText = Color(0xFF686371);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          surface: Colors.white,
        ).copyWith(
          primary: primary,
          onPrimary: Colors.white,
          primaryContainer: const Color(0xFFE9E4FF),
          onPrimaryContainer: const Color(0xFF35265F),
          secondary: const Color(0xFF376A74),
          onSecondary: Colors.white,
          secondaryContainer: const Color(0xFFE0F1F3),
          onSecondaryContainer: const Color(0xFF204E57),
          tertiary: const Color(0xFF965A23),
          onTertiary: Colors.white,
          tertiaryContainer: const Color(0xFFFFF0DC),
          onTertiaryContainer: const Color(0xFF71421A),
          error: const Color(0xFFB83F4E),
          onError: Colors.white,
          errorContainer: const Color(0xFFFFEDEF),
          onErrorContainer: const Color(0xFF802935),
          onSurface: text,
          onSurfaceVariant: secondaryText,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: background,
          surfaceContainer: const Color(0xFFF0EDF8),
          surfaceContainerHigh: const Color(0xFFEBE7F3),
          surfaceContainerHighest: const Color(0xFFE6E0F0),
          outline: const Color(0xFF90899D),
          outlineVariant: const Color(0xFFE4DFED),
          shadow: const Color(0xFF33254E),
        );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    final type = base.textTheme.apply(bodyColor: text, displayColor: text);
    final textTheme = type.copyWith(
      headlineLarge: type.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.6,
      ),
      headlineMedium: type.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.4,
      ),
      headlineSmall: type.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.3,
      ),
      titleLarge: type.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -.2,
      ),
      titleMedium: type.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: type.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodySmall: type.bodySmall?.copyWith(color: secondaryText),
      labelLarge: type.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      labelMedium: type.labelMedium?.copyWith(color: secondaryText),
      labelSmall: type.labelSmall?.copyWith(color: secondaryText),
    );
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: scheme.outlineVariant),
    );
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    return base.copyWith(
      textTheme: textTheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: text,
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: textTheme.titleLarge,
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: .5,
        shadowColor: scheme.shadow.withValues(alpha: .08),
        surfaceTintColor: Colors.transparent,
        shape: cardShape,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: fieldBorder,
        enabledBorder: fieldBorder,
        disabledBorder: fieldBorder,
        focusedBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        errorBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: fieldBorder.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
        labelStyle: TextStyle(color: secondaryText),
        floatingLabelStyle: TextStyle(color: scheme.primary),
        hintStyle: TextStyle(color: secondaryText),
        prefixIconColor: secondaryText,
        suffixIconColor: secondaryText,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: buttonShape,
          textStyle: textTheme.labelLarge,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: buttonShape,
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: buttonShape,
          foregroundColor: scheme.primary,
          textStyle: textTheme.labelLarge,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        elevation: 2,
        focusElevation: 3,
        hoverElevation: 3,
        highlightElevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        extendedTextStyle: textTheme.labelLarge,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.primaryContainer,
        secondarySelectedColor: scheme.primaryContainer,
        disabledColor: scheme.surfaceContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        labelStyle: textTheme.labelLarge,
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onPrimaryContainer,
        ),
        checkmarkColor: scheme.primary,
        deleteIconColor: scheme.onSurfaceVariant,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHigh,
        circularTrackColor: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: scheme.outlineVariant,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: scheme.primaryContainer,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => textTheme.labelMedium?.copyWith(
            fontSize: 11,
            letterSpacing: 0,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shadowColor: scheme.shadow.withValues(alpha: .12),
        textStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.inversePrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
