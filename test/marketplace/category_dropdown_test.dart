import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/widgets/category_dropdown.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/core/constants/content_options.dart';

void main() {
  testWidgets('native category menu is bounded, selected and scrollable', (
    tester,
  ) async {
    String? value = 'Programming';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Padding(
              padding: const EdgeInsets.all(16),
              child: categoryDropdown(
                context: context,
                label: 'Category',
                value: value,
                options: contentCategories,
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .menuMaxHeight,
      330,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded).hitTestable(), findsOneWidget);
    final menu = find.byType(Scrollable).last;
    expect(tester.getSize(menu).height, lessThanOrEqualTo(350));
    await tester.scrollUntilVisible(
      find.text(contentCategories.last).hitTestable(),
      100,
      scrollable: menu,
    );
    await tester.tap(find.text(contentCategories.last).hitTestable());
    await tester.pumpAndSettle();
    expect(value, contentCategories.last);
  });
  testWidgets('large text on small viewport wraps menu rows without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Padding(
              padding: const EdgeInsets.all(16),
              child: categoryDropdown(
                context: context,
                label: 'Category',
                value: 'Version Control & Collaboration',
                options: contentCategories,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('validation and disabled state are preserved', (tester) async {
    final form = GlobalKey<FormState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Form(
              key: form,
              child: categoryDropdown(
                context: context,
                label: 'Category',
                value: null,
                options: contentCategories,
                onChanged: null,
                validator: (v) => v == null ? 'Select category' : null,
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .onChanged,
      isNull,
    );
    expect(form.currentState!.validate(), false);
    await tester.pump();
    expect(find.text('Select category'), findsOneWidget);
  });
}
