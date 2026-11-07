import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('run-recovery-batch.py'))
R = importlib.util.module_from_spec(spec)
spec.loader.exec_module(R)
G = R.G
FIX = G.D.load_tool('test_calibrate_recovery_clock')
SNAP = G.D.load_tool('test_diagnose_recovery_baseline')


class BatchEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.exe = self.root / 'fixture'
        self.exe.write_bytes(b'fixture')
        self.time = 0
        self.processes = {pid: dict(pid=pid, uid=os.getuid(), parentPID=pid-1, startSeconds=10,
                                   startMicroseconds=1, executable=str(self.exe)) for pid in (10, 11, 12)}
        binaries = {role: dict(executable=str(self.exe), sha256=G.D.digest(self.exe)) for role in G.ROLES}
        self.gate = G.RecoveryBatchGate(self.root, str(uuid.uuid4()), 'a'*64, binaries,
                                       lambda: self.time, lambda pid: self.processes[pid])
        for role, pid in zip(G.ROLES, self.processes):
            self.gate.bind(role, self.processes[pid])
        reader, self.writer = os.pipe()
        self.pipe = G.LifecyclePipe(reader)
        os.close(reader)
        self.addCleanup(self.cleanup)

    def cleanup(self):
        if self.writer is not None:
            os.close(self.writer)
        self.pipe.thread.join(timeout=1)
        self.pipe.close()
        self.gate.close()

    def emit(self, stages):
        events = []
        for at, stage in stages:
            event = dict(type='internal-lifecycle', role='controller', clock='mach_continuous_time/ns',
                         continuousNs=at, stage=stage, succeeded=True)
            if stage.startswith('disable'):
                event['operation'] = 'disable'
            events.append(event)
        os.write(self.writer, b''.join((json.dumps(event)+'\n').encode() for event in events))
        deadline = time.monotonic()+1
        while time.monotonic() < deadline:
            with self.pipe.lock:
                if len(self.pipe.pending) >= len(events):
                    return
            time.sleep(.001)
        self.fail('fixture pipe not drained')

    def sleep_round(self, mutate=lambda before, after, evidence, stages: None):
        for action in G.ACTIONS[:3]:
            self.gate.request(action, lambda: True, lambda: True)
        self.gate.stream = self.pipe
        self.gate.native_disable_count = 1
        self.time = 175
        before, after, evidence = FIX.capture(100, 100), FIX.capture(1000, 200), FIX.evidence()
        stages = [(190, 'sleepRequested'), (1415, 'systemHasPoweredOn'), (1420, 'restorationStarted'),
                  (1421, 'restorationVerified'), (1430, 'disableStarted'), (1440, 'disableFinished')]
        mutate(before, after, evidence, stages)
        def send():
            self.time = 1600
            self.emit(stages)
            self.gate.observe_power(evidence['intervals'][0]['powerEvent'], FIX.SESSION)
            return True
        reply = dict(result='status', sessionState={'applied': {}}, selectedMode='externalOnly',
                     stateMode='externalOnly', requiresExplicitActivation=False)
        self.gate.request('sleep', send, lambda: self.gate.verify_sleep(before, after, evidence, reply, 'a'*64))

    def test_sleep_requires_real_pause_and_native_reapplication_in_one_request(self):
        self.sleep_round()
        self.assertEqual(self.gate.confirmed_requests, 4)
        self.assertEqual(self.gate.native_disable_count, 2)
        self.assertEqual(self.gate.deadline, 1410 + 10*G.D.NS)

    def test_power_notification_without_positive_sleep_cannot_confirm(self):
        def mutate(before, after, evidence, stages):
            after.update(FIX.capture(1000, 1000))
            evidence.update(FIX.evidence(1420))
        with self.assertRaisesRegex(RuntimeError, 'real-sleep-unproved'):
            self.sleep_round(mutate)
        self.assertTrue(self.gate.stopped)
        self.assertEqual(self.gate.confirmed_requests, 3)

    def test_native_wake_without_recovery_endpoint_cannot_confirm(self):
        with self.assertRaisesRegex(RuntimeError, 'wake-reapplication-endpoint-missing'):
            self.sleep_round(lambda before, after, evidence, stages: stages.pop(3))

    def test_stale_or_other_probe_clock_capture_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'sleep-capture-outside-batch'):
            self.sleep_round(lambda before, after, evidence, stages:
                             (before.update(probeSHA256='b'*64), after.update(probeSHA256='b'*64)))

    def test_duplicate_power_pair_stops_without_renewing_deadline(self):
        self.sleep_round()
        original = self.gate.deadline
        with self.assertRaisesRegex(RuntimeError, 'unexpected-power-event'):
            self.gate.observe_power(FIX.evidence()['intervals'][0]['powerEvent'], FIX.SESSION)
        self.assertEqual(self.gate.deadline, original)

    def exit_round(self, mutate=lambda receipt, snapshots, internal: None, exited=lambda binding: True, returncode=0):
        for action in G.ACTIONS[:4]:
            self.gate.request(action, lambda: True, lambda: True)
        self.gate.stream = self.pipe
        native = self.root / 'native'
        native.mkdir(mode=0o700)
        self.gate.native_budget_directory = native
        self.gate.application_process = SimpleNamespace(poll=lambda: returncode, stdout=io.BytesIO())
        snapshot = SNAP.snapshot()
        inner, external = snapshot['displays']
        hardware = dict(bootSession=FIX.SESSION, registryEntryID=1)
        layout = dict(main=inner['identityUUID'], origins=[inner['identityUUID'], dict(x=0, y=0),
                      external['identityUUID'], dict(x=1728, y=0)])
        expectation = dict(session=str(uuid.uuid4()), generation=3, baseline=layout,
                           internalIdentity=inner['identityUUID'], numericIDHint=inner['id'], hardware=hardware)
        record = dict(session=expectation['session'], generation=3, baseline=layout, phase='restored',
                      layoutPending=False, sourceUnresolved=False, independentGuardVerified=True,
                      internalDisplay=dict(identity=inner['identityUUID'], baseline=True, applied=False,
                                           pending=False, hardwareIdentity=hardware))
        receipt = dict(version=1, app={key: self.processes[10][key] for key in
                       ('pid', 'startSeconds', 'startMicroseconds')}, verifiedAtNanoseconds=100,
                       expectation=expectation, record=record)
        state = dict(id=inner['id'], identityUUID=inner['identityUUID'], reportedIdentityUUID=inner['identityUUID'],
                     isBuiltIn=True, isActive=True, isOnline=True, hardwareIdentity=hardware)
        snapshots, internal = [copy.deepcopy(snapshot), copy.deepcopy(snapshot)], dict(state={'_0': state})
        mutate(receipt, snapshots, internal)
        G.D.save_new(native / 'restoration.json', receipt)
        self.time = 100
        def send():
            os.close(self.writer)
            self.writer = None
            self.pipe.thread.join(timeout=1)
            self.time = 101
            return True
        self.gate.request('stop', send, lambda: self.gate.verify_exit(snapshot, hardware, snapshots, internal, exited))

    def test_exit_uses_bound_receipt_two_full_C_snapshots_hardware_and_all_roles(self):
        self.exit_round()
        self.assertEqual(self.gate.confirmed_requests, 5)
        self.gate.close()
        self.assertIsNone(self.pipe.fd)

    def test_exit_rejects_live_role_even_with_valid_restoration_receipt(self):
        with self.assertRaisesRegex(RuntimeError, 'controller-still-running'):
            self.exit_round(exited=lambda binding: binding['pid'] != 12)

    def test_exit_rejects_stale_process_receipt(self):
        with self.assertRaisesRegex(RuntimeError, 'unbound-restoration-receipt'):
            self.exit_round(lambda r, s, i: r['app'].update(startMicroseconds=2))

    def test_exit_rejects_old_receipt_timestamp(self):
        with self.assertRaisesRegex(RuntimeError, 'unbound-restoration-receipt'):
            self.exit_round(lambda r, s, i: r.update(verifiedAtNanoseconds=99))

    def test_exit_rejects_pending_record(self):
        with self.assertRaisesRegex(RuntimeError, 'unresolved-responsibility'):
            self.exit_round(lambda r, s, i: r['record'].update(layoutPending=True))

    def test_exit_requires_independent_guard_proof(self):
        with self.assertRaisesRegex(RuntimeError, 'unverified-restoration-receipt'):
            self.exit_round(lambda r, s, i: r['record'].update(independentGuardVerified=False))

    def test_exit_rejects_changed_mode(self):
        with self.assertRaisesRegex(RuntimeError, 'C-or-mode-mismatch'):
            self.exit_round(lambda r, s, i: s[1]['displays'][1]['mode'].update(refreshRate=60))

    def test_exit_requires_enabled_internal_display(self):
        with self.assertRaisesRegex(RuntimeError, 'internal-identity-unverified'):
            self.exit_round(lambda r, s, i: i['state']['_0'].update(isActive=False))

    def test_exit_rejects_nonzero_exit(self):
        with self.assertRaisesRegex(RuntimeError, 'application-exit-not-normal'):
            self.exit_round(returncode=1)

    def test_exit_rejects_signal_exit(self):
        with self.assertRaisesRegex(RuntimeError, 'application-exit-not-normal'):
            self.exit_round(returncode=-9)

    def topology_event(self):
        return dict(type='internal-lifecycle', role='controller', clock='mach_continuous_time/ns',
            continuousNs=0, stage='wakeTopologyWaiting', recoveryTopology=dict(onlineDisplayCount=1,
                activeDisplayCount=1, activeBuiltInCount=1, activePhysicalCount=0, activeOtherCount=0))

    def test_native_topology_counts_are_saved_without_other_payload_fields(self):
        event = dict(self.topology_event(), ignoredPrivateField='PRIVATE-CANARY')
        self.gate.stream = self.pipe
        with patch.object(self.pipe, 'take', return_value=([event], False, None)):
            self.gate.tick()
        saved = [json.loads(line) for line in self.gate.journal.path.read_text().splitlines()][-1]
        self.assertEqual(saved['recoveryTopology'], event['recoveryTopology'])
        self.assertNotIn('PRIVATE-CANARY', self.gate.journal.path.read_text())

    def test_extra_topology_fields_stop_before_persistence(self):
        event = self.topology_event()
        event['recoveryTopology']['serial'] = 'PRIVATE-CANARY'
        self.gate.stream = self.pipe
        with patch.object(self.pipe, 'take', return_value=([event], False, None)):
            with self.assertRaisesRegex(RuntimeError, 'invalid-topology-counts'):
                self.gate.tick()
        self.assertTrue(self.gate.stopped)
        self.assertNotIn('PRIVATE-CANARY', self.gate.journal.path.read_text())

    def test_boolean_topology_count_is_rejected(self):
        event = self.topology_event()
        event['recoveryTopology']['onlineDisplayCount'] = True
        self.gate.stream = self.pipe
        with patch.object(self.pipe, 'take', return_value=([event], False, None)):
            with self.assertRaisesRegex(RuntimeError, 'invalid-topology-counts'):
                self.gate.tick()

    def test_fixed_entry_runs_real_gate_pipe_sleep_and_exit_validators_without_hardware(self):
        self.pipe.close()
        self.gate.roles.clear()
        os.close(self.writer)
        self.writer = None
        snapshot = SNAP.snapshot()
        hardware = dict(bootSession=FIX.SESSION, registryEntryID=1)
        state = self.root / 'state'
        state.mkdir(mode=0o700)
        reader, self.writer = os.pipe()
        child = SimpleNamespace(pid=10, stdout=os.fdopen(reader, 'rb'), poll=lambda: None)
        backend = SimpleNamespace(bundle=self.root, field=dict(bootSession=FIX.SESSION), close=lambda: True)
        calls = []
        def tick(force=False):
            self.gate.tick()
        backend.tick = tick
        backend.wait = lambda: (tick(), time.sleep(.001))
        backend.visual = lambda message: calls.append('visual')
        backend.preflight = lambda: calls.append('sleep-preflight')
        backend.read_C = lambda phase: calls.append(phase)
        backend.start_recorder = lambda: calls.append('recorder-ready')
        backend.capture = lambda name: FIX.capture(100, 100)
        backend.safety_handoff = lambda: self.fail('successful fixture must not need safety handoff')
        def launch(directory, boot):
            process = G.RecoveryBatchGate.launch_application(self.gate, directory, boot, lambda *a, **k: child)
            self.pipe = self.gate.stream
            G.D.save_new(self.gate.native_budget_directory / 'app-process.json',
                         {key: self.processes[10][key] for key in ('pid', 'startSeconds', 'startMicroseconds')})
            return process
        phase = ['standby']
        def run(args, **kwargs):
            command = args[2]
            if command == 'status':
                status = 'waiting' if phase[0] == 'standby' else 'applied' if phase[0] == 'start' else 'manualConfiguration'
                return SimpleNamespace(returncode=0, stdout=json.dumps(dict(result='status', sessionState={status: {}},
                    selectedMode='externalOnly', stateMode='externalOnly', requiresExplicitActivation=phase[0]=='standby')).encode())
            if command == 'apply-externalOnly':
                phase[0] = 'start'
                for role, pid in (('owner', 11), ('helper', 12)):
                    G.D.save_new(self.gate.native_budget_directory / (role+'-process.json'),
                                 {key: self.processes[pid][key] for key in ('pid', 'startSeconds', 'startMicroseconds')})
                    self.gate.bind_registered_process(role)
                self.time = 21
                self.emit([(20, 'disableStarted'), (21, 'disableFinished')])
            elif command == 'restore-for-configuration':
                phase[0] = 'restore'
                self.time = 33
                self.emit(list(zip(range(30, 34), ('restorationStarted', 'restorationVerified',
                                                 'pauseVerificationStarted', 'pauseVerificationFinished'))))
            elif command == 'confirm-configuration':
                phase[0] = 'confirm-user'
                self.time = 41
                self.emit([(40, 'configurationConfirmationStarted'), (41, 'configurationConfirmationFinished')])
            elif command == 'quit':
                self.time = 1601
                inner, external = snapshot['displays']
                layout = dict(main=inner['identityUUID'], origins=[inner['identityUUID'], dict(x=0, y=0),
                              external['identityUUID'], dict(x=1728, y=0)])
                expectation = dict(session=str(uuid.uuid4()), generation=3, baseline=layout,
                    internalIdentity=inner['identityUUID'], numericIDHint=inner['id'], hardware=hardware)
                record = dict(session=expectation['session'], generation=3, baseline=layout, phase='restored',
                    layoutPending=False, sourceUnresolved=False, independentGuardVerified=True,
                    internalDisplay=dict(identity=inner['identityUUID'], baseline=True, pending=False, hardwareIdentity=hardware))
                G.D.save_new(self.gate.native_budget_directory / 'restoration.json', dict(version=1,
                    app={key: self.processes[10][key] for key in ('pid', 'startSeconds', 'startMicroseconds')},
                    verifiedAtNanoseconds=self.time, expectation=expectation, record=record))
                self.processes.clear()
                child.poll = lambda: 0
                os.close(self.writer)
                self.writer = None
                self.pipe.thread.join(timeout=1)
            return SimpleNamespace(returncode=0, stdout=b'{"result":"accepted"}')
        backend.wait_application = lambda action: self.gate.control_application('status', run)
        def capture(name):
            self.time = 170
            return FIX.capture(100, 100)
        backend.capture = capture
        def sleep_once():
            self.time = 1600
            self.emit([(190, 'sleepRequested'), (1415, 'systemHasPoweredOn'), (1420, 'restorationStarted'),
                       (1421, 'restorationVerified'), (1430, 'disableStarted'), (1440, 'disableFinished')])
            self.gate.observe_power(FIX.evidence()['intervals'][0]['powerEvent'], FIX.SESSION)
        backend.sleep_once = sleep_once
        backend.sleep_and_verify = lambda before: self.gate.verify_sleep(before, FIX.capture(1000, 200), FIX.evidence(),
            dict(result='status', sessionState={'applied': {}}, selectedMode='externalOnly', stateMode='externalOnly',
                 requiresExplicitActivation=False), 'a'*64)
        inner = snapshot['displays'][0]
        internal = dict(state={'_0': dict(id=inner['id'], identityUUID=inner['identityUUID'], reportedIdentityUUID=inner['identityUUID'],
                         isBuiltIn=True, isActive=True, isOnline=True, hardwareIdentity=hardware)})
        backend.exit_and_verify = lambda: self.gate.verify_exit(snapshot, hardware, [snapshot, snapshot], internal,
                                                               lambda binding: binding['pid'] not in self.processes)
        control = self.gate.control_application
        def confirm(**kwargs):
            self.gate.configuration_visual_at = self.time
            return True
        with patch.object(self.gate, 'launch_application', launch), \
             patch.object(self.gate, 'control_application', lambda action, *a: control(action, run)), \
             patch.object(self.gate, 'confirm_configuration_visual', confirm):
            result = R.execute(backend, self.gate)
        self.assertTrue(result['passed'], result)
        self.assertEqual(result['confirmedRequests'], 5)
        self.assertEqual(result['nativeDisableObserved'], 2)
        self.assertIsNone(self.pipe.fd)
        self.assertTrue(child.stdout.closed)

    def test_prefix_failure_enters_handoff_without_later_actions(self):
        calls = []
        backend = SimpleNamespace(tick=lambda **kwargs: None, close=lambda: True,
            read_C=lambda phase: (_ for _ in ()).throw(RuntimeError('C-or-mode-mismatch')),
            safety_handoff=lambda: calls.append('handoff') or dict(userHandoffRequired=True))
        result = R.execute(backend, self.gate)
        self.assertFalse(result['passed'])
        self.assertEqual(result['stopReason'], 'evidence-or-command-failed')
        self.assertEqual(result['consumedRequests'], 0)
        self.assertEqual(calls, ['handoff'])

    def test_safety_quit_timeout_is_consumed_and_never_retried(self):
        backend = R.BatchMac.__new__(R.BatchMac)
        backend.gate = self.gate
        backend.now = lambda: (100, 100)
        backend.journal = self.gate.journal
        backend.read_C = lambda phase: ([], {})
        with patch.object(G, 'process_has_exited', return_value=False), \
             patch.object(R.subprocess, 'run', side_effect=R.subprocess.TimeoutExpired('fixture', 10)) as run:
            first = backend.safety_handoff()
            second = backend.safety_handoff()
        self.assertTrue(first['normalQuitRequested'])
        self.assertFalse(second['normalQuitRequested'])
        self.assertTrue(first['userHandoffRequired'])
        self.assertEqual(run.call_count, 1)
        self.assertTrue(self.gate.stopped)


