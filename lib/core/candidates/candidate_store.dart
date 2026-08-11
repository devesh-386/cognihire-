/// Persistence for real-pipeline candidates. Abstract for the same reason
/// [RoleStore]/[IntakeStore] are.
library;

import 'candidate.dart';

abstract class CandidateStore {
  Future<List<Candidate>> listCandidates();
}

class InMemoryCandidateStore implements CandidateStore {
  const InMemoryCandidateStore([this._candidates = const []]);

  final List<Candidate> _candidates;

  @override
  Future<List<Candidate>> listCandidates() async => _candidates;
}
