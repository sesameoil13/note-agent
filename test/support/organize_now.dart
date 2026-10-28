import 'package:note_agent/note_workspace.dart';

extension OrganizeNow on NoteWorkspace {
  /// Sends what is waiting for 整理 and returns [noteId]'s job.
  Future<WorkspaceTextJob> organizeNow(String noteId) async {
    await sendWaitingNow();
    return textJobs.firstWhere((j) => j.noteId == noteId && !j.reorganization);
  }
}
