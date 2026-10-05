import 'package:antgrid/update/update_check_result.dart';
import 'package:antgrid/update/update_install_controller.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:flutter/widgets.dart';

class FakeUpdateStrategy extends UpdateStrategy {
  FakeUpdateStrategy({
    this.activeBuild = true,
    this.result = UpdateCheckResult.upToDate,
    this.policy = UpdateCheckOutcome.updateAvailable,
  });
  bool activeBuild;
  UpdateCheckResult result;
  UpdateCheckOutcome policy;
  Future<UpdateCheckResult> Function()? onDetect;
  Future<void> Function()? onPrepare;
  int checks = 0;
  int preparations = 0;
  int installs = 0;
  int policies = 0;
  bool skipPending = false;
  String action = 'Update';
  @override
  String get rowActionLabel => action;
  @override
  bool get active => activeBuild;
  @override
  bool get skipAutomaticWhenPending => skipPending;
  @override
  Future<void> prepare() async {
    preparations++;
    await onPrepare?.call();
  }

  @override
  Future<UpdateCheckResult> detect() async {
    checks++;
    return await (onDetect?.call() ?? Future.value(result));
  }

  @override
  UpdateCheckOutcome automaticOutcome(UpdateCheckResult result) {
    policies++;
    return result.actionable ? policy : UpdateCheckOutcome.none;
  }

  @override
  Future<UpdateInstallResult> install(BuildContext context) async {
    installs++;
    return UpdateInstallResult.handedOff;
  }
}

class SpyUpdateInstallController extends UpdateInstallController {
  SpyUpdateInstallController({this.seed = const UpdateInstallIdle()});
  UpdateInstallState seed;
  int starts = 0;
  BuildContext? caller;
  bool? confirmed;
  void Function(BuildContext)? onStart;
  @override
  UpdateInstallState build() => seed;
  @override
  Future<void> start(BuildContext context, {bool confirm = true}) async {
    starts++;
    caller = context;
    confirmed = confirm;
    onStart?.call(context);
  }
}
