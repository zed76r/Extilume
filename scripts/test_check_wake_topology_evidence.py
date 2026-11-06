import importlib.util
from pathlib import Path
import unittest

s = importlib.util.spec_from_file_location('wake', Path(__file__).with_name('check-wake-topology-evidence.py'))
D = importlib.util.module_from_spec(s)
s.loader.exec_module(D)


def event(stage, at, **extra):
    if stage in ('wakeTopologyWaiting', 'wakeTopologyReady'):
        external = int(stage == 'wakeTopologyReady')
        extra['recoveryTopology'] = dict(onlineDisplayCount=1 + external, activeDisplayCount=1 + external,
                                        activeBuiltInCount=1, activePhysicalCount=external, activeOtherCount=0)
    return dict(type='internal-lifecycle', clock='mach_continuous_time/ns', role='controller',
                stage=stage, continuousNs=at, **extra)


def document():
    return dict(wakeNanoseconds=100, events=[
        event('wakeTopologyCheckStarted', 101), event('wakeTopologyWaiting', 102),
        event('wakeTopologyCheckStarted', 103), event('wakeTopologyReady', 104, succeeded=True)])


class WakeEvidenceTests(unittest.TestCase):
    def test_wait_then_ready_only_proves_supplied_branch_markers(self):
        result = D.assess(document())
        self.assertEqual(result['branchCoverage'], 'covered')
        self.assertEqual((result['checks'], result['waits']), (2, 1))
        self.assertFalse(result['hardwareAcceptance'])
        self.assertFalse(result['recoveryAcceptance'])
        self.assertFalse(result['candidateAndProcessBindingVerified'])

    def test_recovery_writes_after_ready_are_outside_readiness_check(self):
        value = document()
        value['events'].append(event('enableStarted', 20_000_000_000))
        self.assertEqual(D.assess(value)['branchCoverage'], 'covered')

    def test_immediate_ready_is_not_wait_coverage(self):
        value = document(); value['events'] = value['events'][2:]
        self.assertEqual(D.assess(value)['branchCoverage'], 'not-observed')

    def test_ready_requires_complete_anonymous_topology(self):
        for bad in (0, True):
            value = document()
            value['events'][-1]['recoveryTopology']['activePhysicalCount'] = bad
            with self.assertRaises(ValueError): D.assess(value)

    def test_missing_terminal_is_incomplete(self):
        value = document(); value['events'].pop()
        self.assertEqual(D.assess(value)['branchCoverage'], 'incomplete')

    def test_rejection_never_becomes_success(self):
        value = document(); value['events'][-1] = event('wakeTopologyRejected', 104, succeeded=False, failureCode='identity-conflict')
        self.assertEqual(D.assess(value)['branchCoverage'], 'rejected')
        value['events'].append(event('wakeTopologyReady', 105, succeeded=True))
        with self.assertRaises(ValueError): D.assess(value)

    def test_wrong_role_clock_order_deadline_and_result_reject(self):
        for field, bad in [('role', 'helper'), ('clock', 'wall-clock'), ('continuousNs', 99),
                           ('continuousNs', 10_000_000_100), ('continuousNs', True),
                           ('succeeded', False), ('stage', 'wakeTopologyInvented')]:
            with self.subTest(field=field, bad=bad):
                value = document(); value['events'][-1][field] = bad
                with self.assertRaises(ValueError): D.assess(value)

    def test_orphan_duplicate_and_write_during_wait_reject(self):
        for alteration in ('orphan', 'duplicate', 'write', 'resleep', 'fault'):
            value = document()
            if alteration == 'orphan': value['events'].pop(2)
            elif alteration == 'duplicate': value['events'].insert(1, event('wakeTopologyCheckStarted', 101))
            else: value['events'].insert(2, event({'write': 'enableStarted', 'resleep': 'sleepRequested', 'fault': 'restorationFailed'}[alteration], 102))
            with self.subTest(alteration=alteration), self.assertRaises(ValueError): D.assess(value)


if __name__ == '__main__': unittest.main()
