import importlib.util
import io
import json
import os
import subprocess
import sys
import time
from types import SimpleNamespace
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

    def launch_fixture(self):
        self.gate.roles.clear()
        state = self.root/'state'
        state.mkdir(mode=0o700)
        reader, writer = os.pipe()
        process = SimpleNamespace(pid=10, stdout=os.fdopen(reader, 'rb'), fixture_writer=writer)
        def cleanup():
            if process.fixture_writer is not None:
                os.close(process.fixture_writer)
            if self.gate.stream:
                self.gate.stream.thread.join(timeout=1)
            self.gate.close()
            process.stdout.close()
        self.addCleanup(cleanup)
        def spawn(args, **kwargs):
            self.assertEqual(args, [str(self.exe), '--recovery-batch', '--state-directory', str(state)])
            self.assertEqual(kwargs['stdout'], subprocess.PIPE)
            self.assertEqual(kwargs['stderr'], subprocess.DEVNULL)
            self.assertTrue(kwargs['start_new_session'])
            self.assertEqual(Path(kwargs['env']['EXTILUME_RECOVERY_BATCH_DIRECTORY']), self.gate.native_budget_directory)
            self.assertEqual(self.events()[-1]['event'], 'consume-before-application-launch')
            return process
        self.gate.launch_application(state, str(uuid.uuid4()), spawn)
        return process

    def register_fixture(self, role, pid):
        value = {key: self.processes[pid][key] for key in ('pid', 'startSeconds', 'startMicroseconds')}
        G.D.save_new(self.gate.native_budget_directory/(role+'-process.json'), value)

    def test_launch_binds_own_pipe_and_waits_for_native_registration_and_standby(self):
        process = self.launch_fixture()
        self.assertIs(self.gate.application_process, process)
        self.assertEqual(self.gate.roles['app']['pid'], 10)
        self.register_fixture('app', 10)
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            self.assertEqual(args[1:3], ['--control', 'status'])
            self.assertNotIn('--allow-display-write', args)
            return SimpleNamespace(returncode=0, stdout=json.dumps(dict(result='status', sessionState={'waiting': {}},
                selectedMode='externalOnly', stateMode='externalOnly', requiresExplicitActivation=True)).encode())
        self.gate.wait_for_standby(wait=lambda: self.fail('already ready'), run=run)
        self.assertEqual(len(calls), 1)
        self.assertFalse((self.gate.native_budget_directory/'initial-authorized.json').exists())

    def test_native_owner_registration_requires_parent_and_start_identity(self):
        self.launch_fixture()
        self.register_fixture('owner', 11)
        self.gate.bind_registered_process('owner')
        self.register_fixture('helper', 12)
        self.processes[12]['startMicroseconds'] += 1
        with self.assertRaisesRegex(RuntimeError, 'stale-process-registration'):
            self.gate.bind_registered_process('helper')
        self.assertNotIn('helper', self.gate.roles)

    def test_existing_state_blocks_launch_before_spawn(self):
        self.gate.roles.clear()
        state = self.root/'state'
        state.mkdir(mode=0o700)
        (state/'keep').write_text('keep')
        with self.assertRaisesRegex(RuntimeError, 'batch-state-not-empty'):
            self.gate.launch_application(state, str(uuid.uuid4()), lambda *a, **k: self.fail('must not launch'))
        self.assertIsNone(self.gate.application_process)
        self.assertEqual((state/'keep').read_text(), 'keep')

    def test_launch_failure_is_consumed_and_not_retried(self):
        self.gate.roles.clear()
        state = self.root/'state'
        state.mkdir(mode=0o700)
        with self.assertRaises(OSError):
            self.gate.launch_application(state, str(uuid.uuid4()), lambda *a, **k: (_ for _ in ()).throw(OSError()))
        with self.assertRaisesRegex(RuntimeError, 'batch-stopped'):
            self.gate.launch_application(state, str(uuid.uuid4()), lambda *a, **k: self.fail('must not retry'))
        self.assertEqual(sum(x['event']=='consume-before-application-launch' for x in self.events()), 1)

    def test_confirmation_and_quit_use_consumed_action_transport(self):
        calls = []
        for action in G.ACTIONS:
            def send():
                if action == 'confirm-user':
                    self.gate.configuration_visual_at = self.time
                if action not in ('confirm-user', 'stop'):
                    return True
                def run(args, **kwargs):
                    calls.append(args[2])
                    self.assertIn('--allow-display-write', args)
                    return SimpleNamespace(returncode=0, stdout=b'{"result":"accepted"}')
                return self.gate.control_application(action, run)['result'] == 'accepted'
            self.gate.request(action, send, lambda: True)
        self.assertEqual(calls, ['confirm-configuration', 'quit'])

    def dialog_fixture(self, answer=b'normal', wait=False):
        process = SimpleNamespace(returncode=0, stdout=io.BytesIO(answer))
        process.poll = lambda: None if wait else 0
        process.communicate = lambda **kwargs: (answer, None)
        process.terminate = lambda: setattr(process, 'poll', lambda: 0)
        process.wait = lambda **kwargs: 0
        return process

    def test_confirmation_requires_current_human_answer_and_is_once_only(self):
        for action in ('start', 'restore'):
            self.gate.request(action, lambda: True, lambda: True)
        process = self.dialog_fixture()
        self.assertTrue(self.gate.confirm_configuration_visual(spawn=lambda *a, **k: process))
        self.assertTrue(process.stdout.closed)
        self.assertEqual(self.gate.configuration_visual_at, self.time)
        with self.assertRaisesRegex(RuntimeError, 'visual-confirmation-order'):
            self.gate.confirm_configuration_visual(spawn=lambda *a, **k: self.fail('must not repeat'))

    def test_abnormal_confirmation_stops_before_saving_layout(self):
        for action in ('start', 'restore'):
            self.gate.request(action, lambda: True, lambda: True)
        with self.assertRaisesRegex(RuntimeError, 'configuration-not-visually-confirmed'):
            self.gate.confirm_configuration_visual(spawn=lambda *a, **k: self.dialog_fixture(b'abnormal'))
        self.assertIsNone(self.gate.configuration_visual_at)
        with self.assertRaisesRegex(RuntimeError, 'batch-stopped'):
            self.gate.request('confirm-user', lambda: self.fail('must not send'), lambda: True)

    def test_dialog_timeout_reaps_only_dialog_and_never_grants_confirmation(self):
        for action in ('start', 'restore'):
            self.gate.request(action, lambda: True, lambda: True)
        process = self.dialog_fixture(wait=True)
        def wait():
            self.time = self.gate.deadline
        with self.assertRaisesRegex(RuntimeError, 'batch-deadline'):
            self.gate.confirm_configuration_visual(spawn=lambda *a, **k: process, wait=wait)
        self.assertEqual(process.poll(), 0)
        self.assertTrue(process.stdout.closed)
        self.assertIsNone(self.gate.configuration_visual_at)

    def test_quit_reply_allows_app_exit_before_independent_verifier(self):
        for action in G.ACTIONS[:-1]:
            self.gate.request(action, lambda: True, lambda: True)
        def send():
            def run(*args, **kwargs):
                del self.processes[10]
                return SimpleNamespace(returncode=0, stdout=b'{"result":"accepted"}')
            return self.gate.control_application('stop', run)['result'] == 'accepted'
        verified = []
        self.gate.request('stop', send, lambda: verified.append(True) or True)
        self.assertEqual(verified, [True])

    def test_bound_launch_control_confirmation_and_exit_share_one_pipe_and_budget(self):
        process = self.launch_fixture()
        self.register_fixture('app', 10)
        phase = 'standby'
        def emit(stages):
            events = []
            for stage in stages:
                self.time += 1
                event = dict(type='internal-lifecycle', role='controller', clock='mach_continuous_time/ns',
                             continuousNs=self.time, stage=stage, succeeded=True)
                if stage.startswith('disable'):
                    event['operation'] = 'disable'
                events.append(event)
            os.write(process.fixture_writer, b''.join((json.dumps(event)+'\n').encode() for event in events))
            deadline = time.monotonic()+1
            while time.monotonic() < deadline:
                with self.gate.stream.lock:
                    if len(self.gate.stream.pending) >= len(events):
                        return
                time.sleep(.001)
            self.fail('fixture pipe did not drain')
        def run(args, **kwargs):
            if args[2] == 'status':
                if phase == 'standby':
                    reply = dict(result='status', sessionState={'waiting': {}}, selectedMode='externalOnly',
                                 stateMode='externalOnly', requiresExplicitActivation=True)
                else:
                    reply, _ = application_evidence(phase)
                return SimpleNamespace(returncode=0, stdout=json.dumps(reply).encode())
            if phase == 'start':
                for role, pid in (('owner', 11), ('helper', 12)):
                    self.register_fixture(role, pid)
                    self.gate.bind_registered_process(role)
                emit(('disableStarted', 'disableFinished'))
            elif phase == 'restore':
                emit(('restorationStarted', 'restorationVerified', 'pauseVerificationStarted', 'pauseVerificationFinished'))
            elif phase == 'confirm-user':
                emit(('configurationConfirmationStarted', 'configurationConfirmationFinished'))
            elif phase == 'stop':
                self.processes.clear()
                os.close(process.fixture_writer)
                process.fixture_writer = None
                self.gate.stream.thread.join(timeout=1)
            return SimpleNamespace(returncode=0, stdout=b'{"result":"accepted"}')
        self.gate.wait_for_standby(run=run)
        for phase in G.ACTIONS:
            if phase == 'confirm-user':
                self.gate.confirm_configuration_visual(spawn=lambda *a, **k: self.dialog_fixture())
            def send():
                if phase == 'sleep':
                    emit(('sleepRequested', 'systemHasPoweredOn', 'disableStarted', 'disableFinished'))
                    return True
                return self.gate.control_application(phase, run)['result'] == 'accepted'
            def verify():
                if phase == 'stop':
                    return not self.processes and self.gate.stream.eof
                if phase == 'sleep':
                    return self.gate.wake is not None and self.gate.native_disable_count == 2
                return self.gate.verify_application(phase, self.gate.control_application('status', run))
            self.gate.request(phase, send, verify)
        self.assertEqual(self.gate.confirmed_requests, 5)
        self.assertEqual(self.gate.native_disable_count, 2)
        self.assertFalse(self.gate.native_disable_pending)
        self.gate.close()
        self.assertIsNone(self.gate.stream.fd)

    def test_native_budget_is_bound_to_original_window_and_stop_is_durable(self):
        self.gate.roles.clear()
        boot = str(uuid.uuid4())
        environment = self.gate.prepare_native_budget(boot)
        directory = Path(environment['EXTILUME_RECOVERY_BATCH_DIRECTORY'])
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        policy = directory / 'policy.json'
        self.assertEqual(policy.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(policy.read_text()), dict(bootSession=boot, started=0, deadline=180*G.D.NS))
        self.time = 180*G.D.NS
        with self.assertRaisesRegex(RuntimeError, 'batch-deadline'):
            self.gate.tick()
        self.assertTrue((directory/'stopped').exists())

    def test_native_permits_follow_durable_requests(self):
        roles = dict(self.gate.roles)
        self.gate.roles.clear()
        self.gate.prepare_native_budget(str(uuid.uuid4()))
        self.gate.roles = roles
        directory = self.gate.native_budget_directory
        self.assertFalse((directory/'initial-authorized.json').exists())
        self.assertFalse((directory/'wake-authorized.json').exists())
        for action in G.ACTIONS:
            def send():
                if action in ('start', 'sleep'):
                    name = 'initial-authorized.json' if action == 'start' else 'wake-authorized.json'
                    self.assertEqual(json.loads((directory/name).read_text()), self.gate.requested_at)
                    self.assertEqual(self.events()[-1], dict(event='consume-before-request', action=action))
                return True
            self.gate.request(action, send, lambda: True)

    def test_native_budget_cannot_be_reprepared_or_added_to_running_app(self):
        with self.assertRaisesRegex(RuntimeError, 'native-budget-order'):
            self.gate.prepare_native_budget(str(uuid.uuid4()))
        self.assertIsNone(self.gate.native_budget_directory)

    def test_native_budget_preparation_is_single_use_and_close_stops_native_attempts(self):
        self.gate.roles.clear()
        self.gate.prepare_native_budget(str(uuid.uuid4()))
        directory = self.gate.native_budget_directory
        original = (directory/'policy.json').read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'native-budget-order'):
            self.gate.prepare_native_budget(str(uuid.uuid4()))
        self.gate.close()
        self.assertEqual((directory/'policy.json').read_bytes(), original)
        self.assertTrue((directory/'stopped').exists())

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

    def test_bound_control_adapter_dispatches_once_then_reads_status(self):
        calls = []
        reply, events = application_evidence('start')
        self.time = 100
        def run(args, **kwargs):
            calls.append(args)
            self.assertEqual(args[0], str(self.exe))
            self.assertEqual(args[-2:], ['--target-process', '10:10:1'])
            self.assertLessEqual(kwargs['timeout'], 10)
            self.assertTrue(kwargs['capture_output'])
            if args[2] == 'status':
                self.assertNotIn('--allow-display-write', args)
                return subprocess.CompletedProcess(args, 0, json.dumps(reply).encode())
            self.assertEqual(args[2:4], ['apply-externalOnly', '--allow-display-write'])
            return subprocess.CompletedProcess(args, 0, b'{"result":"accepted"}')
        def verify():
            self.time = 200
            return self.gate.verify_application('start', self.gate.control_application('status', run), events)
        self.gate.request('start', lambda: self.gate.control_application('start', run)['result'] == 'accepted', verify)
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.gate.confirmed_requests, 1)

    def test_bound_control_cannot_run_outside_consumed_request(self):
        with self.assertRaisesRegex(RuntimeError, 'control-outside-request'):
            self.gate.control_application('start', lambda *a, **k: self.fail('must not dispatch'))

    def test_control_timeout_is_unconfirmed_and_never_retried(self):
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            raise subprocess.TimeoutExpired(args, 1, output=b'PRIVATE_OUTPUT', stderr=b'PRIVATE_ERROR')
        with self.assertRaisesRegex(RuntimeError, '^application-control-unconfirmed$'):
            self.gate.request('start', lambda: self.gate.control_application('start', run), lambda: True)
        self.assertEqual(len(calls), 1)
        self.assertEqual(self.gate.next_action, 1)
        self.assertEqual(self.gate.confirmed_requests, 0)
        self.assertTrue(self.gate.stopped)

    def test_wrong_target_reply_is_not_accepted(self):
        def run(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, b'{"result":"target-mismatch"}')
        with self.assertRaisesRegex(RuntimeError, 'application-control-unconfirmed'):
            self.gate.request('start', lambda: self.gate.control_application('start', run), lambda: True)
        self.assertEqual(self.gate.confirmed_requests, 0)

    def test_two_control_calls_cannot_reuse_one_request_budget(self):
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            self.assertEqual(self.events()[-1], dict(event='control-dispatch', action='start'))
            return subprocess.CompletedProcess(args, 0, b'{"result":"accepted"}')
        def send():
            self.gate.control_application('start', run)
            self.gate.control_application('start', run)
            return True
        with self.assertRaisesRegex(RuntimeError, 'control-already-dispatched'):
            self.gate.request('start', send, lambda: True)
        self.assertEqual(len(calls), 1)

    def test_verification_cannot_issue_another_write(self):
        with self.assertRaisesRegex(RuntimeError, 'control-outside-request'):
            self.gate.request('start', lambda: True,
                lambda: self.gate.control_application('start', lambda *a, **k: self.fail('must not dispatch')))

    def install_event_queue(self):
        queue = []
        def take():
            events = queue[:]
            queue.clear()
            return events, False, None
        self.gate.stream = SimpleNamespace(take=take, close=lambda: None)
        return queue

    def test_collected_events_supply_completion_without_caller_override(self):
        queue = self.install_event_queue()
        reply, events = application_evidence('start')
        self.time = 100
        def send():
            self.time = 200
            queue.extend(events)
            return True
        self.gate.request('start', send, lambda: self.gate.verify_application('start', reply))
        self.assertEqual(self.gate.native_disable_count, 1)
        self.assertFalse(self.gate.native_disable_pending)

    def test_unfinished_native_disable_cannot_complete_even_if_verifier_returns_true(self):
        queue = self.install_event_queue()
        self.time = 100
        def send():
            self.time = 200
            queue.append(application_evidence('start')[1][0])
            return True
        with self.assertRaisesRegex(RuntimeError, 'native-disable-incomplete'):
            self.gate.request('start', send, lambda: True)
        self.assertTrue(self.gate.native_disable_pending)
        self.assertEqual(self.gate.confirmed_requests, 0)

    def test_third_disable_is_recorded_then_stops_batch(self):
        queue = self.install_event_queue()
        self.time = 100
        def initial_send():
            self.time = 200
            queue.extend(application_evidence('start')[1])
            return True
        self.gate.request('start', initial_send, lambda: True)
        for action in ('restore', 'confirm-user'):
            self.gate.request(action, lambda: True, lambda: True)
        def verify_sleep():
            self.time = 300
            self.gate.observe_wake(300)
            self.time = 400
            queue.extend(dict(event, continuousNs=310+i) for i,event in enumerate(application_evidence('start')[1]))
            return True
        self.gate.request('sleep', lambda: True, verify_sleep)
        self.assertEqual(self.gate.native_disable_count, 2)
        queue.append(dict(application_evidence('start')[1][0], continuousNs=350))
        with self.assertRaisesRegex(RuntimeError, 'native-disable-outside-budget'): self.gate.tick()
        self.assertTrue(self.gate.stopped)
        self.assertEqual(self.gate.native_disable_count, 3)
        self.assertTrue(self.gate.native_disable_pending)
        self.assertEqual(self.events()[-1], dict(event='native-disable-observed', count=3))

    def test_unexpected_eof_stops_before_any_dispatch(self):
        self.gate.stream = SimpleNamespace(take=lambda: ([], True, None), close=lambda: None)
        with self.assertRaisesRegex(RuntimeError, 'lifecycle-unexpected-eof'):
            self.gate.request('start', lambda: self.fail('must not dispatch'), lambda: True)

    def test_native_wake_precedes_automatic_reapplication_in_same_drain(self):
        queue = self.install_event_queue()
        self.time = 100
        def initial_send():
            self.time = 200
            queue.extend(application_evidence('start')[1])
            return True
        self.gate.request('start', initial_send, lambda: True)
        for action in ('restore', 'confirm-user'):
            self.gate.request(action, lambda: True, lambda: True)
        def send_sleep():
            self.time = 400
            queue.append(dict(application_evidence('start')[1][0], stage='systemHasPoweredOn', continuousNs=300))
            queue.extend(dict(event, continuousNs=310+i) for i,event in enumerate(application_evidence('start')[1]))
            return True
        self.gate.request('sleep', send_sleep, lambda: True)
        self.assertEqual(self.gate.wake, 300)
        self.assertEqual(self.gate.deadline, 300 + 10 * G.D.NS)
        self.assertEqual(self.gate.native_disable_count, 2)

    def test_live_completion_rejects_caller_supplied_event_list(self):
        queue = self.install_event_queue()
        reply, events = application_evidence('start')
        self.time = 100
        def send():
            self.time = 200
            queue.extend(events)
            return True
        with self.assertRaisesRegex(RuntimeError, 'lifecycle-input-override'):
            self.gate.request('start', send, lambda: self.gate.verify_application('start', reply, events))

    def test_unknown_stage_is_not_persisted(self):
        queue = self.install_event_queue()
        self.time = 200
        queue.append(dict(application_evidence('start')[1][0], stage='PRIVATE_CANARY'))
        with self.assertRaisesRegex(RuntimeError, 'invalid-lifecycle-event'): self.gate.tick()
        self.assertNotIn('PRIVATE_CANARY', json.dumps(self.events()))

    def test_standalone_tick_timeout_latches_stop(self):
        self.time = 180 * G.D.NS
        with self.assertRaisesRegex(RuntimeError, 'batch-deadline'): self.gate.tick()
        self.assertTrue(self.gate.stopped)

    def test_gate_close_keeps_active_pipe_draining_until_eof(self):
        read, write = os.pipe()
        reader, writer = os.fdopen(read, 'rb', buffering=0), os.fdopen(write, 'wb', buffering=0)
        self.addCleanup(reader.close)
        self.addCleanup(writer.close)
        self.gate.attach_stream(reader.fileno())
        collector = self.gate.stream
        self.addCleanup(collector.close)
        self.gate.close()
        self.assertEqual(self.events()[-1]['readerCleanup'], 'retained-until-eof')
        self.assertTrue(collector.thread.is_alive())
        writer.write(b'recovery output still drains\n')
        writer.close()
        collector.thread.join(timeout=2)
        self.assertFalse(collector.thread.is_alive())
        self.gate.close()
        self.assertIsNone(collector.fd)

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

    def test_disable_transaction_begin_is_not_a_restoration(self):
        reply, events = application_evidence('start')
        begin = dict(events[0], stage='enableBeginStarted', operation='disable')
        events.insert(1, begin)
        self.assertTrue(self.assess('start', reply, events))
        for operation in ('enable', None):
            begin['operation'] = operation
            with self.assertRaisesRegex(RuntimeError, 'unexpected-restoration'):
                self.assess('start', reply, events)

    def test_restore_rejects_any_new_disable(self):
        reply, events = application_evidence('restore')
        events.append(dict(events[-1], stage='disableStarted', continuousNs=150))
        with self.assertRaisesRegex(RuntimeError, 'unexpected-disable'):
            self.assess('restore', reply, events)

    def test_human_confirmation_sleep_and_exit_need_separate_proof(self):
        for action in ('sleep', 'stop'):
            with self.assertRaisesRegex(RuntimeError, 'unsupported-application-checkpoint'):
                self.assess(action, *application_evidence('start'))

    def test_configuration_needs_new_successful_markers_not_prior_manual_state(self):
        reply, _ = application_evidence('restore')
        events = [dict(type='internal-lifecycle', role='controller', clock='mach_continuous_time/ns',
                       continuousNs=110+i, stage=stage, succeeded=True)
                  for i, stage in enumerate(('configurationConfirmationStarted', 'configurationConfirmationFinished'))]
        self.assertTrue(G.application_checkpoint('confirm-user', reply, events, 100, 200, 300))
        for incomplete in ([], events[:1], [dict(events[0], continuousNs=90), events[1]],
                           [events[0], dict(events[1], succeeded=False)]):
            with self.assertRaises(RuntimeError):
                G.application_checkpoint('confirm-user', reply, incomplete, 100, 200, 300)

    def test_deadline_cannot_be_used_as_a_success_endpoint(self):
        with self.assertRaisesRegex(RuntimeError, 'invalid-completion-window'):
            G.application_checkpoint('start', *application_evidence('start'), 100, 300, 300)


