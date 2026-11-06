import '../../projects/models/project_milestone.dart';

/// A stable preview identity; existingMilestoneId is the optional database UUID.
class GeneratedMilestoneDraft {
  const GeneratedMilestoneDraft({
    required this.localId,
    required this.title,
    required this.position,
    this.existingMilestoneId,
  });
  final String localId, title;
  final int position;
  final String? existingMilestoneId;

  factory GeneratedMilestoneDraft.existing(ProjectMilestone milestone) =>
      GeneratedMilestoneDraft(
        localId: 'saved:${milestone.id}',
        title: milestone.title,
        position: milestone.position,
        existingMilestoneId: milestone.id,
      );

  GeneratedMilestoneDraft copyWith({String? title, int? position}) =>
      GeneratedMilestoneDraft(
        localId: localId,
        title: title ?? this.title,
        position: position ?? this.position,
        existingMilestoneId: existingMilestoneId,
      );

  Map<String, Object?> toJson() => {
    'localId': localId,
    'title': title,
    'position': position,
    'existingMilestoneId': existingMilestoneId,
  };
}
