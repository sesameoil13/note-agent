import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/first_run.dart';

void main() {
  test(
    'a new install starts at the welcome step, then asks which device this is',
    () {
      const facts = FirstRunFacts();
      expect(
        nextFirstRunStep(const FirstRunAnswers(), facts),
        FirstRunStep.welcome,
      );
      expect(
        nextFirstRunStep(const FirstRunAnswers(started: true), facts),
        FirstRunStep.deviceKind,
      );
    },
  );

  test(
    'the first device connects AI and registers; other devices join by pairing',
    () {
      const first = FirstRunAnswers(started: true, firstDevice: true);
      const other = FirstRunAnswers(started: true, firstDevice: false);
      expect(
        nextFirstRunStep(first, const FirstRunFacts()),
        FirstRunStep.connectAi,
      );
      // A saved key alone is not enough: the device must also be registered.
      expect(
        nextFirstRunStep(first, const FirstRunFacts(hasKey: true)),
        FirstRunStep.connectAi,
      );
      expect(
        nextFirstRunStep(
          first,
          const FirstRunFacts(hasKey: true, registered: true),
        ),
        FirstRunStep.vault,
      );
      expect(
        nextFirstRunStep(other, const FirstRunFacts()),
        FirstRunStep.joinDevice,
      );
      expect(
        nextFirstRunStep(
          other,
          const FirstRunFacts(hasKey: true, registered: true),
        ),
        FirstRunStep.vault,
      );
    },
  );

  test(
    'after the vault, only people with an old vault see the backup step',
    () {
      const connected = FirstRunFacts(
        hasKey: true,
        registered: true,
        vaultChosen: true,
      );
      const answered = FirstRunAnswers(started: true, firstDevice: true);
      expect(nextFirstRunStep(answered, connected), FirstRunStep.oldVault);

      const noOldVault = FirstRunAnswers(
        started: true,
        firstDevice: true,
        hasOldVault: false,
      );
      expect(nextFirstRunStep(noOldVault, connected), FirstRunStep.obsidian);

      const oldVault = FirstRunAnswers(
        started: true,
        firstDevice: true,
        hasOldVault: true,
      );
      expect(nextFirstRunStep(oldVault, connected), FirstRunStep.backup);
      expect(
        nextFirstRunStep(
          oldVault,
          const FirstRunFacts(
            hasKey: true,
            registered: true,
            vaultChosen: true,
            backupReady: true,
          ),
        ),
        FirstRunStep.obsidian,
      );
    },
  );

  test(
    'Obsidian checks and the notification request lead to the done step',
    () {
      const answers = FirstRunAnswers(
        started: true,
        firstDevice: true,
        hasOldVault: false,
      );
      const checked = FirstRunFacts(
        hasKey: true,
        registered: true,
        vaultChosen: true,
        obsidianChecked: true,
      );
      expect(nextFirstRunStep(answers, checked), FirstRunStep.notifications);
      const asked = FirstRunAnswers(
        started: true,
        firstDevice: true,
        hasOldVault: false,
        notificationsAsked: true,
      );
      expect(nextFirstRunStep(asked, checked), FirstRunStep.done);
      const finished = FirstRunAnswers(
        started: true,
        firstDevice: true,
        hasOldVault: false,
        notificationsAsked: true,
        finished: true,
      );
      expect(nextFirstRunStep(finished, checked), isNull);
    },
  );

  test(
    '稍后 moves on, except at the vault step, and leaves the step outstanding',
    () {
      const facts = FirstRunFacts();
      final skippedAi = const FirstRunAnswers(
        started: true,
        firstDevice: true,
      ).skip(FirstRunStep.connectAi);
      expect(nextFirstRunStep(skippedAi, facts), FirstRunStep.vault);
      // The vault cannot be skipped: without it there is nowhere to save notes.
      expect(
        nextFirstRunStep(skippedAi.skip(FirstRunStep.vault), facts),
        FirstRunStep.vault,
      );

      final allSkipped = skippedAi
          .skip(FirstRunStep.oldVault)
          .skip(FirstRunStep.obsidian)
          .skip(FirstRunStep.notifications);
      const withVault = FirstRunFacts(vaultChosen: true);
      expect(nextFirstRunStep(allSkipped, withVault), FirstRunStep.done);
      expect(outstandingFirstRunSteps(allSkipped, withVault), [
        FirstRunStep.connectAi,
        FirstRunStep.oldVault,
        FirstRunStep.obsidian,
        FirstRunStep.notifications,
      ]);
    },
  );

  test(
    '继续 from the banner reopens at the first unfinished step, not the welcome',
    () {
      final finished = const FirstRunAnswers(started: true, firstDevice: false)
          .skip(FirstRunStep.joinDevice)
          .skip(FirstRunStep.oldVault)
          .skip(FirstRunStep.obsidian)
          .skip(FirstRunStep.notifications)
          .finish();
      const facts = FirstRunFacts(vaultChosen: true);
      expect(nextFirstRunStep(finished, facts), isNull);
      expect(
        nextFirstRunStep(finished.reopen(), facts),
        FirstRunStep.joinDevice,
      );
    },
  );

  test('a step done elsewhere (e.g. in Settings) is no longer outstanding', () {
    final answers =
        const FirstRunAnswers(
              started: true,
              firstDevice: true,
              hasOldVault: false,
            )
            .skip(FirstRunStep.connectAi)
            .skip(FirstRunStep.obsidian)
            .skip(FirstRunStep.notifications)
            .finish();
    const facts = FirstRunFacts(
      hasKey: true,
      registered: true,
      vaultChosen: true,
      obsidianChecked: true,
    );
    expect(outstandingFirstRunSteps(answers, facts), [
      FirstRunStep.notifications,
    ]);
  });

  test('an install set up before this version never sees the sequence', () {
    expect(firstRunAtLaunch(null, existingInstall: true).finished, isTrue);
    expect(
      nextFirstRunStep(
        firstRunAtLaunch(null, existingInstall: false),
        const FirstRunFacts(),
      ),
      FirstRunStep.welcome,
    );
    // Someone mid-way through the sequence resumes it, even with a vault chosen.
    const midway = FirstRunAnswers(started: true, firstDevice: true);
    expect(firstRunAtLaunch(midway, existingInstall: true).finished, isFalse);
    // Nor a banner about questions they were never asked; Settings stays open.
    expect(
      outstandingFirstRunSteps(
        firstRunAtLaunch(null, existingInstall: true),
        const FirstRunFacts(vaultChosen: true),
      ),
      isEmpty,
    );
  });

  test('answers survive a restart', () {
    final answers = const FirstRunAnswers(
      started: true,
      firstDevice: false,
      hasOldVault: true,
    ).skip(FirstRunStep.joinDevice);
    final restored = FirstRunAnswers.fromJson(answers.toJson());
    expect(restored.started, isTrue);
    expect(restored.firstDevice, isFalse);
    expect(restored.hasOldVault, isTrue);
    expect(restored.skipped, {FirstRunStep.joinDevice});
    expect(restored.finished, isFalse);
  });

  test(
    'a failed check of the paired key resumes at the join step after restart',
    () {
      const paired = FirstRunFacts(hasKey: true, registered: true);
      final failed = FirstRunAnswers.fromJson(
        const FirstRunAnswers(
          started: true,
          firstDevice: false,
        ).copyWith(keyCheckFailed: true).toJson(),
      );
      expect(nextFirstRunStep(failed, paired), FirstRunStep.joinDevice);
      expect(
        outstandingFirstRunSteps(failed, paired),
        contains(FirstRunStep.joinDevice),
      );
      expect(
        nextFirstRunStep(failed.skip(FirstRunStep.joinDevice), paired),
        FirstRunStep.vault,
      );
    },
  );
}
