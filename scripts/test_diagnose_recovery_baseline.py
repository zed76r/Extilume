"""Dg1 离线反例：不运行任何 App、probe、ps、睡眠或原生时钟。"""
import copy
import io
import importlib.util
import json
import os
import stat
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock
from types import SimpleNamespace

SPEC = importlib.util.spec_from_file_location('dg1', Path(__file__).with_name('diagnose-recovery-baseline.py'))
D = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(D)
FIX = D.load_tool('test_calibrate_recovery_clock')
BOOT = FIX.SESSION


def snapshot():
    return dict(displays=[dict(
        id=index + 1, identity={role: {}}, identityUUID=f'00000000-0000-0000-0000-00000000000{index + 2}',
        isOnline=True, isActive=True, isMain=index == 0, isMirrored=False,
        originX=index * 1728, originY=0, rotation=0,
        mode=dict(width=1728, height=1117, pixelWidth=3456, pixelHeight=2234, refreshRate=120,
                  ioDisplayModeID=123)) for index, role in enumerate(('builtIn', 'physical'))])


class Fake:
    def __init__(self, field):
        self.field = field
        self.c = self.a = 0
        self.calls = []
        self.pending = []
        self.data = FIX.evidence()
        self.evidence_event = self.data['intervals'][0]['powerEvent']
        self.failure = None
        self.cleanup = True
        self.after_visual = 'normal'
        self.snapshot_reads = 0
        self.third_snapshot = None

    def now(self):
        return self.c, self.a

    def events(self):
        pending, self.pending = self.pending, []
        return pending

    def check_processes(self, daily):
        if self.failure == 'unexpected-controller':
            raise RuntimeError(self.failure)

    def snapshot(self):
        self.snapshot_reads += 1
        if self.snapshot_reads == 3 and self.third_snapshot:
            self.third_snapshot(self)
        value = copy.deepcopy(self.field['expectedC'])
        if self.failure == 'incomplete-C':
            value['displays'].pop()
        return value

    def internal_state(self, *args):
        if self.failure == 'internal-identity-unverified':
            raise RuntimeError(self.failure)

    def normal_exit(self, daily):
        self.calls.append('daily-normal-exit')
        if self.failure == 'daily-exit-failed':
            raise RuntimeError(self.failure)
        entry = next(e for e in self.field['records'] if e['role'] == 'daily')
        before = D.CLOCK.load_private(entry['path'])
        after = dict(before, phase='restored', layoutPending=False)
        Path(entry['path']).write_text(json.dumps(after))
        return before

    def confirm(self, phase):
        if self.failure == 'observation-gap' and phase == 'before':
            self.c = self.a = 4 * D.NS
        return self.after_visual if phase == 'after' else 'normal'

    def preflight(self):
        self.session.tick()
        if self.failure == 'sleep-preflight-blocked':
            raise RuntimeError(self.failure)

    def capture(self, name):
        return FIX.capture(100, 100) if name == 'before' else FIX.capture(1000, 200)

    def start_recorder(self):
        self.calls.append('start-recorder')

    def sleep_once(self):
        self.session.tick(force=True)
        self.calls.append('sleep')
        if self.failure == 'sleep-request-failed':
            raise RuntimeError(self.failure)
        self.c, self.a = 1600, 300
        self.pending = [copy.deepcopy(self.evidence_event)]
        if self.failure == 'sleep-over-total-deadline':
            self.c = 181 * D.NS

    def wait(self):
        self.session.tick()

    def stop_recorder(self):
        self.calls.append('stop-recorder')
        return self.data

    def close(self):
        self.calls.append('cleanup-own-readers')
        return self.cleanup


