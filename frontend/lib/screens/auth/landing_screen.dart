import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../public/public_site_widgets.dart';

class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: SiteColors.background,
        body: SelectionArea(
          child: Column(
            children: [
              const PublicSiteHeader(),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 900;
                    return SingleChildScrollView(
                      child: Column(
                        children: [
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              compact ? 22 : 5.2 * 16,
                              compact ? 50 : 76,
                              compact ? 22 : 5.2 * 16,
                              65,
                            ),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1320),
                              child: compact
                                  ? Column(children: [
                                      const _HeroCopy(centered: true),
                                      const SizedBox(height: 42),
                                      const _EditorPreview(),
                                    ])
                                  : const Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Expanded(flex: 8, child: _HeroCopy()),
                                        SizedBox(width: 45),
                                        Expanded(
                                            flex: 12, child: _EditorPreview()),
                                      ],
                                    ),
                            ),
                          ),
                          const _HowItWorks(),
                          const SitePageFooter(),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
}

class _HeroCopy extends StatelessWidget {
  const _HeroCopy({this.centered = false});
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final alignment =
        centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final textAlign = centered ? TextAlign.center : TextAlign.left;
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 900;
    return Column(
      crossAxisAlignment: alignment,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          decoration: BoxDecoration(
              color: SiteColors.lavender,
              borderRadius: BorderRadius.circular(99)),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.bolt_rounded, size: 18, color: SiteColors.purple),
            SizedBox(width: 7),
            Text('Video Caption Generator',
                style: TextStyle(
                    color: SiteColors.ink, fontWeight: FontWeight.w700)),
          ]),
        ),
        const SizedBox(height: 27),
        Text.rich(
          TextSpan(children: const [
            TextSpan(text: 'Add Professional\nCaptions to Your\nVideos in '),
            TextSpan(
                text: 'Minutes', style: TextStyle(color: SiteColors.purple)),
          ]),
          textAlign: textAlign,
          style: TextStyle(
              color: SiteColors.ink,
              fontSize: compact ? 43 : 59,
              height: 1.06,
              fontWeight: FontWeight.w800,
              letterSpacing: compact ? -1.6 : -2.6),
        ),
        const SizedBox(height: 20),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 510),
          child: Text(
              'Auto-generate accurate captions, edit every line, and style them to match your content.',
              textAlign: textAlign,
              style: const TextStyle(
                  color: SiteColors.muted, fontSize: 18, height: 1.65)),
        ),
        const SizedBox(height: 26),
        _MainCta(centered: centered),
        const SizedBox(height: 25),
        Wrap(
          alignment: centered ? WrapAlignment.center : WrapAlignment.start,
          spacing: 20,
          runSpacing: 12,
          children: const [
            _Benefit('Fast & Accurate'),
            _Benefit('Fully Editable'),
            _Benefit('HD Export'),
          ],
        ),
      ],
    );
  }
}

class _MainCta extends StatelessWidget {
  const _MainCta({required this.centered});
  final bool centered;

  @override
  Widget build(BuildContext context) => Align(
        alignment: centered ? Alignment.center : Alignment.centerLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: SiteColors.purple,
            borderRadius: BorderRadius.circular(15),
            boxShadow: [
              BoxShadow(
                  color: SiteColors.purple.withOpacity(.23),
                  blurRadius: 22,
                  offset: const Offset(0, 10))
            ],
          ),
          child: FilledButton.icon(
            onPressed: () => context.go('/register'),
            icon: const Icon(Icons.play_arrow_rounded, size: 24),
            label: const Text('Get Started',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            style: FilledButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 27, vertical: 18),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15))),
          ),
        ),
      );
}

class _Benefit extends StatelessWidget {
  const _Benefit(this.label);
  final String label;

  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.check_rounded, color: SiteColors.purple, size: 19),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(
                color: SiteColors.ink, fontWeight: FontWeight.w600)),
      ]);
}

class _EditorPreview extends StatelessWidget {
  const _EditorPreview();

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 620;
    return Container(
      padding: EdgeInsets.all(compact ? 9 : 12),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(23),
          border: Border.all(color: SiteColors.border, width: 2),
          boxShadow: [
            BoxShadow(
                color: SiteColors.purple.withOpacity(.10),
                blurRadius: 35,
                offset: const Offset(0, 17))
          ]),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: const BoxDecoration(
              color: Color(0xFF191927),
              borderRadius: BorderRadius.vertical(top: Radius.circular(13))),
          child: Row(children: [
            const SiteBrand(compact: true),
            const Spacer(),
            if (!compact)
              const Text('My Video  /  Edit',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
            const Spacer(),
            const _TinyButton('Export')
          ]),
        ),
        // This row is inside a vertical scroll view and has no finite height
        // to stretch against. Stretching gives the editor rails unbounded
        // height constraints and leaves the desktop canvas blank.
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!compact) const _ToolRail(),
          Expanded(
            flex: 3,
            child: Padding(
              padding: EdgeInsets.all(compact ? 8 : 12),
              child: Column(children: [
                AspectRatio(
                  aspectRatio: 1.52,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        const DecoratedBox(
                          decoration: BoxDecoration(color: Color(0xFF55506C)),
                        ),
                        Positioned(
                          left: 22,
                          top: 22,
                          child: Container(
                            width: 90,
                            height: 112,
                            decoration: BoxDecoration(
                                color: const Color(0xFF45604A),
                                borderRadius: BorderRadius.circular(45)),
                          ),
                        ),
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 13, vertical: 10),
                            decoration: BoxDecoration(
                                color: Colors.black.withOpacity(.62),
                                borderRadius: BorderRadius.circular(8)),
                            child: const Text(
                                'Create engaging videos\nwith auto captions.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    height: 1.25)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 9),
                Row(children: [
                  const Icon(Icons.play_arrow_rounded, color: SiteColors.ink),
                  const SizedBox(width: 8),
                  const Text('0:00 / 0:30',
                      style: TextStyle(fontSize: 12, color: SiteColors.ink)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: const LinearProgressIndicator(
                              value: .43,
                              minHeight: 5,
                              color: SiteColors.purple,
                              backgroundColor: Color(0xFFE2DDEB)))),
                  const SizedBox(width: 11),
                  const Icon(Icons.closed_caption_rounded,
                      color: SiteColors.ink),
                  const SizedBox(width: 7),
                  const Icon(Icons.fullscreen_rounded, color: SiteColors.ink)
                ]),
              ]),
            ),
          ),
          if (!compact) const _StyleRail(),
        ]),
      ]),
    );
  }
}

