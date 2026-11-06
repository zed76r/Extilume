import importlib.util
import json
import os
import subprocess
import sys
from unittest.mock import patch
from pathlib import Path
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('recovery-batch-gate.py'))
G = importlib.util.module_from_spec(spec)
spec.loader.exec_module(G)


class BatchGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.root.chmod(0o700)
        self.exe = self.root/'fixture'; self.exe.write_bytes(b'fixture')
        self.binaries = {r: dict(executable=str(self.exe), sha256=G.D.digest(self.exe)) for r in G.ROLES}
        self.time = 0
        self.processes = {i: dict(pid=i, uid=os.getuid(), parentPID=i-1, startSeconds=10,
                                 startMicroseconds=1, executable=str(self.exe)) for i in (10, 11, 12)}
        self.candidate = str(uuid.uuid4())
        self.gate = G.RecoveryBatchGate(self.root, self.candidate, 'a'*64, self.binaries,
                                       lambda: self.time, lambda pid: self.processes[pid])
        self.addCleanup(self.gate.close)
        for role,pid in zip(G.ROLES,(10,11,12)): self.gate.bind(role,self.processes[pid])

    def events(self):
        return [json.loads(x) for x in (self.root/(self.candidate+'.jsonl')).read_text().splitlines()]

    def test_full_sequence_consumes_before_every_dispatch(self):
        for action in G.ACTIONS:
            def send():
                self.assertEqual(self.events()[-1], dict(event='consume-before-request',action=action))
                return True
            self.gate.request(action,send,lambda:True)
        self.assertEqual([x['action'] for x in self.events() if x['event']=='consume-before-request'],list(G.ACTIONS))

    def test_failed_dispatch_cannot_retry_or_advance(self):
        with self.assertRaisesRegex(RuntimeError,'action-not-accepted'): self.gate.request('start',lambda: False,lambda:True)
        for action in ('start','restore'):
            with self.assertRaisesRegex(RuntimeError,'batch-stopped'):
                self.gate.request(action,lambda: self.fail('must not dispatch'),lambda:True)
        self.assertEqual(sum(x['event']=='consume-before-request' for x in self.events()),1)

    def test_reopening_same_candidate_cannot_reset_budget(self):
        self.gate.close()
        with self.assertRaises(FileExistsError):
            G.RecoveryBatchGate(self.root,self.candidate,'b'*64,self.binaries,lambda:0,lambda _:None)

    def test_reused_pid_is_rejected_before_dispatch(self):
        self.processes[10]['startMicroseconds']=2
        with self.assertRaisesRegex(RuntimeError,'process-reused-or-changed'):
            self.gate.request('start',lambda: self.fail('must not dispatch'),lambda:True)
        self.assertFalse(any(x['event']=='consume-before-request' for x in self.events()))

    def test_binary_replacement_is_rejected(self):
        self.exe.write_bytes(b'replaced')
        with self.assertRaisesRegex(RuntimeError,'candidate-binary-mismatch'):
            self.gate.request('start',lambda: self.fail('must not dispatch'),lambda:True)

    def test_late_result_stops_and_remains_consumed(self):
        def send(): self.time=180*G.D.NS; return True
        with self.assertRaisesRegex(RuntimeError,'batch-deadline'): self.gate.request('start',send,lambda:True)
        self.assertEqual(self.gate.next_action,1)
        self.assertFalse(any(x['event']=='action-confirmed' for x in self.events()))

    def test_invalid_order_and_recursive_dispatch_stop(self):
        def send():
            self.gate.request('restore',lambda: self.fail('nested dispatch'),lambda:True)
            return True
        with self.assertRaisesRegex(RuntimeError,'action-order-or-quota'): self.gate.request('start',send,lambda:True)
        self.assertTrue(self.gate.stopped)

    def test_journal_failure_prevents_dispatch(self):
        def fail(_): raise OSError('fixture')
        self.gate.journal.append=fail
        with self.assertRaises(OSError): self.gate.request('start',lambda: self.fail('must not dispatch'),lambda:True)
        self.assertTrue(self.gate.stopped)
        self.gate.journal.append=lambda _:None

    def test_parent_and_uid_are_in_process_binding(self):
        self.processes[10]['parentPID']=999
        with self.assertRaisesRegex(RuntimeError,'process-reused-or-changed'):
            self.gate.request('start',lambda: self.fail('must not dispatch'),lambda:True)
        value=dict(self.processes[10],uid=os.getuid()+1)
        with self.assertRaisesRegex(RuntimeError,'invalid-process-binding'): G.process_key(value)

    def test_wake_deadline_is_the_earlier_absolute_limit(self):
        for action in G.ACTIONS[:3]: self.gate.request(action,lambda:True,lambda:True)
        self.time=175*G.D.NS
        self.gate.request('sleep',lambda:True,lambda:True)
        self.gate.observe_wake(self.time)
        self.assertEqual(self.gate.deadline,180*G.D.NS)
        self.time=180*G.D.NS
        with self.assertRaisesRegex(RuntimeError,'batch-deadline'):
            self.gate.request('stop',lambda:self.fail('late dispatch'),lambda:True)

    def test_wake_has_ten_seconds_and_cannot_be_reset(self):
        for action in G.ACTIONS[:4]: self.gate.request(action,lambda:True,lambda:True)
        self.time=20*G.D.NS
        self.gate.observe_wake(self.time)
        self.assertEqual(self.gate.deadline,30*G.D.NS)
        with self.assertRaisesRegex(RuntimeError,'invalid-wake-boundary'):self.gate.observe_wake(self.time)
        self.assertTrue(self.gate.stopped)

    def test_slow_confirmation_journal_stops_before_return(self):
        append = self.gate.journal.append
        def slow(event):
            append(event)
            if event['event'] == 'action-confirmed': self.time = 180 * G.D.NS
        self.gate.journal.append = slow
        with self.assertRaisesRegex(RuntimeError, 'batch-deadline'):
            self.gate.request('start', lambda: True, lambda: True)
        self.assertTrue(self.gate.stopped)

    def test_wake_before_sleep_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError,'invalid-wake-boundary'):self.gate.observe_wake(0)

    def test_acceptance_does_not_confirm_completion(self):
        with self.assertRaisesRegex(RuntimeError, 'action-not-confirmed'):
            self.gate.request('start', lambda: True, lambda: False)
        self.assertTrue(any(x['event'] == 'action-accepted' for x in self.events()))
        self.assertFalse(any(x['event'] == 'action-confirmed' for x in self.events()))
        self.assertTrue(self.gate.stopped)

    def test_late_verification_never_confirms(self):
        def verify():
            self.time = 180 * G.D.NS
            return True
        with self.assertRaisesRegex(RuntimeError, 'batch-deadline'):
            self.gate.request('start', lambda: True, verify)
        self.assertFalse(any(x['event'] == 'action-confirmed' for x in self.events()))

    def test_process_change_during_verification_rejects_completion(self):
        def verify():
            self.processes[11]['startMicroseconds'] += 1
            return True
        with self.assertRaisesRegex(RuntimeError, 'process-reused-or-changed'):
            self.gate.request('start', lambda: True, verify)
        self.assertFalse(any(x['event'] == 'action-confirmed' for x in self.events()))

    def test_structured_app_and_native_evidence_drive_gate_completion(self):
        self.time = 100
        reply, events = application_evidence('start')
        def verify():
            self.time = 200
            return self.gate.verify_application('start', reply, events)
        self.gate.request('start', lambda: True, verify)
        self.assertEqual(self.events()[-1], dict(event='action-confirmed', action='start'))

    def test_missing_verifier_stops_before_dispatch(self):
        with self.assertRaisesRegex(RuntimeError, 'missing-action-adapter'):
            self.gate.request('start', lambda: self.fail('must not dispatch'), None)
        self.assertFalse(any(x['event'] == 'consume-before-request' for x in self.events()))

    def test_caught_completion_failure_cannot_be_overridden(self):
        def verify():
            try: self.gate.verify_application('start', dict(result='accepted'), [])
            except RuntimeError: pass
            return True
        with self.assertRaisesRegex(RuntimeError, 'batch-stopped'):
            self.gate.request('start', lambda: True, verify)
        self.assertFalse(any(x['event'] == 'action-confirmed' for x in self.events()))

    def test_failed_completion_close_retains_consumption_and_role_bindings(self):
        with self.assertRaisesRegex(RuntimeError, 'action-not-confirmed'):
            self.gate.request('start', lambda: True, lambda: False)
        self.gate.close()
        end = self.events()[-1]
        self.assertEqual(end['consumed'], 1)
        self.assertEqual(end['confirmed'], 0)
        self.assertEqual(end['unconfirmedAction'], 'start')
        self.assertEqual(set(self.gate.roles), set(G.ROLES))
        self.assertEqual(end['controllerCleanup'], 'requires-bound-safety-handoff')

    def test_close_is_idempotent_and_does_not_dispatch_cleanup(self):
        self.gate.close();self.gate.close()
        self.assertEqual(self.events()[-1]['controllerCleanup'],'requires-bound-safety-handoff')
        with self.assertRaisesRegex(RuntimeError,'batch-stopped'): self.gate.request('start',lambda:True,lambda:True)