class Dg1Tests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.field = dict(bootSession=BOOT, expectedC=snapshot(), internalHardwareIdentity={}, daily=None, records=[])
        for role in ('old-1', 'old-2', 'daily'):
            path = self.root / (role + '.json')
            D.save_new(path, dict(phase='restored', layoutPending=False, sourceUnresolved=False,
                                  session=BOOT, generation=1, baseline={}))
            self.field['records'].append(dict(role=role, path=str(path), sha256=D.digest(path)))

    def session(self, fake=None):
        fake = fake or Fake(self.field)
        journal = D.Journal(self.root, BOOT, 'a' * 64)
        self.addCleanup(journal.close)
        return D.Session(fake, self.field, journal), fake

    def absent_daily(self):
        entry = self.field['records'][-1]
        Path(entry['path']).unlink()
        state = self.root / 'daily-state'
        state.mkdir(mode=0o700)
        self.patch_default = patch.object(D, 'DEFAULT_STATE_DIRECTORY', state)
        self.patch_default.start()
        self.addCleanup(self.patch_default.stop)
        info = state.stat()
        entry.clear()
        entry.update(role='daily', path=str(state / 'recovery-record.json'), absent=True,
                     directoryIdentity=dict(device=info.st_dev, inode=info.st_ino))
        return entry

    def test_bound_absent_daily_needs_no_fake_record_and_does_not_quit_app(self):
        entry = self.absent_daily()
        (Path(entry['path']).parent / 'internal-session').mkdir(mode=0o700)
        D.validate_record_inventory(self.field)
        session, fake = self.session()
        report = session.execute()
        self.assertTrue(report['informationSufficient'])
        self.assertFalse(Path(entry['path']).exists())
        self.assertNotIn('daily-normal-exit', fake.calls)
        self.assertFalse(report['hardwareAcceptance'])

    def test_absent_flag_never_accepts_old_responsibility_or_live_daily(self):
        entry = self.absent_daily()
        for change in ('old-record', 'live-daily', 'fake-hash', 'wrong-name', 'custom-directory', 'invalid-inode'):
            field = copy.deepcopy(self.field)
            if change == 'old-record':
                field['records'][0] = dict(entry, role='old-1', path=str(self.root / 'old.json'))
            elif change == 'live-daily':
                field['daily'] = dict(pid=123)
            elif change == 'fake-hash':
                field['records'][-1]['sha256'] = 'a' * 64
            elif change == 'wrong-name':
                field['records'][-1]['path'] = str(Path(entry['path']).with_name('different.json'))
            elif change == 'custom-directory':
                field['records'][-1]['path'] = str(self.root / 'different/recovery-record.json')
            else:
                field['records'][-1]['directoryIdentity']['inode'] = True
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                D.validate_record_inventory(field)

    def test_record_appearing_after_quota_consumption_stops_before_sleep_request(self):
        entry = self.absent_daily()
        session, fake = self.session()
        original = session.journal.consume

        def consume(action):
            original(action)
            if action == 'sleep':
                D.save_new(entry['path'], dict(phase='owned', layoutPending=True))

        with patch.object(session.journal, 'consume', side_effect=consume):
            report = session.execute()
        self.assertEqual(report['stopReason'], 'daily-record-appeared')
        self.assertEqual(report['consumedActions'], {'sleep': 1})
        self.assertNotIn('sleep', fake.calls)

    def test_absence_does_not_hide_pending_internal_session(self):
        entry = self.absent_daily()
        state = Path(entry['path']).parent / 'internal-session'
        state.mkdir(mode=0o700)
        D.save_new(state / 'recovery-record.json', dict(phase='owned', layoutPending=True))
        session, fake = self.session()
        self.assertEqual(session.execute()['stopReason'], 'daily-record-appeared')
        self.assertNotIn('sleep', fake.calls)

    def test_absence_rejects_dangling_links_for_record_and_internal_directory(self):
        entry = self.absent_daily()
        record = Path(entry['path'])
        record.symlink_to(record.parent / 'missing')
        with self.assertRaisesRegex(RuntimeError, 'daily-record-appeared'):
            D.check_absent_daily(entry)
        record.unlink()
        (record.parent / 'internal-session').symlink_to(record.parent / 'missing-directory')
        with self.assertRaises(OSError):
            D.check_absent_daily(entry)

    def test_absence_never_treats_permission_or_replaced_directory_as_empty(self):
        entry = self.absent_daily()
        with patch.object(D.os, 'stat', side_effect=PermissionError('fixture')):
            with self.assertRaises(PermissionError):
                D.check_absent_daily(entry)
        state = Path(entry['path']).parent
        state.rename(state.with_name('retained-old-directory'))
        state.mkdir(mode=0o700)
        with self.assertRaisesRegex(RuntimeError, 'daily-directory-changed'):
            D.check_absent_daily(entry)

    def test_absence_requires_existing_private_parent_without_creating_it(self):
        entry = self.absent_daily()
        parent = Path(entry['path']).parent
        parent.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, 'private-directory-required'):
            D.check_absent_daily(entry)
        parent.chmod(0o700)
        parent.rmdir()
        with self.assertRaises(FileNotFoundError):
            D.check_absent_daily(entry)
        self.assertFalse(parent.exists())

    def test_present_day_record_does_not_gain_an_absent_shortcut(self):
        D.validate_record_inventory(self.field)
        session, fake = self.session()
        Path(self.field['records'][-1]['path']).unlink()
        report = session.execute()
        self.assertFalse(report['informationSufficient'])
        self.assertNotIn('sleep', fake.calls)

    def test_positive_pause_is_only_baseline_not_hardware_or_cause_acceptance(self):
        session, fake = self.session()
        report = session.execute()
        self.assertTrue(report['informationSufficient'])
        self.assertFalse(report['hardwareAcceptance'])
        self.assertEqual(report['ownerCausality'], 'unknown')
        self.assertEqual(report['physicalObservation'], 'normal')
        self.assertEqual(fake.calls.count('sleep'), 1)
        self.assertEqual(fake.snapshot_reads, 4)
        self.assertEqual(report['newDisableSessions'], 0)

    def test_human_timeout_preserves_machine_measurement_without_passing(self):
        session, fake = self.session()
        original_confirm = fake.confirm

        def delayed_confirm(phase):
            if phase == 'after':
                fake.c += 11 * D.NS
                fake.a += 11 * D.NS
                session.tick()
            return original_confirm(phase)

        fake.confirm = delayed_confirm
        report = session.execute()
        self.assertEqual(report['stopReason'], 'collection-deadline')
        self.assertIn('stop-recorder', fake.calls)
        self.assertTrue(report['sleepMeasurement']['measurementSupported'])
        self.assertFalse(report['informationSufficient'])
        self.assertEqual(report['physicalObservation'], 'unknown')
        self.assertEqual(fake.calls.count('sleep'), 1)

    def test_wake_topology_failure_preserves_measurement_and_still_stops(self):
        session, fake = self.session()
        fake.third_snapshot = lambda backend: setattr(backend, 'failure', 'incomplete-C')
        report = session.execute()
        self.assertEqual(report['stopReason'], 'incomplete-C')
        self.assertFalse(report['informationSufficient'])
        self.assertEqual(report['physicalObservation'], 'unknown')
        self.assertEqual(fake.snapshot_reads, 3)
        self.assertEqual(fake.calls.count('sleep'), 1)
        self.assertIn('stop-recorder', fake.calls)
        self.assertTrue(report['sleepMeasurement']['measurementSupported'])

    def test_failed_sleep_is_consumed_and_restart_or_copy_cannot_reclaim_candidate(self):
        session, fake = self.session()
        fake.failure = 'sleep-request-failed'
        report = session.execute()
        self.assertEqual(report['consumedActions'], {'sleep': 1})
        events = [json.loads(line) for line in session.journal.path.read_text().splitlines()]
        self.assertEqual([e['event'] for e in events if e.get('action') == 'sleep'], ['consume-before-request'])
        with self.assertRaises(FileExistsError):
            D.Journal(self.root, BOOT, 'b' * 64)
        with self.assertRaisesRegex(RuntimeError, 'quota-exhausted'):
            session.journal.consume('sleep')

    def test_journal_failure_prevents_action(self):
        session, fake = self.session()
        with patch.object(session.journal, 'consume', side_effect=OSError('fixture')):
            report = session.execute()
        self.assertNotIn('sleep', fake.calls)
        self.assertFalse(report['informationSufficient'])

    def test_directory_sync_failure_leaves_consumed_candidate_and_prevents_start(self):
        original = D.os.fsync

        def fail_directory(descriptor):
            if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                raise OSError('fixture-directory-sync-failed')
            original(descriptor)

        with patch.object(D.os, 'fsync', side_effect=fail_directory), self.assertRaises(OSError):
            D.Journal(self.root, BOOT, 'a' * 64)
        with self.assertRaises(FileExistsError):
            D.Journal(self.root, BOOT, 'a' * 64)

    def test_marker_arriving_between_event_read_and_clock_sample_is_valid(self):
        session, fake = self.session()
        session.journal.consume('sleep')
        fake.c = 1000

        def events():
            fake.c = 1600
            return [fake.evidence_event]

        fake.events = events
        session.tick()
        self.assertEqual(session.wake, fake.evidence_event)

    def test_preflight_failures_never_request_sleep_or_clear_responsibility(self):
        for failure in ('unexpected-controller', 'incomplete-C', 'internal-identity-unverified',
                        'sleep-preflight-blocked', 'observation-gap'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as other:
                # Each independent fixture gets its own candidate; production candidates cannot reset.
                ledger = Path(other)
                ledger.chmod(0o700)
                journal = D.Journal(ledger, BOOT, 'a' * 64)
                fake = Fake(self.field)
                fake.failure = failure
                before = {e['path']: Path(e['path']).read_bytes() for e in self.field['records']}
                try:
                    report = D.Session(fake, self.field, journal).execute()
                finally:
                    journal.close()
                self.assertFalse(report['informationSufficient'])
                self.assertNotIn('sleep', fake.calls)
                self.assertEqual(before, {p: Path(p).read_bytes() for p in before})

    def test_unresolved_old_record_blocks_even_if_software_C_is_normal(self):
        path = Path(self.field['records'][0]['path'])
        path.write_text(json.dumps(dict(phase='restoring', layoutPending=True, sourceUnresolved=False)))
        self.field['records'][0]['sha256'] = D.digest(path)
        session, fake = self.session()
        self.assertEqual(session.execute()['stopReason'], 'unresolved-responsibility')
        self.assertNotIn('sleep', fake.calls)

    def test_no_real_sleep_or_duplicate_pair_does_not_become_visual_failure(self):
        for mutation in ('zero', 'missing', 'duplicate', 'different-marker'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as other:
                journal = D.Journal(Path(other), BOOT, 'a' * 64)
                fake = Fake(self.field)
                if mutation == 'zero':
                    fake.capture = lambda name: FIX.capture(100, 100) if name == 'before' else FIX.capture(1000, 1000)
                    fake.data = FIX.evidence(1420)
                if mutation == 'missing':
                    fake.data['intervals'] = []
                if mutation == 'duplicate':
                    fake.data['intervals'] *= 2
                if mutation == 'different-marker':
                    fake.evidence_event = dict(fake.evidence_event, didWakeAtNanoseconds=1400)
                try:
                    report = D.Session(fake, self.field, journal).execute()
                finally:
                    journal.close()
                self.assertFalse(report['informationSufficient'])
                self.assertEqual(report['physicalObservation'], 'normal' if mutation == 'zero' else 'unknown')
                self.assertEqual(fake.calls.count('sleep'), 1)

    def test_abnormal_or_rescue_is_retained_and_no_restart_or_retry(self):
        for observation in ('abnormal', 'rescue'):
            with self.subTest(observation=observation), tempfile.TemporaryDirectory() as other:
                journal = D.Journal(Path(other), BOOT, 'a' * 64)
                fake = Fake(self.field)
                fake.after_visual = observation
                try:
                    report = D.Session(fake, self.field, journal).execute()
                finally:
                    journal.close()
                self.assertFalse(report['informationSufficient'])
                self.assertEqual(report['physicalObservation'], observation)
                self.assertTrue(report['safetyHandoffRequired'])
                self.assertEqual(fake.calls.count('sleep'), 1)
                self.assertNotIn('restart', fake.calls)

    def test_sleep_exceeding_total_deadline_does_not_get_ten_more_seconds(self):
        session, fake = self.session()
        fake.failure = 'sleep-over-total-deadline'
        report = session.execute()
        self.assertEqual(report['stopReason'], 'collection-deadline')
        self.assertEqual(fake.snapshot_reads, 2)

    def test_wake_deadline_and_observation_gap_are_distinct(self):
        session, fake = self.session()
        fake.third_snapshot = lambda f: setattr(f, 'c', 11 * D.NS)
        self.assertEqual(session.execute()['stopReason'], 'collection-deadline')
        self.assertLess(fake.snapshot_reads, 4)

    def test_cleanup_failure_never_reports_complete_information(self):
        session, fake = self.session()
        fake.cleanup = False
        self.assertFalse(session.execute()['informationSufficient'])

    def test_daily_quit_failure_consumes_only_the_exit_no_sleep(self):
        self.field['daily'] = dict(pid=123)
        session, fake = self.session()
        fake.failure = 'daily-exit-failed'
        report = session.execute()
        self.assertEqual(report['consumedActions'], {'daily-normal-exit': 1})
        self.assertNotIn('sleep', fake.calls)

    def test_changed_boot_blocks_before_daily_quit_or_sleep(self):
        self.field['daily'] = dict(pid=123)
        session, fake = self.session()
        fake.capture = lambda name: dict(wrapped=dict(bootSession='00000000-0000-0000-0000-000000000099'))
        self.assertEqual(session.execute()['stopReason'], 'boot-changed')
        self.assertNotIn('daily-normal-exit', fake.calls)
        self.assertNotIn('sleep', fake.calls)

    def test_daily_inflight_record_cannot_trigger_signal(self):
        backend = D.Mac.__new__(D.Mac)
        backend.bundle = self.root
        exe = self.root / 'Extilume'
        exe.write_bytes(b'fixture')
        entry = self.field['records'][-1]
        record = D.CLOCK.load_private(entry['path'])
        record['phase'] = 'applying'
        Path(entry['path']).write_text(json.dumps(record))
        backend.session = SimpleNamespace(records={'daily': entry})
        daily = dict(pid=123, executable=str(exe), sha256=D.digest(exe), recordSHA256=D.digest(entry['path']))
        with patch.object(backend, 'pid_path', return_value=str(exe)), \
                patch.object(D.os, 'kill', side_effect=AssertionError('must not signal')), \
                self.assertRaisesRegex(RuntimeError, 'daily-not-stable-primary'):
            backend.normal_exit(daily)

    def test_successful_daily_compensation_is_separate_from_diagnostic_writes(self):
        self.field['daily'] = dict(pid=123)
        entry = self.field['records'][-1]
        data = D.CLOCK.load_private(entry['path'])
        Path(entry['path']).write_text(json.dumps(dict(data, phase='owned', layoutPending=True)))
        session, fake = self.session()
        self.assertTrue(session.execute()['informationSufficient'])
        self.assertEqual(fake.calls.count('daily-normal-exit'), 1)

    def test_command_allowlist_rejects_control_before_subprocess(self):
        backend = D.Mac.__new__(D.Mac)
        backend.session = type('S', (), {'tick': lambda self: None})()
        backend.probe = self.root / 'probe'
        backend.bundle = self.root
        with patch.object(D.subprocess, 'Popen', side_effect=AssertionError('must not launch')):
            for args in (['--internal-app-session', '3'], ['--display-guard', '3'],
                         ['--closeout-layout-records', '--allow-record-write', '/private/field.json'],
                         ['--recover-primary', '3'], ['--display-snapshot', '-1'],
                         ['--sample-recovery-clock', '/outside/sample.json']):
                with self.subTest(args=args), self.assertRaisesRegex(RuntimeError, 'command-not-allowed'):
                    backend.spawn([str(backend.probe)] + args)

    def test_process_with_spaces_in_executable_path_is_not_missed(self):
        backend = D.Mac.__new__(D.Mac)
        backend.children = {}
        image = '/fixture/Build Products/Extilume.app/Contents/MacOS/Extilume'
        output = f'123 1 {os.getuid()} S {image}\n'
        with patch.object(D.subprocess, 'run', return_value=SimpleNamespace(stdout=output)), \
                patch.object(backend, 'pid_path', return_value=image), \
                self.assertRaisesRegex(RuntimeError, 'unexpected-controller'):
            backend.check_processes(None)

    def test_argv_mentioning_Extilume_does_not_masquerade_as_kernel_image(self):
        backend = D.Mac.__new__(D.Mac)
        backend.children = {}
        output = f'123 1 {os.getuid()} S /fixture/python Extilume/scripts/test.py\n'
        with patch.object(D.subprocess, 'run', return_value=SimpleNamespace(stdout=output)), \
                patch.object(backend, 'pid_path', return_value='/fixture/python'):
            backend.check_processes(None)

    def test_internal_witness_must_match_numeric_and_reported_identity_and_be_saved(self):
        for index, change in enumerate(({}, {'id': 999}, {'reportedIdentityUUID': BOOT}), 1):
            backend = D.Mac.__new__(D.Mac)
            backend.bundle, backend.snapshot_count = self.root, index
            inner = snapshot()['displays'][0]
            state = dict(id=inner['id'], identityUUID=inner['identityUUID'],
                         reportedIdentityUUID=inner['identityUUID'], hardwareIdentity={},
                         isBuiltIn=True, isOnline=True, isActive=True)
            state.update(change)
            reply = dict(state={'_0': state})
            with patch.object(backend, 'witness', return_value=reply):
                if change:
                    with self.assertRaisesRegex(RuntimeError, 'internal-identity-unverified'):
                        backend.internal_state(snapshot(), {})
                else:
                    backend.internal_state(snapshot(), {})
            self.assertEqual(D.CLOCK.load_private(self.root / f'internal-state-{index}.json'), reply)

    def test_local_dialog_uses_fixed_choices_and_remaining_deadline(self):
        for choice in ('normal', 'abnormal', 'rescue', 'cancel'):
            with self.subTest(choice=choice):
                backend = D.Mac.__new__(D.Mac)
                backend.children = {}
                backend.now = lambda: (2 * D.NS, 2 * D.NS)
                backend.session = SimpleNamespace(deadline=10 * D.NS, tick=Mock())
                backend.wait = Mock()
                process = Mock(pid=321, returncode=0, stdout=io.BytesIO())
                process.poll.side_effect = [None, 0]
                process.communicate.return_value = ((choice + '\n').encode(), None)
                with patch.object(D.subprocess, 'Popen', return_value=process) as spawn:
                    self.assertEqual(backend.confirm_dialog('after'), choice)
                self.assertEqual(spawn.call_args.args[0], ['/usr/bin/osascript', '-e', D.CONFIRM_DIALOG, 'after', '8'])
                self.assertEqual(backend.children[321][1], '/usr/bin/osascript')
                self.assertTrue(process.stdout.closed)
                backend.wait.assert_called_once()
                self.assertIn('default button 1', D.CONFIRM_DIALOG)

    def test_local_dialog_timeout_cannot_accept_late_normal(self):
        backend = D.Mac.__new__(D.Mac)
        backend.children = {}
        backend.now = lambda: (0, 0)
        backend.session = SimpleNamespace(deadline=10 * D.NS,
            tick=Mock(side_effect=[None, RuntimeError('collection-deadline')]))
        process = Mock(pid=321, returncode=0, stdout=io.BytesIO())
        process.poll.return_value = 0
        process.communicate.return_value = (b'normal\n', None)
        with patch.object(D.subprocess, 'Popen', return_value=process), self.assertRaisesRegex(RuntimeError, 'collection-deadline'):
            backend.confirm_dialog('after')
        self.assertTrue(process.stdout.closed)

    def test_dialog_failure_and_unknown_output_never_mean_normal(self):
        for output, code in [(b'normal\n', 1), (b'yes\n', 0), (b'x' * 33, 0)]:
            backend = D.Mac.__new__(D.Mac)
            backend.children = {}
            backend.now = lambda: (0, 0)
            backend.session = SimpleNamespace(deadline=10 * D.NS, tick=lambda: None)
            process = Mock(pid=321, returncode=code, stdout=io.BytesIO())
            process.poll.return_value = code
            process.communicate.return_value = (output, None)
            with patch.object(D.subprocess, 'Popen', return_value=process), self.assertRaises(RuntimeError):
                backend.confirm_dialog('after')

    def test_dialog_wait_preserves_immediate_anomaly_stop_and_cleanup_ownership(self):
        backend = D.Mac.__new__(D.Mac)
        backend.children = {}
        backend.now = lambda: (0, 0)
        backend.session = SimpleNamespace(deadline=10 * D.NS, tick=lambda: None)
        backend.wait = Mock(side_effect=RuntimeError('physical-anomaly'))
        process = Mock(pid=321, stdout=io.BytesIO())
        process.poll.return_value = None
        with patch.object(D.subprocess, 'Popen', return_value=process), self.assertRaisesRegex(RuntimeError, 'physical-anomaly'):
            backend.confirm_dialog('after')
        self.assertIs(backend.children[321][0], process)
        self.assertTrue(process.stdout.closed)

    def test_assertions_wait_handles_stop_instead_of_blocking_five_seconds(self):
        backend = D.Mac.__new__(D.Mac)
        backend.children = {}
        backend.session = SimpleNamespace(tick=lambda: None)
        backend.now = lambda: (0, 0)
        with tempfile.TemporaryFile() as output:
            process = SimpleNamespace(pid=123, stdout=output)
            with patch.object(D.subprocess, 'Popen', return_value=process), \
                    patch.object(backend, 'wait', side_effect=RuntimeError('physical-anomaly')), \
                    self.assertRaisesRegex(RuntimeError, 'physical-anomaly'):
                backend.preflight()

    def test_nonprivate_or_symlink_budget_is_refused(self):
        link = self.root / 'link'
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'private-directory-required'):
            D.Journal(link, BOOT, 'a' * 64)

    def test_nan_and_unknown_role_are_refused(self):
        for field in ('mode', 'identity'):
            value = snapshot()
            if field == 'mode':
                value['displays'][0]['mode']['refreshRate'] = float('nan')
            else:
                value['displays'][1]['identity'] = {'unknown': {}}
            with self.assertRaises(RuntimeError):
                D.signature(value)

    def prepare_bundle_in_temporary_repo(self, probe):
        source = Path(D.__file__).resolve().parents[1]
        repo = self.root / 'prepare-repo'
        scripts = repo / 'scripts'
        scripts.mkdir(mode=0o700, parents=True)
        for name in ('diagnose-recovery-baseline.py', 'calibrate-recovery-clock.py',
                     'verify-guard-interleavings.py', 'verify-guard-drill.py'):
            (scripts / name).write_bytes((source / 'scripts' / name).read_bytes())
        (repo / 'Package.swift').write_bytes((source / 'Package.swift').read_bytes())
        budget = repo / '.local/verification/dg1-budget'
        self.assertFalse(budget.parent.exists())
        with patch.object(D, '__file__', str(scripts / 'diagnose-recovery-baseline.py')):
            report = D.prepare(self.root / 'bundle', probe)
        self.assertEqual(stat.S_IMODE(budget.stat().st_mode), 0o700)
        return report

    def test_prepare_never_executes_program_or_accepts_field_authorization(self):
        probe = self.root / 'fixture-probe'
        probe.write_bytes(b'not an executable')
        with patch.object(D.subprocess, 'Popen', side_effect=AssertionError('must not launch')), \
                patch.object(D.subprocess, 'run', side_effect=AssertionError('must not launch')), \
                patch.object(D.CLOCK, 'native_sample', side_effect=AssertionError('must not sample')):
            report = self.prepare_bundle_in_temporary_repo(probe)
        self.assertFalse(report['fieldReady'])
        bundle = self.root / 'bundle'
        field = D.CLOCK.load_private(bundle / 'field.template.json')
        manifest = D.CLOCK.load_private(bundle / 'manifest.json')
        self.assertFalse(field['approved'])
        self.assertEqual(field['confirmationMethod'], 'local-dialog')
        with self.assertRaisesRegex(RuntimeError, 'field-authorization-required'):
            D.validate_field(bundle, manifest, field)

    def test_signed_input_still_cannot_use_negative_pid_or_relative_shared_budget(self):
        probe = self.root / 'fixture-probe'
        probe.write_bytes(b'fixture')
        bundle = self.root / 'bundle'
        self.prepare_bundle_in_temporary_repo(probe)
        manifest = D.CLOCK.load_private(bundle / 'manifest.json')
        field = D.CLOCK.load_private(bundle / 'field.template.json')
        field.update(approved=True, rescueOperator='user', rescueActions=['fixture-only'],
                     calibrationApplicable=True, lidOpenAndUnlocked=True, bootSession=BOOT,
                     internalHardwareIdentity=dict(bootSession=BOOT, registryEntryID=1),
                     records=self.field['records'], expectedC=snapshot(),
                     daily=dict(pid=-1, executable='/fixture/Extilume',
                                recordSHA256=self.field['records'][-1]['sha256']))
        with self.assertRaisesRegex(RuntimeError, 'invalid-daily-authorization'):
            D.validate_field(bundle, manifest, field)
        field['confirmationMethod'] = 'auto-normal'
        with self.assertRaisesRegex(RuntimeError, 'invalid-confirmation-method'):
            D.validate_field(bundle, manifest, field)
        manifest['budgetDirectory'] = 'relative-budget'
        with self.assertRaisesRegex(RuntimeError, 'absolute-budget-required'):
            D.validate_field(bundle, manifest, field)


if __name__ == '__main__':
    unittest.main()
