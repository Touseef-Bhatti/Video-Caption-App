import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_exception.dart';
import '../models/project.dart';
import 'core_providers.dart';

class ProjectListState {
  const ProjectListState({this.projects = const [], this.isLoading = false, this.errorMessage});

  final List<Project> projects;
  final bool isLoading;
  final String? errorMessage;

  ProjectListState copyWith({List<Project>? projects, bool? isLoading, String? errorMessage, bool clearError = false}) =>
      ProjectListState(
        projects: projects ?? this.projects,
        isLoading: isLoading ?? this.isLoading,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      );
}

class ProjectListNotifier extends StateNotifier<ProjectListState> {
  ProjectListNotifier(this._ref) : super(const ProjectListState()) {
    refresh();
  }

  final Ref _ref;

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final raw = await _ref.read(apiClientProvider).getList('/api/projects');
      final projects = raw.map((j) => Project.fromJson(j as Map<String, dynamic>)).toList();
      state = state.copyWith(projects: projects, isLoading: false);
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.message);
    }
  }

  Future<bool> deleteProject(String projectId) async {
    try {
      await _ref.read(apiClientProvider).delete('/api/projects/$projectId');
      state = state.copyWith(projects: state.projects.where((p) => p.id != projectId).toList());
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(errorMessage: e.message);
      return false;
    }
  }
}

final projectListProvider = StateNotifierProvider<ProjectListNotifier, ProjectListState>((ref) => ProjectListNotifier(ref));

/// A single project's detail -- re-fetched on demand (e.g. after a
/// render/re-render completes) rather than polled continuously; job
/// progress itself is polled separately by job_provider.dart.
final projectDetailProvider = FutureProvider.family<Project, String>((ref, projectId) async {
  final json = await ref.read(apiClientProvider).get('/api/projects/$projectId');
  return Project.fromJson(json);
});

final videoPreviewUrlProvider = FutureProvider.family<String, String>((ref, projectId) async {
  final json = await ref.read(apiClientProvider).get('/api/projects/$projectId/video/preview-url');
  return json['preview_url'] as String;
});

class UsageSummary {
  UsageSummary({required this.totalSeconds, required this.monthSeconds, required this.videos});

  final double totalSeconds;
  final double monthSeconds;
  final int videos;
}

final usageProvider = FutureProvider.autoDispose<UsageSummary>((ref) async {
  final j = await ref.read(apiClientProvider).get('/api/usage');
  return UsageSummary(
    totalSeconds: (j['total_seconds_processed'] as num).toDouble(),
    monthSeconds: (j['this_month_seconds_processed'] as num).toDouble(),
    videos: (j['videos_processed'] as num).toInt(),
  );
});