class IndependentWakeObservationTests(unittest.TestCase):
    def test_snapshot_is_retained_before_reapplication_wait_can_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            events = []
            backend = R.BatchMac.__new__(R.BatchMac)
            backend.bundle = root
            backend.gate = SimpleNamespace(power_event={}, wake=1)
            backend.journal = SimpleNamespace(append=events.append)
            backend.now = lambda: (100, 100)
            backend.capture = lambda name: FIX.capture(1000, 200)
            backend.stop_recorder = FIX.evidence
            backend.witness = lambda flag: SNAP.snapshot()
            def blocked(action):
                self.assertEqual(action, 'sleep')
                value = G.D.CLOCK.load_private(root / 'wake-independent.private.json')
                self.assertEqual(value['snapshot'], SNAP.snapshot())
                raise RuntimeError('fixture-reapplication-blocked')
            backend.wait_application = blocked
            with self.assertRaisesRegex(RuntimeError, 'fixture-reapplication-blocked'):
                backend.sleep_and_verify(FIX.capture(100, 100))
            self.assertEqual([event['event'] for event in events],
                             ['independent-wake-read-started', 'independent-wake-read-finished'])
            self.assertEqual(events[-1]['builtIn'], 1)
            self.assertEqual(events[-1]['physical'], 1)


