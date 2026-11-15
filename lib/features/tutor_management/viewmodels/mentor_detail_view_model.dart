import 'dart:async';
import '../../../core/utils/view_model.dart';
import '../../educational_content/models/learning_resource.dart';
import '../../educational_content/repositories/content_repository.dart';
import '../models/tutor_models.dart';
import '../models/mentor_payment.dart';
import '../repositories/tutor_repository.dart';
import 'tutor_view_model.dart';

class MentorDetailViewModel extends ViewModel {
  MentorDetailViewModel(this.repository, this.mentorId, this.content)
    : owner = repository.userId {
    if (repository is TutorSessionSource) {
      subscription = (repository as TutorSessionSource).userChanges.listen((
        id,
      ) {
        if (id != owner) {
          update(() {
            invalidatePlayback();
            invalid = true;
            resources = [];
            slots = [];
            access = const MentorPaymentAccess();
          });
        }
      });
    }
  }
  static const requestTimeout = Duration(seconds: 20);
  final TutorRepository repository;
  final ContentRepository? content;
  final String mentorId, owner;
  StreamSubscription<String?>? subscription;
  bool invalid = false;
  bool get current {
    try {
      return isActive && !invalid && repository.userId == owner;
    } catch (_) {
      return false;
    }
  }

  bool get own => owner == mentorId;
  bool get unlocked => own || (accountRole == 'student' && access.materials);
  List<MentorSlot> slots = [];
  List<LearningResource> resources = [];
  MentorPaymentOffer? offer;
  MentorPaymentAccess access = const MentorPaymentAccess();
  String? accountRole, error, success, paymentError, materialsError;
  bool loading = true,
      loadingAccount = true,
      loadingSessions = true,
      busy = false,
      loadingMaterials = false,
      hasMore = false;
  Future<void>? pending;
  Future<void> load() => pending ??= _load().whenComplete(() => pending = null);
  Future<void> _load() async {
    if (!current) return;
    update(() {
      loading = true;
      error = null;
    });
    await Future.wait([_account(), _sessions(), loadMaterials()]);
    if (current) update(() => loading = false);
  }

  Future<void> _account() async {
    if (!current) return;
    update(() => loadingAccount = true);
    try {
      final role = await repository.role().timeout(requestTimeout);
      if (!current) return;
      final values = await Future.wait<dynamic>([
        repository.paymentOffer(mentorId).timeout(requestTimeout),
        if (role == 'student')
          repository.paymentAccess(mentorId).timeout(requestTimeout)
        else
          Future.value(const MentorPaymentAccess()),
      ]);
      final price = values[0] as MentorPaymentOffer?;
      final entitlement = values[1] as MentorPaymentAccess;
      if (current) {
        update(() {
          accountRole = role;
          offer = price;
          if (access.materials && !entitlement.materials) invalidatePlayback();
          access = entitlement;
          paymentError = null;
        });
      }
    } catch (e) {
      if (current) {
        update(() {
          invalidatePlayback();
          access = const MentorPaymentAccess();
          paymentError = tutorError(e);
        });
      }
    } finally {
      if (current) update(() => loadingAccount = false);
    }
  }

  Future<void> _sessions() async {
    if (!current) return;
    update(() => loadingSessions = true);
    try {
      final values = await repository
          .availableSlots(mentorId)
          .timeout(requestTimeout);
      if (current) update(() => slots = values);
    } catch (e) {
      if (current) update(() => error = tutorError(e));
    } finally {
      if (current) update(() => loadingSessions = false);
    }
  }

  Future<void> loadMaterials({bool more = false}) async {
    if (!current || loadingMaterials) return;
    if (!more) invalidatePlayback();
    update(() {
      loadingMaterials = true;
      materialsError = null;
    });
    try {
      if (content is! MentorResourcePreviewRepository) {
        throw const FormatException(
          'Learning-material previews are not available yet.',
        );
      }
      final rows = await (content as MentorResourcePreviewRepository)
          .mentorPreviews(mentorId, offset: more ? resources.length : 0)
          .timeout(requestTimeout);
      if (current) {
        update(() {
          resources = more ? [...resources, ...rows] : rows;
          hasMore = rows.length == 20;
        });
      }
    } catch (e) {
      if (current) {
        update(
          () => materialsError = e is FormatException
              ? e.message
              : 'Could not load learning materials. Retry, or ask the administrator to enable mentor previews.',
        );
      }
    } finally {
      if (current) update(() => loadingMaterials = false);
    }
  }

  int playbackVersion = 0;
  final _playbackRequests = <String, Future<String>>{};
  void invalidatePlayback() {
    playbackVersion++;
    _playbackRequests.clear();
  }

  Future<String> videoPlaybackUrl(String id) {
    if (!current) return Future.error(StateError('Session changed.'));
    final existing = _playbackRequests[id];
    if (existing != null) return existing;
    final version = playbackVersion;
    final request = _videoPlaybackUrl(id, version);
    _playbackRequests[id] = request;
    return request.whenComplete(() {
      if (version == playbackVersion) _playbackRequests.remove(id);
    });
  }

  Future<String> _videoPlaybackUrl(String id, int version) async {
    bool valid() => current && version == playbackVersion;
    if (!valid() || content is! ResourceOpeningRepository) {
      throw StateError('Video unavailable.');
    }
    if (!own) {
      final latest = await repository.paymentAccess(mentorId);
      if (!valid()) throw StateError('Session changed.');
      update(() {
        if (access.materials && !latest.materials) invalidatePlayback();
        access = latest;
      });
    }
    if (!valid() || !unlocked) {
      throw StateError('Materials access is required.');
    }
    final resource = await content!.get(id);
    if (!valid() ||
        resource.id != id ||
        resource.kind != 'Video' ||
        resource.authorId != mentorId ||
        resource.status != 'published' ||
        resource.hidden) {
      throw StateError('Video unavailable.');
    }
    final url = await (content as ResourceOpeningRepository).primaryFileUrl(
      resource,
    );
    if (!valid() || !unlocked) throw StateError('Session changed.');
    return url;
  }

  Future<bool> canOpen(String id) async {
    if (!current || content == null) return false;
    if (!own) {
      final latest = await repository.paymentAccess(mentorId);
      if (!current) return false;
      update(() {
        if (access.materials && !latest.materials) invalidatePlayback();
        access = latest;
      });
    }
    if (!current || !unlocked) return false;
    // Recheck the resource through existing full-row RLS immediately before navigation.
    final r = await content!.get(id);
    return current &&
        r.authorId == mentorId &&
        r.status == 'published' &&
        !r.hidden;
  }

  @override
  void dispose() {
    invalidatePlayback();
    subscription?.cancel();
    super.dispose();
  }
}