def application_evidence(action):
    state = 'applied' if action == 'start' else 'manualConfiguration'
    reply = dict(result='status', sessionState={state: {}}, selectedMode='externalOnly',
                 stateMode='externalOnly', requiresExplicitActivation=False)
    stages = ('disableStarted', 'disableFinished') if action == 'start' else (
        'restorationStarted', 'restorationVerified', 'pauseVerificationStarted', 'pauseVerificationFinished')
    events = [dict(type='internal-lifecycle', role='controller', clock='mach_continuous_time/ns',
                   stage=stage, continuousNs=110 + index) for index, stage in enumerate(stages)]
    if action == 'start':
        events[0]['operation'] = 'disable'
        events[-1].update(succeeded=True, operation='disable')
    return reply, events


class ApplicationCheckpointTests(unittest.TestCase):
    def assess(self, action, reply, events):
        return G.application_checkpoint(action, reply, events, 100, 200, 300)

    def test_start_and_restore_require_both_sources(self):
        for action in ('start', 'restore'):
            reply, events = application_evidence(action)
            self.assertTrue(self.assess(action, reply, events))
            with self.assertRaisesRegex(RuntimeError, 'completion-endpoint-missing'):
                self.assess(action, reply, events[:-1])

    def test_accepted_and_legacy_status_are_insufficient(self):
        for reply in (dict(result='accepted'), dict(result='status', status='外屏已生效')):
            with self.assertRaisesRegex(RuntimeError, 'application-not-completed'):
                self.assess('start', reply, application_evidence('start')[1])

    def test_intent_mismatch_or_pending_activation_is_rejected(self):
        for change in (dict(stateMode='externalPrimary'), dict(requiresExplicitActivation=True),
                       dict(sessionState={'applying': {}}), dict(sessionState={'recoveryIncomplete': {}})):
            reply, events = application_evidence('start')
            reply.update(change)
            with self.assertRaisesRegex(RuntimeError, 'application-not-completed'):
                self.assess('start', reply, events)

    def test_stale_future_reordered_and_wrong_role_events_are_rejected(self):
        for change in (dict(continuousNs=99), dict(continuousNs=201), dict(role='helper'),
                       dict(clock='wall-clock'), dict(continuousNs=True)):
            reply, events = application_evidence('start')
            events[0].update(change)
            with self.assertRaises(RuntimeError): self.assess('start', reply, events)
        reply, events = application_evidence('start')
        events.reverse()
        with self.assertRaises(RuntimeError): self.assess('start', reply, events)

    def test_failure_after_endpoint_still_rejects(self):
        for stage in ('firstConnectionInvalidation', 'sleepRequested', 'restorationFailed', 'disableFailed'):
            reply, events = application_evidence('start')
            events.append(dict(events[0], stage=stage, continuousNs=150))
            with self.assertRaisesRegex(RuntimeError, 'completion-fault'):
                self.assess('start', reply, events)

    def test_disable_must_return_success_and_occur_only_once(self):
        reply, events = application_evidence('start')
        events[-1].pop('succeeded')
        with self.assertRaisesRegex(RuntimeError, 'disable-not-confirmed'):
            self.assess('start', reply, events)
        reply, events = application_evidence('start')
        events.append(dict(events[-1], continuousNs=150))
        with self.assertRaisesRegex(RuntimeError, 'completion-event-order'):
            self.assess('start', reply, events)

    def test_restore_rejects_any_new_disable(self):
        reply, events = application_evidence('restore')
        events.append(dict(events[-1], stage='disableStarted', continuousNs=150))
        with self.assertRaisesRegex(RuntimeError, 'unexpected-disable'):
            self.assess('restore', reply, events)

    def test_human_confirmation_sleep_and_exit_need_separate_proof(self):
        for action in ('confirm-user', 'sleep', 'stop'):
            with self.assertRaisesRegex(RuntimeError, 'unsupported-application-checkpoint'):
                self.assess(action, *application_evidence('start'))

    def test_deadline_cannot_be_used_as_a_success_endpoint(self):
        with self.assertRaisesRegex(RuntimeError, 'invalid-completion-window'):
            G.application_checkpoint('start', *application_evidence('start'), 100, 300, 300)


