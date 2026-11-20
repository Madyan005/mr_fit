import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/feedback/device_cue_output.dart';
import '../../data/feedback/foreground_keep_alive.dart';
import '../../domain/contracts/set_summary_payload.dart';
import '../../domain/metrics/metrics_session.dart';
import '../../domain/metrics/metrics_worker.dart';
import '../../domain/session/session_ports.dart';
import '../providers.dart';

final cueOutputProvider = Provider<CueOutput>((ref) => DeviceCueOutput());

final keepAliveProvider = Provider<KeepAlive>((ref) => ForegroundKeepAlive());

/// The app runs the engine in an Isolate; tests bind [InlineMetricsSession.start].
final metricsSessionFactoryProvider =
    Provider<MetricsSessionFactory>((ref) => (ctx, caps) async => MetricsWorker.start(ctx, caps));

/// Where a finished set goes: encrypted DB first, then the upload queue (5c).
final completedSetSinkProvider = Provider<Future<void> Function(SetSummaryPayload)>(
    (ref) => ref.watch(setRepositoryProvider).saveCompletedSet);
