import 'dart:async';

import 'package:caption_app/core/api_client.dart';
import 'package:caption_app/core/storage/token_storage.dart';
import 'package:caption_app/models/caption.dart';
import 'package:caption_app/providers/caption_provider.dart';
import 'package:caption_app/providers/core_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeApi extends ApiClient {
  FakeApi() : super(tokenStorage: TokenStorage());
  String fingerprint = 'saved';
  String? exportId;
  Completer<void>? saving;
  Map<String, dynamic>? lastSave;
  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async => {
    'caption_data': {'language': 'English', 'segments': []},
    'style_preset': 'classic', 'aspect_ratio': '1:1',
    'render_fingerprint': fingerprint, 'matching_export_id': exportId,
  };
  @override
  Future<Map<String, dynamic>> put(String path, {Object? data}) async {
    lastSave = data as Map<String, dynamic>;
    await saving?.future;
    fingerprint = 'updated';
    return {'render_fingerprint': fingerprint};
  }
  @override
  Future<Map<String, dynamic>> post(String path, {Object? data}) async => {'job_id': 'job'};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(ProviderContainer, CaptionEditorNotifier, FakeApi)> setup() async {
    final api = FakeApi();
    final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
    final notifier = container.read(captionEditorProvider('project').notifier);
    await Future<void>.delayed(Duration.zero);
    addTearDown(container.dispose);
    return (container, notifier, api);
  }

  test('enqueue and failed render cannot unlock an old download', () async {
    final (container, notifier, api) = await setup();
    expect(container.read(captionEditorProvider('project')).videoFormat, '1:1');
    expect(await notifier.saveAndRerender(), 'job');
    api.exportId = 'old';
    expect(await notifier.matchingExportId(), isNull);
    await notifier.finishRender('job', completed: false);
    expect(container.read(captionEditorProvider('project')).hasUnrenderedChanges, isTrue);
    expect(await notifier.matchingExportId(), isNull);
  });

  test('only completed matching render becomes downloadable', () async {
    final (_, notifier, api) = await setup();
    await notifier.saveAndRerender();
    api.exportId = 'current-export';
    await notifier.finishRender('job', completed: true);
    expect(await notifier.matchingExportId(), 'current-export');
    api.fingerprint = 'changed-by-another-tab';
    expect(await notifier.matchingExportId(), isNull);
  });

  test('editing during a render retains pending changes', () async {
    final (container, notifier, api) = await setup();
    await notifier.saveAndRerender();
    notifier.setStyleOverrides(const StyleOverrides(fontSize: 72));
    api.exportId = 'finished-old-settings';
    await notifier.finishRender('job', completed: true);
    final state = container.read(captionEditorProvider('project'));
    expect(state.hasUnsavedChanges, isTrue);
    expect(state.hasUnrenderedChanges, isTrue);
    expect(await notifier.matchingExportId(), isNull);
  });

  test('edits made while saving stay dirty and format is persisted', () async {
    final (container, notifier, api) = await setup();
    notifier.setVideoFormat('4:5');
    api.saving = Completer<void>();
    final save = notifier.save();
    notifier.setPreset('comic');
    api.saving!.complete();
    await save;
    expect(api.lastSave!['aspect_ratio'], '4:5');
    expect(container.read(captionEditorProvider('project')).hasUnsavedChanges, isTrue);
  });
}