class KernelIdentityTests(unittest.TestCase):
    def test_reused_process_during_read_is_rejected(self):
        before = dict(pid=10, uid=os.getuid(), parentPID=9, startSeconds=10, startMicroseconds=1)
        with patch.object(G, '_read_process_info', side_effect=[before, dict(before, startMicroseconds=2)]), \
             patch.object(G.D.Mac, 'pid_path', return_value='/fixture'):
            with self.assertRaisesRegex(RuntimeError, 'process-reused-or-changed'):
                G.read_process_identity(10)

    def test_exec_changed_during_read_is_rejected(self):
        info = dict(pid=10, uid=os.getuid(), parentPID=9, startSeconds=10, startMicroseconds=1)
        with patch.object(G, '_read_process_info', return_value=info), \
             patch.object(G.D.Mac, 'pid_path', side_effect=['/first', '/second']):
            with self.assertRaisesRegex(RuntimeError, 'process-reused-or-changed'):
                G.read_process_identity(10)

    def test_bad_pid_is_rejected_before_native_call(self):
        with patch.object(G, '_read_process_info') as read:
            for pid in (True, -1, 0, 1, 2**31, '10'):
                with self.assertRaisesRegex(RuntimeError, 'invalid-process-binding'):
                    G.read_process_identity(pid)
            read.assert_not_called()

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin kernel API')
    def test_gate_defaults_to_real_kernel_reader(self):
        identity = G.read_process_identity(os.getpid())
        binaries = {role: dict(executable=identity['executable'], sha256=G.D.digest(identity['executable']))
                    for role in G.ROLES}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            gate = G.RecoveryBatchGate(root, str(uuid.uuid4()), 'a'*64, binaries, lambda: 0)
            try:
                gate.bind('app', identity)
                self.assertEqual(gate.roles['app'], identity)
            finally:
                gate.close()

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin kernel API')
    def test_real_child_identity_and_exit(self):
        with subprocess.Popen(['/bin/cat'], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL) as child:
            first = G.read_process_identity(child.pid)
            self.assertEqual(first['parentPID'], os.getpid())
            self.assertEqual(first['uid'], os.getuid())
            self.assertEqual(Path(first['executable']).resolve(), Path('/bin/cat').resolve())
            self.assertEqual(G.read_process_identity(child.pid), first)
            child.stdin.close()
            child.wait(timeout=5)
            with self.assertRaisesRegex(RuntimeError, 'process-info-unavailable|process-exited-or-changed'):
                G.read_process_identity(child.pid)


if __name__ == '__main__': unittest.main()