class NativeWitnessTests(unittest.TestCase):
    def setUp(self):
        self.binding = dict(pid=20, uid=os.getuid(), parentPID=11, startSeconds=10,
                            startMicroseconds=1, executable='/candidate with spaces/Extilume')
        self.backend = R.BatchMac.__new__(R.BatchMac)
        self.backend.children = {}
        self.roles_checked = []
        self.backend.gate = SimpleNamespace(roles={'owner': dict(pid=11, executable=self.binding['executable'])},
            check_roles=lambda roles: self.roles_checked.append(roles))
        self.backend.journal = SimpleNamespace(append=lambda event: None)

    def scan(self, arguments=None, parent=11, identities=None):
        image = self.binding['executable']
        arguments = arguments or image + ' --display-snapshot 198'
        output = f"20 {parent} {os.getuid()} S {arguments}\n"
        with patch.object(R.subprocess, 'run', return_value=SimpleNamespace(stdout=output)), \
             patch.object(self.backend, 'pid_path', return_value=image), \
             patch.object(G, 'read_process_identity', side_effect=identities or [self.binding, self.binding]):
            self.backend.check_processes(None)

    def test_exact_read_only_witness_requires_bound_parent_and_stable_kernel_identity(self):
        self.scan()
        self.assertEqual(self.roles_checked, [('owner',)])

    def test_same_binary_extra_controller_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'unexpected-controller'):
            self.scan(self.binding['executable'] + ' --internal-app-session /state 198')

    def test_witness_from_unbound_parent_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'unexpected-controller'):
            self.scan(parent=99)

    def test_reused_witness_pid_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'native-witness-unbound'):
            self.scan(identities=[self.binding, dict(self.binding, startMicroseconds=2)])

    def test_close_never_terminates_bound_native_roles(self):
        reader = SimpleNamespace()
        self.backend.children = {10: (None, '/candidate/Extilume'), 21: (reader, '/probe')}
        def close(backend):
            self.assertEqual(backend.children, {21: (reader, '/probe')})
            return True
        with patch.object(G.D.Mac, 'close', close):
            self.assertTrue(self.backend.close())


