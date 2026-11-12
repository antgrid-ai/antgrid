import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../foundations/theme.dart';
import '../foundations/tokens.dart';
import 'button.dart';

/// Lets a host move focus to the first field that currently shows an error.
///
/// Validation is host-owned. The host decides which fields are invalid and
/// passes error text to them; this controller only knows which registered
/// fields are showing an error right now. Fields register through
/// [CarbonFormFieldRegistrar] (the library's text input and search do this
/// themselves), so a controller attached to a [CarbonForm] sees every
/// participating field below it.
///
/// Fields that are not built (for example, scrolled out of a lazy list) are
/// not registered and cannot be focused.
class CarbonFormController {
  final Set<_CarbonFormFieldRegistrarState> _fields =
      <_CarbonFormFieldRegistrarState>{};

  /// How many registered fields currently show an error.
  int get invalidFieldCount => _fields.where((f) => f.invalid).length;

  /// Scrolls the first invalid field, in visual order, into view and focuses
  /// it. Returns false when no registered field is invalid or none can take
  /// focus.
  ///
  /// Call after the host has applied its validation results and the frame
  /// that shows them has been built, for example from a post-frame callback
  /// or the next event handler. Moving focus makes a screen reader announce
  /// the field with its label and error.
  bool focusFirstInvalid() {
    final candidates = <_CarbonFormFieldRegistrarState>[
      for (final field in _fields)
        if (field.invalid && field.mounted && field.canFocus) field,
    ];
    if (candidates.isEmpty) return false;
    candidates.sort(_visualOrder);
    candidates.first.focus();
    return true;
  }

  static int _visualOrder(
    _CarbonFormFieldRegistrarState a,
    _CarbonFormFieldRegistrarState b,
  ) {
    final pa = a.globalOrigin;
    final pb = b.globalOrigin;
    if (pa == null || pb == null) {
      return pa == null ? (pb == null ? 0 : 1) : -1;
    }
    final byRow = pa.dy.compareTo(pb.dy);
    if (byRow != 0) return byRow;
    final rtl = Directionality.of(a.context) == TextDirection.rtl;
    return rtl ? pb.dx.compareTo(pa.dx) : pa.dx.compareTo(pb.dx);
  }
}

class _CarbonFormScope extends InheritedWidget {
  const _CarbonFormScope({required this.controller, required super.child});

  final CarbonFormController controller;

  @override
  bool updateShouldNotify(_CarbonFormScope old) =>
      !identical(old.controller, controller);
}

/// A vertical group of fields with Carbon's form spacing.
///
/// The form owns layout and discoverability only. It never validates, submits
/// or disables anything: the host passes `errorText` to fields, owns busy and
/// submission state, and calls [CarbonFormController.focusFirstInvalid] (on
/// the controller it supplies, or through [CarbonForm.of]) after showing
/// errors.
///
/// Required fields are marked by each field's own required marker. Set
/// [requiredNote] to add a form-level sentence above the fields explaining
/// the convention.
class CarbonForm extends StatefulWidget {
  const CarbonForm({
    super.key,
    required this.children,
    this.controller,
    this.requiredNote,
    this.spacing = CarbonSpacing.spacing07,
  });

  final List<Widget> children;

  /// Supplied by the host to call [CarbonFormController.focusFirstInvalid]
  /// from outside the form's subtree. The form creates one when null.
  final CarbonFormController? controller;

  /// Optional form-level sentence about required fields, shown first.
  final String? requiredNote;

  /// Gap between children.
  final double spacing;

  /// The nearest form's controller. Asserts when there is none.
  static CarbonFormController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'No CarbonForm found in the widget tree.');
    return controller!;
  }

  /// The nearest form's controller, or null outside a form.
  static CarbonFormController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_CarbonFormScope>()
      ?.controller;

  @override
  State<CarbonForm> createState() => _CarbonFormState();
}

class _CarbonFormState extends State<CarbonForm> {
  CarbonFormController? _owned;

  CarbonFormController get _controller =>
      widget.controller ?? (_owned ??= CarbonFormController());