class _TinyButton extends StatelessWidget {
  const _TinyButton(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
          color: SiteColors.purple, borderRadius: BorderRadius.circular(8)),
      child: Text(label,
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)));
}

class _ToolRail extends StatelessWidget {
  const _ToolRail();
  @override
  Widget build(BuildContext context) => Container(
      width: 112,
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
          color: Color(0xFFF9F8FC),
          borderRadius: BorderRadius.only(bottomLeft: Radius.circular(12))),
      child:
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('▣  Captions',
            style: TextStyle(
                color: SiteColors.purple,
                fontSize: 12,
                fontWeight: FontWeight.w700)),
        SizedBox(height: 18),
        Text('A   Style', style: TextStyle(fontSize: 12)),
        SizedBox(height: 17),
        Text('◈  Animation', style: TextStyle(fontSize: 12)),
        SizedBox(height: 17),
        Text('T   Font', style: TextStyle(fontSize: 12)),
        SizedBox(height: 17),
        Text('◉  Color', style: TextStyle(fontSize: 12))
      ]));
}

class _StyleRail extends StatelessWidget {
  const _StyleRail();
  @override
  Widget build(BuildContext context) => Container(
        width: 160,
        padding: const EdgeInsets.all(13),
        decoration: const BoxDecoration(
            color: Color(0xFFF9F8FC),
            borderRadius: BorderRadius.only(bottomRight: Radius.circular(12))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Expanded(child: _StyleTab('Style', selected: true)),
            Expanded(child: _StyleTab('Text'))
          ]),
          const SizedBox(height: 13),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: List.generate(
                6,
                (index) => Container(
                      width: 38,
                      height: 33,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: index == 0
                              ? SiteColors.purple
                              : const Color(0xFF292936),
                          borderRadius: BorderRadius.circular(6)),
                      child: const Text('Aa',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                    )),
          ),
          const SizedBox(height: 17),
          const Text('Font    Inter',
              style: TextStyle(fontSize: 11, color: SiteColors.ink)),
          const SizedBox(height: 17),
          const Text('Size     ━━━━━',
              style: TextStyle(fontSize: 11, color: SiteColors.ink)),
          const SizedBox(height: 17),
          const Text('Color    ◻',
              style: TextStyle(fontSize: 11, color: SiteColors.ink)),
        ]),
      );
}

class _StyleTab extends StatelessWidget {
  const _StyleTab(this.label, {this.selected = false});
  final String label;
  final bool selected;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
          color: selected ? SiteColors.lavender : Colors.transparent,
          borderRadius: BorderRadius.circular(6)),
      alignment: Alignment.center,
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              color: selected ? SiteColors.purple : SiteColors.ink,
              fontWeight: FontWeight.w600)));
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();
  @override
  Widget build(BuildContext context) => Container(
      width: double.infinity,
      color: const Color(0xFFFAF8FD),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 58),
      child: Column(children: [
        Text('From video to share-ready',
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(color: SiteColors.ink, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        const Text('A simple workflow for clearer, more engaging videos.',
            style: TextStyle(color: SiteColors.muted)),
        const SizedBox(height: 28),
        Wrap(
            spacing: 18,
            runSpacing: 18,
            alignment: WrapAlignment.center,
            children: const [
              _Step('01', Icons.upload_file_rounded, 'Upload your video'),
              _Step('02', Icons.closed_caption_rounded,
                  'Edit and style captions'),
              _Step('03', Icons.ios_share_rounded, 'Export in HD')
            ])
      ]));
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.icon, this.title);
  final String number;
  final IconData icon;
  final String title;
  @override
  Widget build(BuildContext context) => Container(
      width: 260,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: SiteColors.border),
          borderRadius: BorderRadius.circular(15)),
      child: Row(children: [
        Icon(icon, color: SiteColors.purple),
        const SizedBox(width: 13),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(number,
              style: const TextStyle(
                  color: SiteColors.purple,
                  fontSize: 11,
                  fontWeight: FontWeight.w800)),
          Text(title,
              style: const TextStyle(
                  color: SiteColors.ink, fontWeight: FontWeight.w700))
        ]))
      ]));
}