class ProcessExitTests(unittest.TestCase):
    def test_process_reuse_and_unknown_read_fail_closed(self):
        binding = dict(pid=10, uid=os.getuid(), parentPID=9, startSeconds=10,
                       startMicroseconds=1, executable='/fixture')
        info = SimpleNamespace(**dict(binding, status=5))
        with patch.object(G, '_query_process_info', return_value=info):
            self.assertTrue(G.process_has_exited(binding))
            info.startMicroseconds = 2
            with self.assertRaisesRegex(RuntimeError, 'process-reused-or-changed'):
                G.process_has_exited(binding)
        with patch.object(G, '_query_process_info', side_effect=RuntimeError('process-info-unavailable')):
            with self.assertRaisesRegex(RuntimeError, 'process-info-unavailable'):
                G.process_has_exited(binding)


class FieldBindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name).resolve()
        self.bundle.chmod(0o700)
        names = ['Extilume.app/Contents/MacOS/Extilume', 'bin/extilume-probe', 'source/Package.swift']
        names += ['scripts/' + name for name in R.TOOLS]
        for name in names:
            path = self.bundle / name
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
            path.chmod(0o600)
        digest = G.D.digest(self.bundle / names[0])
        self.manifest = dict(version=1, scope=R.SCOPE, candidate=str(uuid.uuid4()),
            files={name: digest for name in names}, sources={'Package.swift': digest},
            macOS=R.platform.mac_ver()[0], architecture=R.platform.machine())
        G.D.save_new(self.bundle / 'manifest.json', self.manifest)
        self.field = dict(approved=True, scope=R.SCOPE, candidate=self.manifest['candidate'],
            manifestSHA256=G.D.digest(self.bundle / 'manifest.json'), probeSHA256=digest,
            macOS=self.manifest['macOS'], architecture=self.manifest['architecture'],
            bootSession=FIX.SESSION, internalHardwareIdentity=dict(bootSession=FIX.SESSION, registryEntryID=1),
            expectedC=SNAP.snapshot(), daily=None, calibrationApplicable=True, lidOpenAndUnlocked=True,
            rescueOperator='user', rescueActions=['normal-quit-once', 'user-takes-over'],
            actions=list(G.ACTIONS), maximumNativeDisableAttempts=2, maximumSleepRequests=1,
            confirmationMethod='local-dialog', records=[
                dict(role='old-1', path=str(self.bundle / 'old-1.json'), sha256=digest),
                dict(role='old-2', path=str(self.bundle / 'old-2.json'), sha256=digest),
                dict(role='daily', path=str(G.D.DEFAULT_STATE_DIRECTORY / 'recovery-record.json'), absent=True,
                     directoryIdentity=dict(device=1, inode=1))])

    def test_complete_bound_field_passes_without_starting_any_process(self):
        with patch.object(R.subprocess, 'Popen', side_effect=AssertionError('no process')):
            R.validate_field(self.bundle, self.manifest, self.field)

    def test_unapproved_field_stays_unapproved(self):
        self.field['approved'] = False
        with self.assertRaisesRegex(RuntimeError, 'field-authorization-required'):
            R.validate_field(self.bundle, self.manifest, self.field)

    def test_expanded_sleep_quota_is_rejected(self):
        self.field['maximumSleepRequests'] = 2
        with self.assertRaisesRegex(RuntimeError, 'field-handoff-or-limits-missing'):
            R.validate_field(self.bundle, self.manifest, self.field)

    def test_changed_frozen_tool_is_rejected(self):
        (self.bundle / 'scripts/recovery-batch-gate.py').write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'frozen-tool-changed'):
            R.validate_field(self.bundle, self.manifest, self.field)

    def test_symlinked_frozen_tool_is_rejected(self):
        path = self.bundle / 'scripts/recovery-batch-gate.py'
        path.unlink()
        path.symlink_to(self.bundle / 'source/Package.swift')
        with self.assertRaisesRegex(RuntimeError, 'frozen-tool-changed'):
            R.validate_field(self.bundle, self.manifest, self.field)


if __name__ == '__main__':
    unittest.main()
