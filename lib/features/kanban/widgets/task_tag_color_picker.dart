import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../../core/errors/app_exception.dart';
import '../models/task_tag.dart';
import '../utils/task_tag_color_utils.dart';
import '../viewmodels/kanban_view_model.dart';
import 'task_tag_chip.dart';

Future<TaskTag?> showTaskTagEditor(
  BuildContext context,
  KanbanViewModel viewModel, {
  TaskTag? tag,
}) => showDialog<TaskTag>(
  context: context,
  builder: (_) => _TagEditorDialog(viewModel: viewModel, tag: tag),
);

class _TagEditorDialog extends StatefulWidget {
  const _TagEditorDialog({required this.viewModel, this.tag});

  final KanbanViewModel viewModel;
  final TaskTag? tag;

  @override
  State<_TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<_TagEditorDialog> {
  late final TextEditingController _name;
  late String _colorHex;
  bool _saving = false;
  bool _isShowingCustomColor = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.tag?.name ?? '');
    _colorHex = TaskTagColorUtils.normalize(
      widget.tag?.colorHex ?? TaskTag.defaultColorHex,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _customColor() async {
    if (_isShowingCustomColor || _saving) return;
    setState(() => _isShowingCustomColor = true);
    try {
      final selected = await showDialog<String>(
        context: context,
        builder: (_) => _CustomColorDialog(initialHex: _colorHex),
      );
      if (selected == null || !mounted) return;
      setState(() => _colorHex = selected);
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Custom color ${selected.substring(1)} selected',
        TextDirection.ltr,
      );
    } finally {
      if (mounted) setState(() => _isShowingCustomColor = false);
    }
  }