class LifecyclePipeTests(unittest.TestCase):
    def pipe(self):
        read, write = os.pipe()
        reader, writer = os.fdopen(read, 'rb', buffering=0), os.fdopen(write, 'wb', buffering=0)
        self.addCleanup(reader.close)
        self.addCleanup(writer.close)
        collector = G.LifecyclePipe(reader.fileno())
        self.addCleanup(collector.close)
        return reader, writer, collector

    def collect(self, collector, count=0, eof=False):
        events = []
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            batch, ended, error = collector.take()
            events.extend(batch)
            if error or (ended if eof else len(events) >= count):
                return events, ended, error
            time.sleep(0.005)
        self.fail('collector did not deliver bounded input')

    def test_fragmented_json_and_non_json_output(self):
        _, writer, collector = self.pipe()
        event = application_evidence('start')[1][0]
        payload = json.dumps(event).encode() + b'\n'
        writer.write(b'ordinary diagnostic\n' + payload[:20])
        writer.write(payload[20:])
        events, _, error = self.collect(collector, count=1)
        self.assertEqual(events, [event])
        self.assertIsNone(error)

    def test_truncated_eof_is_not_complete(self):
        _, writer, collector = self.pipe()
        writer.write(b'{"type":"internal-lifecycle"')
        writer.close()
        _, ended, error = self.collect(collector, eof=True)
        self.assertTrue(ended)
        self.assertEqual(error, 'lifecycle-truncated')

    def test_malformed_line_fails_without_exporting_content(self):
        _, writer, collector = self.pipe()
        writer.write(b'{PRIVATE_CANARY}\n')
        _, _, error = self.collect(collector, eof=True)
        self.assertEqual(error, 'lifecycle-reader-failed')

    def test_oversized_line_is_bounded(self):
        _, writer, collector = self.pipe()
        writer.write(b'x' * 8193 + b'\n')
        _, _, error = self.collect(collector, eof=True)
        self.assertEqual(error, 'lifecycle-reader-failed')

    def test_complete_eof_retains_last_event(self):
        _, writer, collector = self.pipe()
        event = application_evidence('start')[1][0]
        writer.write(json.dumps(event).encode() + b'\n')
        writer.close()
        events, ended, error = self.collect(collector, eof=True)
        self.assertEqual(events, [event])
        self.assertTrue(ended)
        self.assertIsNone(error)

    def test_close_releases_only_owned_descriptor(self):
        reader, writer, collector = self.pipe()
        collector.close()
        collector.close()
        self.assertFalse(collector.thread.is_alive())
        writer.write(b'x')
        self.assertEqual(os.read(reader.fileno(), 1), b'x')

    def test_pending_event_queue_is_bounded_and_keeps_existing_evidence(self):
        _, writer, collector = self.pipe()
        line = json.dumps(application_evidence('start')[1][0]).encode() + b'\n'
        writer.write(line * 4097)
        # Reading the queue early frees capacity and defeats the overflow this test intends to create.
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            with collector.lock:
                if collector.error is not None:
                    break
            time.sleep(.001)
        events, _, error = self.collect(collector, eof=True)
        self.assertEqual(len(events), 4096)
        self.assertEqual(error, 'lifecycle-reader-failed')

    def test_write_end_is_rejected_before_starting_reader(self):
        _, writer, _ = self.pipe()
        with self.assertRaisesRegex(RuntimeError, 'lifecycle-not-readable'):
            G.LifecyclePipe(writer.fileno())

    def test_regular_file_is_not_accepted_as_live_pipe(self):
        with tempfile.TemporaryFile() as file:
            with self.assertRaisesRegex(RuntimeError, 'lifecycle-not-pipe'):
                G.LifecyclePipe(file.fileno())


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
            self.assertFalse(G.process_has_exited(first))
            child.stdin.close()
            child.wait(timeout=5)
            self.assertTrue(G.process_has_exited(first))
            with self.assertRaisesRegex(RuntimeError, 'process-info-unavailable|process-exited-or-changed'):
                G.read_process_identity(child.pid)


if __name__ == '__main__': unittest.main()
