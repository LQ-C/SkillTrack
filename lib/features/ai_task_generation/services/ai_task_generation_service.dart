import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';

class AiTaskGenerationService {
  AiTaskGenerationService(this._client);
  final SupabaseClient _client;

  Future<Object?> generateRaw({
    required String title,
    required String description,
    required DateTime endDate,
  }) async {
    if (_client.auth.currentUser == null) {
      throw const AppException('Sign in to generate tasks.');
    }
    try {
      final response = await _client.functions
          .invoke(
            'generate-project-tasks',
            body: {
              'projectName': title,
              'description': description,
              'deadline': endDate.toIso8601String().split('T').first,
            },
          )
          .timeout(const Duration(minutes: 2));
      return response.data;
    } on AppException {
      rethrow;
    } on FunctionsHttpException catch (error) {
      debugPrint('generate-project-tasks returned HTTP ${error.status}');
      if (error.status == 404 || error.status == 500 || error.status == 503) {
        throw const AppException(AppErrorMessages.taskGenerationUnavailable);
      }
      throw const AppException(AppErrorMessages.generateTasksFailed);
    } on FunctionsFetchException {
      throw const AppException(AppErrorMessages.requestFailed);
    } on SocketException {
      throw const AppException(AppErrorMessages.requestFailed);
    } on TimeoutException {
      throw const AppException(AppErrorMessages.taskGenerationTimedOut);
    } catch (_) {
      throw const AppException(AppErrorMessages.generateTasksFailed);
    }
  }
}
