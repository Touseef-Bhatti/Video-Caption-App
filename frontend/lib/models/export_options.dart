class ExportOptions {
  const ExportOptions({this.resolution = 0, this.fps = 0});

  final int resolution;
  final int fps;

  String get resolutionLabel => switch (resolution) {
        720 => '720 px',
        1024 => '1024 px',
        2048 => '2K · 2048 px',
        3840 => '4K · 3840 px',
        _ => '$resolution px',
      };
}