  Future<void> _save() async {
    if (_saving || widget.viewModel.isSaving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final name = _name.text.trim();
      final tag = widget.tag;
      final ok = tag == null
          ? await widget.viewModel.createTag(name, _colorHex)
          : await widget.viewModel.updateTag(tag, name, _colorHex);
      if (!mounted) return;
      if (ok) {
        final saved = widget.viewModel.availableTags
            .where(
              (item) => tag == null
                  ? item.name.toLowerCase() == name.toLowerCase()
                  : item.id == tag.id,
            )
            .firstOrNull;
        AppRouter.back(context, saved);
      } else {
        setState(() {
          _error =
              widget.viewModel.errorMessage ?? AppErrorMessages.saveTagFailed;
        });
        widget.viewModel.clearError();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = TaskTag(
      id: 'preview',
      ownerId: '',
      name: _name.text.trim().isEmpty ? 'Tag preview' : _name.text.trim(),
      colorHex: _colorHex,
    );
    final custom = !predefinedTagColors.contains(_colorHex);
    return AlertDialog(
      title: Text(widget.tag == null ? 'Create Tag' : 'Edit Tag'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('tag-name-field'),
                controller: _name,
                autofocus: true,
                onChanged: (_) => setState(() => _error = null),
                decoration: const InputDecoration(labelText: 'Tag name'),
              ),
              const SizedBox(height: 16),
              Text(
                'Live preview',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              TaskTagChip(tag: current),
              const SizedBox(height: 18),
              Text(
                'Choose a color',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth < 260
                      ? 3
                      : constraints.maxWidth > 520
                      ? 6
                      : 4;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 8) / columns;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (
                        var index = 0;
                        index < predefinedTagColors.length;
                        index++
                      )
                        SizedBox(
                          width: width,
                          child: Center(
                            child: _ColorSwatch(
                              hex: predefinedTagColors[index],
                              name: predefinedTagColorNames[index],
                              selected: _colorHex == predefinedTagColors[index],
                              onTap: () {
                                setState(
                                  () => _colorHex = predefinedTagColors[index],
                                );
                                SemanticsService.sendAnnouncement(
                                  View.of(context),
                                  '${predefinedTagColorNames[index]}, selected',
                                  TextDirection.ltr,
                                );
                              },
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              Tooltip(
                message: 'Choose a custom tag color',
                child: OutlinedButton.icon(
                  key: const Key('custom-color-button'),
                  onPressed: _isShowingCustomColor || _saving
                      ? null
                      : _customColor,
                  icon: Icon(
                    Icons.palette_outlined,
                    color: TaskTagColorUtils.base(_colorHex),
                  ),
                  label: Text(
                    custom ? 'Custom Color · $_colorHex' : 'Custom Color',
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => AppRouter.back(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-tag-button'),
          onPressed: _saving ? null : _save,
          child: Text(widget.tag == null ? 'Create Tag' : 'Save Tag'),
        ),
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.hex,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String hex;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: name,
    child: Semantics(
      label: '$name, ${selected ? 'selected' : 'not selected'}',
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('tag-color-$hex'),
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Ink(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: TaskTagColorUtils.base(hex),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.onSurface
                    : TaskTagColorUtils.border(hex),
                width: selected ? 3 : 1.5,
              ),
            ),
            child: selected
                ? Center(
                    child: Icon(
                      Icons.check,
                      color: TaskTagColorUtils.mark(hex),
                      size: 25,
                    ),
                  )
                : null,
          ),
        ),
      ),
    ),
  );
}

class _CustomColorDialog extends StatefulWidget {
  const _CustomColorDialog({required this.initialHex});

  final String initialHex;

  @override
  State<_CustomColorDialog> createState() => _CustomColorDialogState();
}

class _CustomColorDialogState extends State<_CustomColorDialog> {
  late final TextEditingController _hex;
  late HSVColor _hsv;
  String? _error;

  @override
  void initState() {
    super.initState();
    _hex = TextEditingController(text: widget.initialHex);
    _hsv = HSVColor.fromColor(TaskTagColorUtils.base(widget.initialHex));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _setHsv(HSVColor color) {
    final rgb = color.toColor().toARGB32() & 0xFFFFFF;
    final hex = '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
    setState(() {
      _hsv = color;
      _hex.text = hex;
      _error = null;
    });
  }

  void _setHex(String input) {
    final normalized = TaskTag.normalizeHex(input);
    setState(() {
      _error = normalized == null ? AppErrorMessages.invalidTagColor : null;
      if (normalized != null) {
        _hsv = HSVColor.fromColor(TaskTagColorUtils.base(normalized));
      }
    });
  }

  void _setSaturationValue(Offset position, Size size) {
    final saturation = (position.dx / size.width).clamp(0.0, 1.0);
    final value = (1 - position.dy / size.height).clamp(0.0, 1.0);
    _setHsv(_hsv.withSaturation(saturation).withValue(value));
  }

  @override
  Widget build(BuildContext context) {
    final valid = TaskTag.normalizeHex(_hex.text);
    return AlertDialog(
      title: const Text('Custom Color'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(constraints.maxWidth, 172);
                  return GestureDetector(
                    key: const Key('saturation-value-picker'),
                    onTapDown: (details) =>
                        _setSaturationValue(details.localPosition, size),
                    onPanUpdate: (details) =>
                        _setSaturationValue(details.localPosition, size),
                    child: SizedBox(
                      height: size.height,
                      width: size.width,
                      child: CustomPaint(
                        painter: _SaturationValuePainter(_hsv),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 10),
              Text('Hue', style: Theme.of(context).textTheme.labelLarge),
              Slider(
                key: const Key('tag-hue-slider'),
                value: _hsv.hue,
                min: 0,
                max: 360,
                onChanged: (value) => _setHsv(_hsv.withHue(value)),
              ),
              const SizedBox(height: 8),
              Text(
                'Color preview',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              Container(
                key: const Key('custom-color-preview'),
                height: 62,
                decoration: BoxDecoration(
                  color: _hsv.toColor(),
                  border: Border.all(
                    color: TaskTagColorUtils.border(_hex.text),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('custom-hex-field'),
                controller: _hex,
                onChanged: _setHex,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#]')),
                  LengthLimitingTextInputFormatter(7),
                ],
                decoration: InputDecoration(
                  labelText: 'Hex color',
                  hintText: '#5C6BC0',
                  errorText: _error,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => AppRouter.back(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('apply-custom-color'),
          onPressed: valid == null
              ? null
              : () => AppRouter.back(context, valid),
          child: const Text('Apply Color'),
        ),
      ],
    );
  }
}

class _SaturationValuePainter extends CustomPainter {
  const _SaturationValuePainter(this.hsv);

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()..color = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.white, Colors.transparent],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    final point = Offset(
      hsv.saturation * size.width,
      (1 - hsv.value) * size.height,
    );
    canvas.drawCircle(point, 10, Paint()..color = Colors.white);
    canvas.drawCircle(
      point,
      10,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black87,
    );
  }

  @override
  bool shouldRepaint(_SaturationValuePainter oldDelegate) =>
      oldDelegate.hsv != hsv;
}
