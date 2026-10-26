/// The first-run sequence: one modal per step instead of the setup list.
/// Which step comes next is derived from what the App knows and what the
/// user answered, so quitting mid-way resumes at the right modal.
enum FirstRunStep {
  welcome,
  deviceKind,
  connectAi,
  joinDevice,
  vault,
  oldVault,
  backup,
  obsidian,
  notifications,
  done,
}

/// What the App can observe now (connection, pairing, vault, reports).
class FirstRunFacts {
  const FirstRunFacts({
    this.hasKey = false,
    this.registered = false,
    this.vaultChosen = false,
    this.backupReady = false,
    this.obsidianChecked = false,
  });
  final bool hasKey;

  /// This device holds a device identity (original or paired).
  final bool registered;
  final bool vaultChosen;

  /// Backup verified or reported, and the local import copy kept.
  final bool backupReady;

  /// The user reported all four Obsidian checks; never App-verified.
  final bool obsidianChecked;
}

/// The user's answers on this device, kept across launches.
class FirstRunAnswers {
  const FirstRunAnswers({
    this.started = false,
    this.firstDevice,
    this.hasOldVault,
    this.notificationsAsked = false,
    this.finished = false,
    this.skipped = const {},
  });
  final bool started;
  final bool? firstDevice;
  final bool? hasOldVault;

  /// The permission was requested; this is not a notification test.
  final bool notificationsAsked;
  final bool finished;

  /// Steps the user put off with 稍后 in this pass through the sequence.
  final Set<FirstRunStep> skipped;

  FirstRunAnswers copyWith({
    bool? started,
    bool? firstDevice,
    bool? hasOldVault,
    bool? notificationsAsked,
    bool? finished,
    Set<FirstRunStep>? skipped,
  }) => FirstRunAnswers(
    started: started ?? this.started,
    firstDevice: firstDevice ?? this.firstDevice,
    hasOldVault: hasOldVault ?? this.hasOldVault,
    notificationsAsked: notificationsAsked ?? this.notificationsAsked,
    finished: finished ?? this.finished,
    skipped: skipped ?? this.skipped,
  );

  /// 稍后. The vault step cannot be put off.
  FirstRunAnswers skip(FirstRunStep step) =>
      step == FirstRunStep.vault ? this : copyWith(skipped: {...skipped, step});

  FirstRunAnswers finish() => copyWith(finished: true);

  /// 继续 from the banner: walk the unfinished steps again.
  FirstRunAnswers reopen() => copyWith(finished: false, skipped: const {});

  Map<String, Object?> toJson() => {
    'started': started,
    'firstDevice': firstDevice,
    'hasOldVault': hasOldVault,
    'notificationsAsked': notificationsAsked,
    'finished': finished,
    'skipped': [for (final step in skipped) step.name],
  };

  factory FirstRunAnswers.fromJson(Map<String, dynamic> json) =>
      FirstRunAnswers(
        started: json['started'] == true,
        firstDevice: json['firstDevice'] as bool?,
        hasOldVault: json['hasOldVault'] as bool?,
        notificationsAsked: json['notificationsAsked'] == true,
        finished: json['finished'] == true,
        skipped: {
          for (final name in (json['skipped'] as List?) ?? const [])
            ...FirstRunStep.values.where((step) => step.name == name),
        },
      );
}

/// Nothing stored and the device already has a vault or a device identity:
/// it was set up before this sequence existed, so it is not shown.
FirstRunAnswers firstRunAtLaunch(
  FirstRunAnswers? stored, {
  required bool existingInstall,
}) =>
    stored ??
    (existingInstall
        ? const FirstRunAnswers(started: true, finished: true)
        : const FirstRunAnswers());

/// Steps after the device question that are not done yet, in sequence order.
List<FirstRunStep> _unfinished(FirstRunAnswers answers, FirstRunFacts facts) {
  final hasOldVault = answers.hasOldVault;
  return [
    if (!facts.hasKey || !facts.registered)
      answers.firstDevice == false
          ? FirstRunStep.joinDevice
          : FirstRunStep.connectAi,
    if (!facts.vaultChosen) FirstRunStep.vault,
    if (hasOldVault == null) FirstRunStep.oldVault,
    if (hasOldVault == true && !facts.backupReady) FirstRunStep.backup,
    if (!facts.obsidianChecked) FirstRunStep.obsidian,
    if (!answers.notificationsAsked) FirstRunStep.notifications,
  ];
}

FirstRunStep? nextFirstRunStep(FirstRunAnswers answers, FirstRunFacts facts) {
  if (answers.finished) return null;
  if (!answers.started) return FirstRunStep.welcome;
  if (answers.firstDevice == null) return FirstRunStep.deviceKind;
  for (final step in _unfinished(answers, facts)) {
    if (!answers.skipped.contains(step)) return step;
  }
  return FirstRunStep.done;
}

/// What the banner counts after the sequence: unfinished steps, wherever
/// they were put off. Done elsewhere (e.g. in Settings) means not listed.
/// An install set up before the sequence existed was never asked, so it
/// gets no banner; the Settings page still shows its state.
List<FirstRunStep> outstandingFirstRunSteps(
  FirstRunAnswers answers,
  FirstRunFacts facts,
) => answers.firstDevice == null ? const [] : _unfinished(answers, facts);
