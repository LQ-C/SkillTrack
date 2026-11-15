import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/core/constants/content_options.dart';
import 'package:skilltrack/features/educational_content/views/resource_editor.dart';
import 'package:skilltrack/features/educational_content/views/content_screen.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'content_test.dart' show FakeContentRepository, sample;

class CategoryContent extends FakeContentRepository {
  String? filteredCategory;
  @override
  Future<List<LearningResource>> list({
    required bool mine,
    required String search,
    String? category,
    String? level,
    String? kind,
    required int offset,
  }) async {
    filteredCategory = category;
    return [sample];
  }
}

void main() {
  test(
    'categories are unique and retain all historical and current values',
    () {
      expect(contentCategories.toSet().length, contentCategories.length);
      for (final value in [
        'Programming',
        'Cyber Security',
        'Cloud Computing',
        'Data Science',
        'Mobile Application Design',
        'Design',
        'Business',
        'Languages',
        'Music',
        'Lifestyle',
        'Other',
      ]) {
        expect(contentCategories, contains(value));
      }
      for (final duplicate in [
        'Cybersecurity',
        'DevOps & Cloud',
        'Data Science & AI',
        'Mobile App Development',
      ]) {
        expect(contentCategories, isNot(contains(duplicate)));
      }
    },
  );
  for (final category in contentCategories) {
    testWidgets('editor saves and Library filters $category', (tester) async {
      final repo = CategoryContent();
      await tester.pumpWidget(
        MaterialApp(
          home: ResourceEditor(
            repository: repo,
            resource: sample,
            canPublish: true,
          ),
        ),
      );
      final dropdown = tester
          .widgetList<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .firstWhere((w) => w.decoration.labelText == 'Skill category');
      dropdown.onChanged!(category);
      await tester.pump();
      await tester.ensureVisible(find.text('Save resource'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save resource'));
      await tester.pumpAndSettle();
      expect(repo.saved?['category'], category);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: ContentScreen(repository: repo, initialCategory: category),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.filteredCategory, category);
      expect(tester.takeException(), isNull);
    });
  }
}