  @override
  void didUpdateWidget(CarbonForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Fields re-register against the new controller when the scope changes;
    // the owned one is kept so a later switch back needs no new instance.
    if (widget.controller != null) _owned = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final note = widget.requiredNote;
    final items = <Widget>[
      if (note != null && note.isNotEmpty)
        Text(
          note,
          style: theme.typography.helper.copyWith(
            color: theme.colors.textSecondary,
          ),
        ),
      ...widget.children,
    ];
    return _CarbonFormScope(
      controller: _controller,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        role: SemanticsRole.form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < items.length; i++) ...<Widget>[
              if (i > 0) SizedBox(height: widget.spacing),
              items[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// A titled group of related fields inside a [CarbonForm].
///
/// The title is announced as a heading so assistive technology users can
/// jump between sections.
class CarbonFormSection extends StatelessWidget {
  const CarbonFormSection({
    super.key,
    required this.title,
    this.description,
    required this.children,
    this.spacing = CarbonSpacing.spacing06,
  });

  final String title;
  final String? description;
  final List<Widget> children;

  /// Gap between the fields of this section.
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final theme = CarbonTheme.of(context);
    final colors = theme.colors;
    final type = theme.typography;
    final description = this.description;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              title,
              style: type.heading.copyWith(color: colors.textPrimary),
            ),
          ),
          if (description != null && description.isNotEmpty) ...<Widget>[
            const SizedBox(height: CarbonSpacing.spacing02),
            Text(
              description,
              style: type.helper.copyWith(color: colors.textSecondary),
            ),
          ],
          const SizedBox(height: CarbonSpacing.spacing05),
          for (var i = 0; i < children.length; i++) ...<Widget>[
            if (i > 0) SizedBox(height: spacing),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// The action row of a form: a [CarbonButtonSet] aligned to the end edge.
///
/// Buttons stay host-owned, so the host sets `busy` or clears `onPressed` on
/// them while a submission runs. The set stacks vertically when the labels do
/// not fit.
class CarbonFormActions extends StatelessWidget {
  const CarbonFormActions({
    super.key,
    required this.children,
    this.alignment = CarbonButtonSetAlignment.end,
  });

  final List<Widget> children;
  final CarbonButtonSetAlignment alignment;

  @override
  Widget build(BuildContext context) =>
      CarbonButtonSet(alignment: alignment, children: children);
}

/// Opts a field into [CarbonFormController.focusFirstInvalid].
///
/// Wrap the field's frame in this. It reports whether the field currently
/// shows an error ([invalid], matching what the user sees: not for disabled
/// or read-only fields) and which [focusNode] to focus. Outside a
/// [CarbonForm] it does nothing, so a field can always use it.
class CarbonFormFieldRegistrar extends StatefulWidget {
  const CarbonFormFieldRegistrar({
    super.key,
    required this.invalid,
    required this.focusNode,
    required this.child,
    this.announcement,
  });

  final bool invalid;
  final FocusNode focusNode;

  /// Spoken when [CarbonFormController.focusFirstInvalid] targets a field that
  /// already has focus, where moving focus would announce nothing. Typically
  /// the field's label and error.
  final String? announcement;
  final Widget child;

  @override
  State<CarbonFormFieldRegistrar> createState() =>
      _CarbonFormFieldRegistrarState();
}

class _CarbonFormFieldRegistrarState extends State<CarbonFormFieldRegistrar> {
  CarbonFormController? _registeredWith;

  bool get invalid => widget.invalid;
  bool get canFocus => widget.focusNode.canRequestFocus;

  Offset? get globalOrigin {
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    return object.localToGlobal(Offset.zero);
  }

  void focus() {
    Scrollable.ensureVisible(
      context,
      alignment: 0.1,
      duration: Duration.zero,
    );
    final announcement = widget.announcement;
    if (widget.focusNode.hasFocus && announcement != null) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        announcement,
        Directionality.of(context),
      );
      return;
    }
    widget.focusNode.requestFocus();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = CarbonForm.maybeOf(context);
    if (identical(controller, _registeredWith)) return;
    _registeredWith?._fields.remove(this);
    _registeredWith = controller;
    controller?._fields.add(this);
  }

  @override
  void dispose() {
    _registeredWith?._fields.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
