"""固定恢复或退出诊断单轮；prepare只构建隔离候选，run须绑定现场清单及已有授权。"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
import uuid

spec = importlib.util.spec_from_file_location('batch_gate', Path(__file__).with_name('recovery-batch-gate.py'))
G = importlib.util.module_from_spec(spec)
spec.loader.exec_module(G)
D = G.D
SCOPE = 'normal-recovery-single-batch-v2'
EXIT_SCOPE = 'exit-provenance-single-batch-v1'
UNATTENDED_EXIT_SCOPE = 'exit-machine-evidence-single-batch-v1'
TOOLS = ('run-recovery-batch.py', 'recovery-batch-gate.py', 'diagnose-recovery-baseline.py',
         'calibrate-recovery-clock.py', 'verify-guard-interleavings.py', 'verify-guard-drill.py')
DIALOG = '''on run argv
    try
        set answer to display dialog (item 1 of argv) with title "Extilume 单轮确认" buttons {"异常", "救援", "正常"} default button 1 giving up after ((item 2 of argv) as integer)
        if gave up of answer then return "cancel"
        if button returned of answer is "正常" then return "normal"
        if button returned of answer is "救援" then return "rescue"
        return "abnormal"
    on error
        return "cancel"
    end try
end run'''


class BatchMac(D.Mac):
    """复用只读witness/时钟/电源采集；进程白名单及截止归本批门禁。"""
    def __init__(self, bundle, field, gate):
        super().__init__(bundle, field)
        self.gate = gate
        self.session = self
        self.journal = gate.journal
        self.report = {}
        self.last_scan = None
        self.safety_deadline = None
        self.safety_requested_at = None
        self.registered_roles = set()

    @property
    def deadline(self):
        return self.safety_deadline if self.safety_deadline is not None else self.gate.deadline

    def check_processes(self, daily):
        output = subprocess.run(['ps', '-axo', 'pid=,ppid=,uid=,stat=,args='],
                                capture_output=True, text=True, check=True, timeout=1).stdout
        rows = [row.split(None, 4) for row in output.splitlines() if row.strip()]
        D.require(all(len(row) == 5 for row in rows), 'invalid-process-observation')
        if 'app' in self.gate.roles:
            parents = {int(row[0]): int(row[1]) for row in rows}
            def depth(row):
                parent = int(row[1])
                for level in range(3):
                    if parent == self.gate.roles['app']['pid']:
                        return level
                    parent = parents.get(parent)
                return 3
            rows.sort(key=depth)
        for pid, parent, uid, state, arguments in rows:
            if state.startswith('Z'):
                continue
            pid, parent = int(pid), int(parent)
            expected = self.children.get(pid)
            if expected is not None and expected[0] is not None and expected[0].poll() is not None:
                expected = None
            if expected is not None:
                image = self.pid_path(pid)
                D.require(image is None or (int(uid) == os.getuid() and image == expected[1]), 'process-image-mismatch')
                continue
            if not any(name in arguments for name in ('Extilume', 'extilume-probe', 'native-primary-preparation')):
                continue
            image = self.pid_path(pid)
            if image is None or Path(image).name not in ('Extilume', 'extilume-probe', 'native-primary-preparation'):
                continue
            parents = [role for role, binding in self.gate.roles.items() if binding['pid'] == parent]
            D.require(len(parents) == 1, 'unexpected-controller')
            binding = self.gate.roles[parents[0]]
            directory = self.bundle / 'state/internal-session'
            starting_role = None
            if parents[0] == 'app' and arguments == f"{image} --internal-app-session {directory} {parent} 198":
                starting_role = 'owner'
            elif parents[0] == 'owner' and arguments == f"{image} --display-guard {directory} 198":
                starting_role = 'helper'
            if starting_role is not None:
                D.require(self.gate.next_action == 1 and 'start' in self.gate.dispatched_controls
                          and starting_role not in self.gate.roles, 'unexpected-controller')
            flags = ('--display-snapshot', '--active-display-snapshot', '--internal-display-snapshot', '--external-display-snapshot')
            D.require(image == binding['executable'] and (starting_role is not None or arguments in
                      [f"{image} {flag} 198" for flag in flags]), 'unexpected-controller')
            try:
                observed = G.read_process_identity(pid)
            except RuntimeError:
                if G._query_process_info(pid) is None:
                    continue  # This exact read-only child exited during the finite process sample.
                raise
            self.gate.check_roles((parents[0],))
            D.require(observed['parentPID'] == parent and observed['executable'] == image
                      and observed['uid'] == int(uid) == os.getuid()
                      and G.process_key(G.read_process_identity(pid)) == G.process_key(observed),
                      'native-witness-unbound')
            if starting_role is not None:
                self.gate.bind(starting_role, observed)
                self.children[pid] = (None, image)
                self.journal.append(dict(event='native-starting-role-bound', role=starting_role))
            else:
                self.journal.append(dict(event='native-witness-observed', parentRole=parents[0]))

    def tick(self, force=False):
        if self.safety_deadline is not None:
            D.require(self.now()[0] < self.safety_deadline, 'safety-observation-deadline')
            return
        try:
            self.gate.tick()
            for role in ('owner', 'helper'):
                if role not in self.registered_roles and self.gate.native_budget_directory is not None:
                    path = self.gate.native_budget_directory / (role + '-process.json')
                    if path.exists():
                        if role == 'helper' and 'owner' not in self.gate.roles:
                            self.gate.bind_registered_process('owner')
                            self.registered_roles.add('owner')
                        self.gate.bind_registered_process(role)
                        self.registered_roles.add(role)
            for role in self.gate.roles.values():
                self.children.setdefault(role['pid'], (None, role['executable']))
            if self.gate.next_action < len(self.gate.actions):
                self.gate.check_roles(tuple(self.gate.roles))
            for event in self.events():
                self.gate.observe_power(event, self.field['bootSession'])
            now, awake = self.now()
            if force or self.last_scan is None or awake - self.last_scan >= D.NS:
                D.require(self.last_scan is None or 0 <= awake - self.last_scan <= 3 * D.NS, 'observation-gap')
                self.check_processes(None)
                self.check_records()
                self.last_scan = self.now()[1]
                D.require(self.last_scan - awake <= D.NS, 'process-observation-slow')
            self.gate.tick()
        except BaseException:
            self.gate._latch_stop()
            raise

    def check_records(self):
        for entry in self.field['records']:
            if entry.get('absent') is True:
                D.check_absent_daily(entry)
            else:
                D.require(D.digest(entry['path']) == entry['sha256'], 'responsibility-changed')
                D.restored(D.CLOCK.load_private(entry['path']))

    def visual(self, message):
        self.tick()
        seconds = max(1, (self.deadline - self.now()[0]) // D.NS)
        process = subprocess.Popen(['/usr/bin/osascript', '-e', DIALOG, message, str(seconds)],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            while process.poll() is None:
                self.wait()
            output, _ = process.communicate(timeout=.5)
            self.tick()
            D.require(process.returncode == 0 and len(output) <= 32, 'human-dialog-failed')
            answer = output.decode().strip()
            self.journal.append(dict(event='human-observation', answer=answer))
            D.require(answer == 'normal', 'physical-anomaly-or-unconfirmed')
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=1)
            process.stdout.close()

    def read_C(self, phase):
        snapshots = []
        for index in (1, 2):
            self.tick(force=True)
            value = self.witness('--display-snapshot')
            D.save_new(self.bundle / f'{phase}-{index}.json', value)
            D.require(D.signature(value) == D.signature(self.field['expectedC']), 'C-or-mode-mismatch')
            snapshots.append(value)
        inner = next(d for d in snapshots[-1]['displays'] if D.WIRE.identity_case(d['identity']) == 'builtIn')
        reply = self.witness('--internal-display-snapshot', dict(identity=inner['identityUUID'],
            numericIDHint=inner['id'], hardwareIdentity=self.field['internalHardwareIdentity']))
        D.save_new(self.bundle / f'{phase}-internal.json', reply)
        state = reply.get('state', {}).get('_0', {})
        D.require(state.get('isBuiltIn') is True and state.get('isOnline') is True and state.get('isActive') is True
                  and state.get('id') == inner['id'] and state.get('hardwareIdentity') == self.field['internalHardwareIdentity']
                  and str(uuid.UUID(state['identityUUID'])) == str(uuid.UUID(inner['identityUUID']))
                  and str(uuid.UUID(state['reportedIdentityUUID'])) == str(uuid.UUID(inner['identityUUID'])),
                  'internal-identity-unverified')
        self.tick()
        return snapshots, reply

    def wait_application(self, action):
        expected = 'applied' if action in ('start', 'sleep') else 'manualConfiguration'
        endpoints = {'start': 'disableFinished', 'restore': 'pauseVerificationFinished',
                     'confirm-user': 'configurationConfirmationFinished', 'sleep': 'disableFinished'}
        while True:
            self.tick()
            reply = self.gate.control_application('status')
            events = self.gate.native_events[self.gate.request_event_start:]
            if (reply.get('sessionState') == {expected: {}}
                    and any(e['role'] == 'controller' and e['stage'] == endpoints[action] for e in events)
                    and set(self.gate.roles) == set(G.ROLES)
                    and {'owner', 'helper'} <= self.registered_roles):
                return reply
            self.wait()

    def sleep_and_verify(self, before):
        while self.gate.power_event is None or self.gate.wake is None:
            self.wait()
        after = self.capture('after')
        evidence = self.stop_recorder()
        requested_at = self.now()[0]
        self.journal.append(dict(event='independent-wake-read-started', continuousNs=requested_at))
        snapshot = self.witness('--display-snapshot')
        observed_at = self.now()[0]
        D.save_new(self.bundle / 'wake-independent.private.json', dict(
            requestedAtNanoseconds=requested_at, observedAtNanoseconds=observed_at, snapshot=snapshot))
        roles = [D.WIRE.identity_case(display['identity']) for display in snapshot['displays']]
        self.journal.append(dict(event='independent-wake-read-finished', requestedAtNanoseconds=requested_at,
            observedAtNanoseconds=observed_at, online=sum(display['isOnline'] is True for display in snapshot['displays']),
            active=sum(display['isActive'] is True for display in snapshot['displays']),
            builtIn=roles.count('builtIn'), physical=roles.count('physical')))
        reply = self.wait_application('sleep')
        self.gate.verify_sleep(before, after, evidence, reply, self.field['probeSHA256'])
        self.visual('请确认：内屏已停用，外屏桌面正常且可操作。异常、已救援或超时将停止本轮。')
        return True

    def exit_and_verify(self):
        while (self.gate.application_process.poll() is None or not self.gate.stream.eof
               or not all(G.process_has_exited(binding) for binding in self.gate.roles.values())):
            self.wait()
        snapshots, internal = self.read_C('exit')
        return self.gate.verify_exit(self.field['expectedC'], self.field['internalHardwareIdentity'], snapshots, internal)

    def safety_handoff(self):
        """失败后只消费尚未派发的正常退出；不重试已派发的quit或终止控制进程。"""
        gate = self.gate
        gate._latch_stop()
        if self.safety_deadline is None:
            self.safety_deadline = self.now()[0] + 10 * D.NS
            self.safety_requested_at = gate.requested_at
        report = dict(normalQuitRequested=False, pipeEOF=gate.stream is None,
                      recoveryVerified=False, userHandoffRequired=True)
        try:
            self.tick()
            if 'app' in gate.roles and not G.process_has_exited(gate.roles['app']) and 'stop' not in gate.dispatched_controls:
                gate.dispatched_controls.add('stop')
                self.safety_requested_at = self.now()[0]
                self.journal.append(dict(event='consume-before-safety-quit', continuousNs=self.safety_requested_at))
                gate.check_roles(('app',))
                app = gate.roles['app']
                target = f"{app['pid']}:{app['startSeconds']}:{app['startMicroseconds']}"
                remaining = (self.safety_deadline - self.now()[0]) / D.NS
                D.require(remaining > 0, 'safety-observation-deadline')
                report['normalQuitRequested'] = True
                subprocess.run([app['executable'], '--control', 'quit', '--allow-display-write',
                                '--target-process', target], capture_output=True, timeout=remaining, check=False)
            while gate.application_process is not None and gate.application_process.poll() is None:
                self.wait()
            if gate.stream is not None:
                while not gate.stream.eof:
                    self.wait()
                report['pipeEOF'] = True
            while any(not G.process_has_exited(binding) for binding in gate.roles.values()):
                self.wait()
            self.tick()
            self.check_processes(None)
            self.check_records()
            # A failure remains a failure even if the allowed safety quit restores the desktop.
            snapshots, internal = self.read_C('handoff')
            report['softwareCVerified'] = True
            self.check_processes(None)
            self.check_records()
            gate.verify_restoration(self.field['expectedC'], self.field['internalHardwareIdentity'], snapshots, internal,
                                    self.safety_requested_at, self.now()[0], G.process_has_exited)
            self.tick()
            report['recoveryVerified'] = True
        except Exception:
            report.setdefault('softwareCVerified', False)
        self.journal.append(dict(event='safety-handoff', result=report))
        return report

    def close(self):
        # Dg1 owns only readers; bound display controllers are registered with a nil process handle.
        self.children = {pid: child for pid, child in self.children.items() if child[0] is not None}
        return super().close()


def close_gate_evidence(gate):
    try:
        gate.close()
    except RuntimeError as error:
        if str(error) != 'connection-evidence-incomplete':
            raise
        return False
    return gate.stream is None or (gate.stream.eof and not getattr(gate.stream, 'connection_error', False))


def execute(backend, gate, unattended=False):
    D.require(not unattended or gate.exit_only, 'unattended-requires-exit-only')
    result = dict(scope=UNATTENDED_EXIT_SCOPE if unattended else (EXIT_SCOPE if gate.exit_only else SCOPE), passed=False, hardwareAcceptance=False, automaticRetry=False,
                  processObservation='one-second-known-image-polling-with-transient-blind-spots')
    if unattended:
        result['physicalObservationPending'] = True
    try:
        backend.tick(force=True)
        backend.read_C('preflight')
        if not unattended:
            backend.visual('请确认开盖、已解锁，双屏画面正常且可操作。' + (
                '本轮仅一次停用后正常退出，不请求睡眠；异常即停止。' if gate.exit_only else
                '本轮最多两次停用、一次睡眠和一次正常退出；异常即停止。'))
        gate.launch_application(backend.bundle / 'state', backend.field['bootSession'])
        gate.wait_for_standby(wait=backend.wait)
        gate.request('start', lambda: gate.control_application('start')['result'] == 'accepted',
                     lambda: gate.verify_application('start', backend.wait_application('start')))
        if gate.exit_only:
            if not unattended:
                backend.visual('请确认内屏已停用，外屏画面正常且可操作；确认后仅请求一次正常退出。')
        else:
            gate.request('restore', lambda: gate.control_application('restore')['result'] == 'accepted',
                         lambda: gate.verify_application('restore', backend.wait_application('restore')))
            backend.read_C('confirmed-C')
            gate.confirm_configuration_visual(wait=backend.wait)
            gate.request('confirm-user', lambda: gate.control_application('confirm-user')['result'] == 'accepted',
                         lambda: gate.verify_application('confirm-user', backend.wait_application('confirm-user')))
            backend.preflight()
            before = backend.capture('before')
            backend.start_recorder()
            gate.request('sleep', lambda: backend.sleep_once() is None, lambda: backend.sleep_and_verify(before))
        gate.request('stop', lambda: gate.control_application('stop')['result'] == 'accepted', backend.exit_and_verify)
        if not unattended:
            backend.visual('请确认退出后内外两屏均正常、可操作，且未采取救援措施。')
        backend.tick(force=True)
        result['passed'] = True
    except BaseException as error:
        code = str(error) if type(error) is RuntimeError else ''
        result['stopReason'] = code if code and all(c in 'abcdefghijklmnopqrstuvwxyz-' for c in code) else 'evidence-or-command-failed'
        try:
            result['safetyHandoff'] = backend.safety_handoff()
        except BaseException:
            result['safetyHandoff'] = dict(userHandoffRequired=True, recoveryVerified=False)
    finally:
        try:
            result['observerCleanupComplete'] = backend.close()
        except Exception:
            result['observerCleanupComplete'] = False
        result['consumedRequests'] = gate.next_action
        result['confirmedRequests'] = gate.confirmed_requests
        result['nativeDisableObserved'] = gate.native_disable_count
        result['connectionEvidenceComplete'] = close_gate_evidence(gate)
        result['pipeEOF'] = gate.stream is None or gate.stream.eof
        result['passed'] = (result['passed'] and result['observerCleanupComplete'] and result['pipeEOF']
                            and result['connectionEvidenceComplete'])
    return result


def source_bindings(repo):
    paths = [repo / 'Package.swift']
    paths += [path for name in ('Sources', 'Tests', 'scripts') for path in (repo / name).rglob('*')
              if path.is_file() and '__pycache__' not in path.parts]
    return {str(path.relative_to(repo)): D.digest(path) for path in paths}


def prepare(directory, exit_only=False, unattended=False):
    D.require(not unattended or exit_only, 'unattended-requires-exit-only')
    repo = Path(__file__).resolve().parents[1]
    bundle = Path(directory).absolute()
    bundle.mkdir(mode=0o700)
    D.private_directory(bundle)
    bindings = source_bindings(repo)
    for name in ('scripts', 'bin', 'state'):
        (bundle / name).mkdir(mode=0o700)
    with D.CLOCK.private_file(bundle / 'build.log', create=True) as log:
        subprocess.run([sys.executable, str(repo / 'scripts/build-menu-bar-app.py'),
                        '--output', str(bundle / 'Extilume.app'), '-c', 'release'],
                       cwd=repo, stdout=log, stderr=log, check=True)
        subprocess.run(['swift', 'build', '-c', 'release', '--product', 'extilume-probe'],
                       cwd=repo, stdout=log, stderr=log, check=True)
    binary_directory = subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'],
                                               cwd=repo, text=True).strip()
    probe = bundle / 'bin/extilume-probe'
    shutil.copy2(Path(binary_directory) / 'extilume-probe', probe)
    probe.chmod(0o700)
    D.require(source_bindings(repo) == bindings, 'source-changed-during-build')
    for name, digest in bindings.items():
        path = bundle / 'source' / name
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_bytes((repo / name).read_bytes())
        path.chmod(0o600)
        D.require(D.digest(path) == digest, 'source-changed-during-freeze')
    for name in TOOLS:
        target = bundle / 'scripts' / name
        target.write_bytes((bundle / 'source/scripts' / name).read_bytes())
        target.chmod(0o600)
    budget = repo / '.local/verification' / ('exit-provenance-budgets' if exit_only else 'normal-recovery-budgets')
    budget.mkdir(mode=0o700, parents=True, exist_ok=True)
    D.private_directory(budget)
    files = {str(path.relative_to(bundle)): D.digest(path) for path in bundle.rglob('*')
             if path.is_file()}
    scope = UNATTENDED_EXIT_SCOPE if unattended else (EXIT_SCOPE if exit_only else SCOPE)
    manifest = dict(version=1, scope=scope, candidate=str(uuid.uuid4()), budgetDirectory=str(budget),
                    files=files, sources=bindings, macOS=platform.mac_ver()[0], architecture=platform.machine())
    D.save_new(bundle / 'manifest.json', manifest)
    D.save_new(bundle / 'field.template.json', dict(approved=False, scope=scope, candidate=manifest['candidate'],
        manifestSHA256=D.digest(bundle / 'manifest.json'), probeSHA256=D.digest(probe),
        macOS=manifest['macOS'], architecture=manifest['architecture'], bootSession=None,
        expectedC=None, internalHardwareIdentity=None, records=[], daily=None,
        calibrationApplicable=False, lidOpenAndUnlocked=False, rescueOperator='user',
        rescueActions=['normal-quit-once', 'user-takes-over'], actions=list(G.EXIT_ACTIONS if exit_only else G.ACTIONS),
        maximumNativeDisableAttempts=1 if exit_only else 2, maximumSleepRequests=0 if exit_only else 1,
        confirmationMethod='machine-evidence' if unattended else 'local-dialog', normalWakeReadiness=not exit_only))
    return dict(prepared=True, fieldReady=False, scope=scope)


def validate_field(bundle, manifest, field):
    unattended = manifest['scope'] == UNATTENDED_EXIT_SCOPE
    exit_only = manifest['scope'] in (EXIT_SCOPE, UNATTENDED_EXIT_SCOPE)
    D.require(manifest['version'] == 1 and manifest['scope'] in (SCOPE, EXIT_SCOPE, UNATTENDED_EXIT_SCOPE) and manifest['scope'] == field['scope']
              and field['approved'] is True and field['candidate'] == manifest['candidate']
              and field['manifestSHA256'] == D.digest(bundle / 'manifest.json'), 'field-authorization-required')
    D.require(field['actions'] == list(G.EXIT_ACTIONS if exit_only else G.ACTIONS)
              and type(field['maximumNativeDisableAttempts']) is int and field['maximumNativeDisableAttempts'] == (1 if exit_only else 2)
              and type(field['maximumSleepRequests']) is int and field['maximumSleepRequests'] == (0 if exit_only else 1)
              and field['confirmationMethod'] == ('machine-evidence' if unattended else 'local-dialog')
              and field['rescueOperator'] == 'user' and field['rescueActions'] == ['normal-quit-once', 'user-takes-over']
              and field['calibrationApplicable'] is True and field['lidOpenAndUnlocked'] is True
              and field['daily'] is None and field.get('normalWakeReadiness') is (not exit_only), 'field-handoff-or-limits-missing')
    D.require(field['macOS'] == manifest['macOS'] == platform.mac_ver()[0]
              and field['architecture'] == manifest['architecture'] == platform.machine(), 'environment-changed')
    D.require(uuid.UUID(field['bootSession']).int != 0
              and str(uuid.UUID(field['internalHardwareIdentity']['bootSession'])) == str(uuid.UUID(field['bootSession']))
              and type(field['internalHardwareIdentity']['registryEntryID']) is int
              and field['internalHardwareIdentity']['registryEntryID'] > 0, 'invalid-internal-proof')
    D.validate_record_inventory(field)
    D.signature(field['expectedC'])
    D.require(all('..' not in Path(name).parts and not Path(name).is_absolute() for name in manifest['files']),
              'invalid-candidate-path')
    required = {'Extilume.app/Contents/MacOS/Extilume', 'bin/extilume-probe'} | {'scripts/' + name for name in TOOLS}
    D.require(required <= set(manifest['files']) and manifest['sources'], 'incomplete-candidate')
    for name, expected in manifest['files'].items():
        path = bundle / name
        D.require(not any(parent.is_symlink() for parent in (path, *path.parents))
                  and D.digest(path) == expected, 'frozen-tool-changed')
    for name, digest in manifest['sources'].items():
        D.require(manifest['files'].get('source/' + name) == digest, 'source-binding-mismatch')
    D.require(field['probeSHA256'] == manifest['files']['bin/extilume-probe'], 'probe-binding-mismatch')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prep = commands.add_parser('prepare', help='构建并冻结隔离候选，不启动App或改变显示')
    prep.add_argument('--directory', required=True)
    prep.add_argument('--exit-only', action='store_true', help='独立冻结一次停用、一次正常退出、零睡眠的诊断候选')
    prep.add_argument('--unattended', action='store_true', help='仅用于零睡眠退出机器证据，不记录人工画面确认')
    run = commands.add_parser('run', help='执行已有授权的固定正常单轮，不包含故障注入或补轮')
    run.add_argument('--bundle', required=True)
    run.add_argument('--field', required=True)
    args = parser.parse_args(argv)
    gate = None
    try:
        if args.command == 'prepare':
            D.require(not args.unattended or args.exit_only, 'unattended-requires-exit-only')
            print(json.dumps(prepare(args.directory, exit_only=True, unattended=True) if args.unattended else
                             prepare(args.directory, exit_only=True) if args.exit_only else prepare(args.directory)))
            return 0
        if not sys.stdin.isatty():
            print('现场执行需要保持开启的交互终端；未领取额度或执行动作。', file=sys.stderr)
            return 1
        bundle = D.private_directory(Path(args.bundle).absolute())
        D.require(Path(__file__).resolve() == bundle / 'scripts/run-recovery-batch.py', 'run-frozen-copy-required')
        field_digest = D.digest(args.field)
        manifest_digest = D.digest(bundle / 'manifest.json')
        field = D.CLOCK.load_private(args.field)
        manifest = D.CLOCK.load_private(bundle / 'manifest.json')
        validate_field(bundle, manifest, field)
        D.require(D.digest(args.field) == field_digest and field['manifestSHA256'] == manifest_digest
                  == D.digest(bundle / 'manifest.json'), 'input-changed-during-validation')
        boot = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid'], text=True).strip()
        D.require(str(uuid.UUID(boot)) == str(uuid.UUID(field['bootSession'])), 'boot-changed')
        app = bundle / 'Extilume.app/Contents/MacOS/Extilume'
        binaries = {role: dict(executable=str(app), sha256=manifest['files']['Extilume.app/Contents/MacOS/Extilume'])
                    for role in G.ROLES}
        gate = G.RecoveryBatchGate(manifest['budgetDirectory'], manifest['candidate'], field_digest, binaries,
                                  lambda: D.CLOCK.native_bounds(D.CLOCK.native_sample())[1],
                                  normal_wake_readiness=field['normalWakeReadiness'], exit_only=field['scope'] in (EXIT_SCOPE, UNATTENDED_EXIT_SCOPE))
        result = execute(BatchMac(bundle, field, gate), gate, unattended=field['scope'] == UNATTENDED_EXIT_SCOPE)
        D.save_new(bundle / 'result.json', result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
        if not result['pipeEOF']:
            print('已停止本轮；保留采集进程排空管道，等待用户安全交接。', file=sys.stderr, flush=True)
            while not gate.stream.eof:
                try:
                    time.sleep(.1)
                except KeyboardInterrupt:
                    continue
            complete = close_gate_evidence(gate)
            D.save_new(bundle / 'handoff-pipe-eof.json', dict(pipeEOF=True, passed=False, connectionEvidenceComplete=complete))
        return 0 if result['passed'] else 1
    except Exception:
        print('候选未就绪或本轮已停止；检查私有回执和已消费额度。', file=sys.stderr)
        return 1
    finally:
        if gate is not None:
            close_gate_evidence(gate)


if __name__ == '__main__':
    raise SystemExit(main())
