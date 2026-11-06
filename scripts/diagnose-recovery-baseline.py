"""Dg1 单轮被动基线。prepare 仅复制工具；run 必须另有具体现场授权。"""
import argparse
import ctypes
import errno
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
from types import SimpleNamespace
import uuid

sys.dont_write_bytecode = True


def load_tool(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CLOCK = load_tool('calibrate-recovery-clock')
WIRE = load_tool('verify-guard-interleavings')
SCOPE = 'Dg1-passive-dual-C'
NS = 1_000_000_000
# shortcut: absence covers only the default profile; extend after custom-profile ownership is verified.
DEFAULT_STATE_DIRECTORY = Path.home() / 'Library/Application Support/Extilume'


CONFIRM_DIALOG = r'''on run argv
    set phase to item 1 of argv
    set secondsLeft to (item 2 of argv) as integer
    if phase is "before" then
        set messageText to "确认双屏现在均正常、可操作。确认后将请求一次睡眠。熄屏不代表已经休眠，请勿看到熄屏就立即唤醒；按本轮约定唤醒，实际休眠以时钟证据判定。"
    else
        set messageText to "请检查内外两屏实际画面及操作。正常请选择正常；黑屏或抖动请选择异常；已经采取恢复措施请选择救援。超时不会记为正常。"
    end if
    try
        set answer to display dialog messageText with title "Extilume 诊断画面确认" buttons {"异常", "救援", "正常"} default button 1 giving up after secondsLeft
        if gave up of answer then return "cancel"
        set choice to button returned of answer
        if choice is "正常" then return "normal"
        if choice is "救援" then return "rescue"
        return "abnormal"
    on error
        return "cancel"
    end try
end run
'''


def require(value, code):
    if not value:
        raise RuntimeError(code)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save_new(path, value):
    with CLOCK.private_file(path, create=True) as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def private_directory(path):
    path = Path(path)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o700, 'private-directory-required')
    return path


def signature(snapshot):
    displays = snapshot['displays']
    require(len(displays) == 2, 'incomplete-C')
    result = {}
    for display in displays:
        role = WIRE.identity_case(display['identity'])
        require(role in ('builtIn', 'physical') and role not in result, 'identity-conflict')
        require(display['isOnline'] is True and display['isActive'] is True
                and display['isMirrored'] is False, 'incomplete-C')
        identity = str(uuid.UUID(display['identityUUID']))
        require(uuid.UUID(identity).int != 0, 'identity-conflict')
        mode = {key: display['mode'][key] for key in
                ('width', 'height', 'pixelWidth', 'pixelHeight', 'refreshRate')}
        require(all(type(value) in (int, float) and math.isfinite(value) and value > 0 for value in mode.values())
                and type(display['rotation']) in (int, float) and math.isfinite(display['rotation']), 'invalid-mode')
        result[role] = dict(identity=identity, x=WIRE.int32(display['originX']),
                            y=WIRE.int32(display['originY']), main=display['isMain'],
                            rotation=display['rotation'], mode=mode)
    require(result['builtIn']['main'] is True and result['physical']['main'] is False
            and result['builtIn']['x'] == result['builtIn']['y'] == 0, 'C-not-internal-main')
    require(result['builtIn']['identity'] != result['physical']['identity'], 'identity-conflict')
    return result


def restored(record):
    require(record['phase'] == 'restored' and record['layoutPending'] is False
            and record['sourceUnresolved'] is False
            and all(record.get(key) is None or record[key]['pending'] is False
                    for key in ('internalDisplay', 'externalDisplay')), 'unresolved-responsibility')


def validate_record_inventory(field):
    entries = field['records']
    require(len(entries) == 3 and {e['role'] for e in entries} == {'old-1', 'old-2', 'daily'},
            'responsibility-inventory-missing')
    require(all(Path(e['path']).is_absolute() for e in entries), 'absolute-record-paths-required')
    require(len({str(Path(e['path']).resolve()) for e in entries}) == 3, 'responsibility-inventory-duplicate')
    for entry in entries:
        require(type(entry.get('absent', False)) is bool, 'invalid-record-presence')
        if entry.get('absent') is True:
            require(entry['role'] == 'daily' and field['daily'] is None
                    and set(entry) == {'role', 'path', 'absent', 'directoryIdentity'}
                    and Path(entry['path']) == DEFAULT_STATE_DIRECTORY / 'recovery-record.json', 'invalid-absent-daily')
            identity = entry['directoryIdentity']
            require(set(identity) == {'device', 'inode'}
                    and all(type(v) is int and v >= 0 for v in identity.values())
                    and identity['inode'] > 0, 'invalid-directory-identity')
        else:
            binding = entry.get('sha256')
            require(isinstance(binding, str) and len(binding) == 64
                    and all(c in '0123456789abcdef' for c in binding), 'invalid-record-binding')
    if field['daily'] is not None:
        daily = field['daily']
        require(type(daily['pid']) is int and daily['pid'] > 1
                and Path(daily['executable']).is_absolute()
                and Path(daily['executable']).name == 'Extilume'
                and daily['recordSHA256'] == next(e['sha256'] for e in entries if e['role'] == 'daily'),
                'invalid-daily-authorization')


def check_absent_daily(entry):
    path = Path(entry['path'])
    require(path == DEFAULT_STATE_DIRECTORY / 'recovery-record.json', 'invalid-absent-daily')
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

    def require_private(info):
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o700, 'private-directory-required')

    def require_absent(directory):
        try:
            os.stat('recovery-record.json', dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            return
        raise RuntimeError('daily-record-appeared')

    try:
        info = os.fstat(descriptor)
        require_private(info)
        expected = entry['directoryIdentity']
        require((info.st_dev, info.st_ino) == (expected['device'], expected['inode']), 'daily-directory-changed')
        require_absent(descriptor)
        try:
            internal = os.open('internal-session', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
        except FileNotFoundError:
            internal = None
        if internal is not None:
            try:
                child = os.fstat(internal)
                require_private(child)
                require_absent(internal)
                current = os.stat('internal-session', dir_fd=descriptor, follow_symlinks=False)
                require((current.st_dev, current.st_ino) == (child.st_dev, child.st_ino), 'daily-directory-changed')
            finally:
                os.close(internal)
        current = path.parent.lstat()
        require((current.st_dev, current.st_ino) == (info.st_dev, info.st_ino), 'daily-directory-changed')
    finally:
        os.close(descriptor)


class Journal:
    def __init__(self, directory, candidate, field_digest):
        self.path = private_directory(directory) / (str(uuid.UUID(candidate)) + '.jsonl')
        self.stream = CLOCK.private_file(self.path, create=True)
        self.file = self.stream.__enter__()
        self.counts = {}
        try:
            self.append(dict(event='claimed', candidate=candidate, fieldSHA256=field_digest))
            for path in (self.path.parent, self.path.parent.parent):
                descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
        except BaseException:
            self.close()
            raise

    def append(self, value):
        self.file.write(json.dumps(value, separators=(',', ':')) + '\n')
        self.file.flush()
        os.fsync(self.file.fileno())

    def consume(self, action):
        require(action in ('daily-normal-exit', 'sleep') and not self.counts.get(action), 'quota-exhausted')
        self.append(dict(event='consume-before-request', action=action))
        self.counts[action] = 1

    def close(self):
        self.stream.__exit__(None, None, None)


class Session:
    def __init__(self, backend, field, journal):
        self.backend, self.field, self.journal = backend, field, journal
        backend.session = self
        self.start, _ = backend.now()
        self.deadline = self.start + 180 * NS
        self.last_scan = None
        self.wake = None
        self.scan_count = 0
        self.daily_pending = field['daily'] is not None
        self.records = {entry['role']: entry for entry in field['records']}
        self.report = dict(scope=SCOPE, informationSufficient=False, physicalObservation='unknown',
                           hardwareAcceptance=False, ownerCausality='unknown',
                           processObservation='one-second-polling-with-transient-blind-spots',
                           newDisableSessions=0, automaticRetry=False, safetyHandoffRequired=False,
                           confirmationMethod=field.get('confirmationMethod', 'terminal'))

    def tick(self, force=False):
        events = self.backend.events()
        now, awake = self.backend.now()
        for event in events:
            require(self.journal.counts.get('sleep') == 1 and self.wake is None, 'unexpected-power-event')
            CLOCK.uint(event['willSleepAtNanoseconds'])
            CLOCK.uint(event['didWakeAtNanoseconds'])
            require(event['bootSession'].lower() == self.field['bootSession'].lower()
                    and 0 <= event['willSleepAtNanoseconds'] < event['didWakeAtNanoseconds'] <= now,
                    'invalid-power-event')
            self.wake = event
            self.deadline = min(self.deadline, event['didWakeAtNanoseconds'] + 10 * NS)
        require(now < self.deadline, 'collection-deadline')
        if force or self.last_scan is None or awake - self.last_scan >= NS:
            require(self.last_scan is None or 0 <= awake - self.last_scan <= 3 * NS, 'observation-gap')
            self.backend.check_processes(self.field['daily'] if self.daily_pending else None)
            self.last_scan = self.backend.now()[1]
            require(self.last_scan - awake <= NS, 'process-observation-slow')
            self.scan_count += 1
            self.check_records()
        require(self.backend.now()[0] < self.deadline, 'collection-deadline')

    def check_records(self):
        for role, entry in self.records.items():
            if entry.get('absent') is True:
                require(role == 'daily' and self.field['daily'] is None, 'invalid-absent-daily')
                check_absent_daily(entry)
                continue
            if role == 'daily' and self.daily_pending:
                continue
            require(digest(entry['path']) == entry['sha256'], 'responsibility-changed')
            restored(CLOCK.load_private(entry['path']))

    def visual(self, phase):
        value = self.backend.confirm(phase)
        self.journal.append(dict(event='human-observation', phase=phase, value=value,
                                 observedAtNanoseconds=self.backend.now()[0]))
        if phase == 'after':
            self.report['physicalObservation'] = value
        require(value == 'normal', 'physical-anomaly' if value == 'abnormal'
                else 'human-rescue' if value == 'rescue' else 'human-cancelled')

    def check_C(self):
        self.tick(force=True)
        snapshot = self.backend.snapshot()
        displays = snapshot['displays']
        roles = []
        for display in displays:
            try:
                roles.append(WIRE.identity_case(display['identity']))
            except Exception:
                roles.append('other')
        self.report['lastTopology'] = dict(
            online=sum(d.get('isOnline') is True for d in displays),
            active=sum(d.get('isActive') is True for d in displays),
            activeBuiltIn=sum(d.get('isActive') is True and role == 'builtIn' for d, role in zip(displays, roles)),
            activePhysical=sum(d.get('isActive') is True and role == 'physical' for d, role in zip(displays, roles)))
        self.journal.append(dict(event='topology-observation', counts=self.report['lastTopology'],
                                 observedAtNanoseconds=self.backend.now()[0]))
        actual = signature(snapshot)
        require(actual == signature(self.field['expectedC']), 'C-or-mode-mismatch')
        self.backend.internal_state(snapshot, self.field['internalHardwareIdentity'])
        self.tick()

    def execute(self):
        try:
            self.tick(force=True)
            before = self.backend.capture('before')
            require(before['wrapped']['bootSession'].lower() == self.field['bootSession'].lower(), 'boot-changed')
            if self.daily_pending:
                self.journal.consume('daily-normal-exit')
                prior_record = self.backend.normal_exit(self.field['daily'])
                self.daily_pending = False
                entry = self.records['daily']
                after = CLOCK.load_private(entry['path'])
                restored(after)
                require(all(after[key] == prior_record[key] for key in ('session', 'generation', 'baseline')),
                        'daily-responsibility-changed')
                entry['sha256'] = digest(entry['path'])
                self.journal.append(dict(event='daily-compensation-completed', recordSHA256=entry['sha256']))
            self.check_C()
            self.check_C()
            self.visual('before')
            self.backend.preflight()
            self.backend.start_recorder()
            self.tick(force=True)
            self.journal.consume('sleep')
            self.tick(force=True)
            self.backend.sleep_once()
            while self.wake is None:
                self.backend.wait()
            after = self.backend.capture('after')
            evidence = self.backend.stop_recorder()
            assessment = CLOCK.compare(before, after, evidence)
            require(evidence['intervals'][0]['powerEvent'] == self.wake, 'wake-marker-mismatch')
            # Preserve timing evidence before topology or human checks can stop this round.
            self.report['sleepMeasurement'] = assessment
            self.journal.append(dict(event='machine-measurement', assessment=assessment))
            self.check_C()
            self.check_C()
            self.tick(force=True)
            self.visual('after')
            require(assessment['measurementSupported'] is True, 'real-sleep-unproved')
            self.tick(force=True)
            self.report['informationSufficient'] = True
        except BaseException as error:
            self.report['stopReason'] = str(error) if type(error) is RuntimeError else 'evidence-or-command-failed'
            self.report['safetyHandoffRequired'] = True
        finally:
            try:
                self.report['observerCleanupComplete'] = self.backend.close()
            except Exception:
                self.report['observerCleanupComplete'] = False
            if not self.report['observerCleanupComplete']:
                self.report.update(informationSufficient=False, safetyHandoffRequired=True)
            self.report.update(consumedActions=dict(self.journal.counts), processSamples=self.scan_count)
            self.journal.append(dict(event='finished', result=self.report))
        return self.report


class Mac:
    def __init__(self, bundle, field):
        self.bundle, self.field = Path(bundle), field
        self.probe = self.bundle / 'bin/extilume-probe'
        self.children = {}
        self.recorder = None
        self.buffer = b''
        self.ready = False
        self.checkpoint = None
        self.answer = None
        self.snapshot_count = 0
        self.input_fd = sys.stdin.fileno()
        self.input_buffer = b''

    def now(self):
        bounds = CLOCK.native_bounds(CLOCK.native_sample())
        return bounds[1], bounds[3]

    @staticmethod
    def pid_path(pid):
        library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        library.proc_pidpath.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(4096)
        ctypes.set_errno(0)
        result = library.proc_pidpath(pid, buffer, len(buffer))
        if result <= 0 and ctypes.get_errno() == errno.ESRCH:
            return None
        require(result > 0, 'process-image-unavailable')
        return buffer.value.decode()

    def check_processes(self, daily):
        output = subprocess.run(['ps', '-axo', 'pid=,ppid=,uid=,stat=,args='],
                                capture_output=True, text=True, check=True, timeout=1).stdout
        rows = [row.split(None, 4) for row in output.splitlines() if row.strip()]
        self.rows = rows
        require(all(len(row) == 5 for row in rows), 'invalid-process-observation')
        for pid, _, uid, state, arguments in rows:
            if state.startswith('Z'):
                continue
            pid = int(pid)
            expected = self.children.get(pid)
            if expected is not None and expected[0] is not None and expected[0].poll() is not None:
                expected = None
            if daily and pid == daily['pid']:
                expected = (None, daily['executable'])
            if expected:
                image = self.pid_path(pid)
                if image is None:
                    continue
                require(int(uid) == os.getuid() and image == expected[1], 'process-image-mismatch')
            else:
                names = ('Extilume', 'extilume-probe', 'native-primary-preparation')
                if any(name in arguments for name in names):
                    image = self.pid_path(pid)
                    require(image is None or Path(image).name not in names, 'unexpected-controller')

    def spawn(self, arguments, **kwargs):
        self.session.tick()
        require(len(arguments) == 3 and arguments[0] == str(self.probe) and arguments[1] in (
            '--display-snapshot', '--internal-display-snapshot', '--sample-recovery-clock',
            '--record-suspension-evidence'), 'command-not-allowed')
        if arguments[1] in ('--display-snapshot', '--internal-display-snapshot'):
            require(arguments[2].isdigit() and int(arguments[2]) >= 3, 'command-not-allowed')
        else:
            require(Path(arguments[2]).parent == self.bundle, 'command-not-allowed')
        require(digest(self.probe) == self.field['probeSHA256'], 'probe-changed')
        kwargs.setdefault('stdout', subprocess.DEVNULL)
        process = subprocess.Popen(arguments, stderr=subprocess.DEVNULL, **kwargs)
        self.children[process.pid] = (process, str(self.probe))
        return process

    def wait(self):
        self.session.tick()
        time.sleep(.05)

    def reap(self, process):
        deadline = min(self.session.deadline, self.now()[0] + 5 * NS)
        while process.poll() is None:
            self.wait()
            require(self.now()[0] < deadline, 'read-only-child-timeout')
        require(process.returncode == 0, 'read-only-child-failed')

    def witness(self, flag, request=None):
        parent, child = socket.socketpair()
        try:
            process = self.spawn([str(self.probe), flag, str(child.fileno())],
                                 stdin=subprocess.DEVNULL, pass_fds=(child.fileno(),))
            child.close()
            if request is not None:
                WIRE.send_frame(parent, request)
            parent.setblocking(False)
            deadline = min(self.session.deadline, self.now()[0] + 5 * NS)
            data = bytearray()
            size = None
            while size is None or len(data) < size + 4:
                self.wait()
                require(self.now()[0] < deadline, 'read-only-child-timeout')
                if select.select([parent], [], [], 0)[0]:
                    chunk = parent.recv(4096)
                    require(chunk, 'witness-eof')
                    data.extend(chunk)
                    if len(data) >= 4 and size is None:
                        size = struct.unpack('>I', data[:4])[0]
                        require(0 < size <= WIRE.MAX_MESSAGE, 'invalid-witness-frame')
            require(len(data) == size + 4, 'invalid-witness-frame')
            self.reap(process)
            return json.loads(data[4:])
        finally:
            parent.close()
            child.close()

    def snapshot(self):
        self.snapshot_count += 1
        require(self.snapshot_count <= 4, 'snapshot-quota-exhausted')
        result = self.witness('--display-snapshot')
        save_new(self.bundle / ('snapshot-' + str(self.snapshot_count) + '.json'), result)
        return result

    def internal_state(self, snapshot, hardware):
        inner = next(d for d in snapshot['displays'] if WIRE.identity_case(d['identity']) == 'builtIn')
        reply = self.witness('--internal-display-snapshot', dict(
            identity=inner['identityUUID'], numericIDHint=inner['id'], hardwareIdentity=hardware))
        save_new(self.bundle / ('internal-state-' + str(self.snapshot_count) + '.json'), reply)
        state = reply.get('state', {}).get('_0', {})
        require(state.get('isBuiltIn') is True and state.get('isOnline') is True
                and state.get('isActive') is True and state.get('hardwareIdentity') == hardware
                and type(state.get('id')) is int and state['id'] == inner['id']
                and str(state.get('identityUUID', '')).lower() == inner['identityUUID'].lower()
                and str(state.get('reportedIdentityUUID', '')).lower() == inner['identityUUID'].lower(),
                'internal-identity-unverified')

    def normal_exit(self, daily):
        require(digest(daily['executable']) == daily['sha256']
                and digest(self.session.records['daily']['path']) == daily['recordSHA256']
                and self.pid_path(daily['pid']) == daily['executable'], 'daily-binding-changed')
        before = CLOCK.load_private(self.session.records['daily']['path'])
        require(before['phase'] == 'owned' and before['sourceUnresolved'] is False
                and before.get('internalDisplay') is None and before.get('externalDisplay') is None,
                'daily-not-stable-primary')
        save_new(self.bundle / 'daily-before.json', before)
        expected = signature(self.field['expectedC'])
        main, origins = WIRE.layout_key(before['baseline'])
        require(str(main) == expected['builtIn']['identity'] and origins == {
            uuid.UUID(d['identity']): (d['x'], d['y']) for d in expected.values()}, 'daily-C-mismatch')
        self.session.tick(force=True)
        os.kill(daily['pid'], signal.SIGTERM)
        while True:
            self.wait()
            if not any(row[0] == str(daily['pid']) and not row[3].startswith('Z') for row in self.rows):
                return before

    def confirm(self, phase):
        print(json.dumps(dict(checkpoint=phase, choices=['normal', 'abnormal', 'rescue', 'cancel'])), flush=True)
        self.checkpoint = phase
        try:
            if self.field.get('confirmationMethod', 'terminal') == 'local-dialog':
                return self.confirm_dialog(phase)
            while self.answer is None:
                self.wait()
            value, self.answer = self.answer, None
            return value
        finally:
            self.checkpoint = None

    def confirm_dialog(self, phase):
        self.session.tick()
        remaining = (self.session.deadline - self.now()[0]) / NS
        require(remaining > 0, 'collection-deadline')
        process = subprocess.Popen(
            ['/usr/bin/osascript', '-e', CONFIRM_DIALOG, phase, str(max(1, min(180, int(remaining))))],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.children[process.pid] = (process, '/usr/bin/osascript')
        try:
            while process.poll() is None:
                self.wait()
            output, _ = process.communicate(timeout=.5)
            self.session.tick()
            require(process.returncode == 0 and len(output) <= 32, 'human-dialog-failed')
            value = output.decode().strip()
            require(value in ('normal', 'abnormal', 'rescue', 'cancel'), 'invalid-human-input')
            return value
        finally:
            process.stdout.close()

    def preflight(self):
        def assertions(command, **_kwargs):
            require(command == ['/usr/bin/pmset', '-g', 'assertions'], 'command-not-allowed')
            self.session.tick()
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            self.children[process.pid] = (process, '/usr/bin/pmset')
            os.set_blocking(process.stdout.fileno(), False)
            output = bytearray()
            deadline = self.now()[0] + 5 * NS
            try:
                while True:
                    self.wait()
                    require(self.now()[0] < deadline, 'sleep-preflight-timeout')
                    chunk = process.stdout.read(4096)
                    if chunk:
                        output.extend(chunk)
                        require(len(output) <= 65536, 'sleep-preflight-output-limit')
                    elif chunk == b'' and process.poll() is not None:
                        break
                return SimpleNamespace(returncode=process.returncode, stdout=output.decode())
            finally:
                process.stdout.close()
        result = CLOCK.preflight(runner=assertions)
        self.session.tick()
        require(result['preflightPassed'], 'sleep-preflight-blocked')

    def capture(self, name):
        path = self.bundle / (name + '-clock.json')
        wrapped = self.bundle / (name + '-clock.probe.json')
        first = CLOCK.native_sample()
        process = self.spawn([str(self.probe), '--sample-recovery-clock', str(wrapped)], stdin=subprocess.DEVNULL)
        self.reap(process)
        last = CLOCK.native_sample()
        value = dict(version=1, probeSHA256=digest(self.probe), before=first,
                     wrapped=CLOCK.load_private(wrapped), after=last)
        CLOCK.validate_capture(value)
        save_new(path, value)
        return value

    def start_recorder(self):
        read_fd, write_fd = os.pipe()
        try:
            # stdout is a bounded marker stream, never a desktop or raw system log.
            self.recorder = self.spawn(
                [str(self.probe), '--record-suspension-evidence', str(self.bundle / 'suspension.json')],
                stdin=subprocess.PIPE, stdout=write_fd)
        finally:
            os.close(write_fd)
        self.read_fd = read_fd
        os.set_blocking(read_fd, False)
        deadline = min(self.session.deadline, self.now()[0] + 5 * NS)
        while not self.ready:
            self.wait()
            require(self.now()[0] < deadline, 'power-recorder-not-ready')

    def events(self):
        events = []
        if select.select([self.input_fd], [], [], 0)[0]:
            chunk = os.read(self.input_fd, 128)
            require(chunk, 'human-input-closed')
            self.input_buffer += chunk
            require(len(self.input_buffer) <= 128, 'invalid-human-input')
        while b'\n' in self.input_buffer:
            line, self.input_buffer = self.input_buffer.split(b'\n', 1)
            value = line.decode().strip()
            if value in ('abnormal', 'rescue'):
                self.session.report['physicalObservation'] = value
                self.session.journal.append(dict(event='human-immediate-stop', value=value,
                                                  observedAtNanoseconds=self.now()[0]))
                raise RuntimeError('physical-anomaly' if value == 'abnormal' else 'human-rescue')
            require(value == 'normal' and self.field.get('confirmationMethod', 'terminal') == 'terminal'
                    and self.checkpoint is not None and self.answer is None,
                    'human-cancelled-or-unexpected-input')
            self.answer = value
        if self.recorder is None:
            return events
        require(self.recorder.poll() is None, 'power-recorder-exited')
        while select.select([self.read_fd], [], [], 0)[0]:
            chunk = os.read(self.read_fd, 4096)
            require(chunk, 'power-recorder-eof')
            self.buffer += chunk
            require(len(self.buffer) <= 8192, 'invalid-power-marker')
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                text = line.decode()
                if '采集已就绪' in text:
                    self.ready = True
                elif text.startswith('{'):
                    value = json.loads(text)
                    if value.get('type') == 'power-event-observation':
                        require(value.get('clock') == 'mach_continuous_time/ns', 'invalid-power-marker')
                        events.append(value['powerEvent'])
        return events

    def sleep_once(self):
        self.session.tick(force=True)
        process = subprocess.Popen(['/usr/bin/pmset', 'sleepnow'], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children[process.pid] = (process, '/usr/bin/pmset')
        self.reap(process)

    def stop_recorder(self):
        recorder, self.recorder = self.recorder, None
        recorder.stdin.write(b'stop\n')
        recorder.stdin.close()
        self.reap(recorder)
        os.close(self.read_fd)
        return CLOCK.load_private(self.bundle / 'suspension.json')

    def close(self):
        if self.recorder is not None:
            try:
                self.recorder.stdin.write(b'stop\n')
                self.recorder.stdin.close()
            except (BrokenPipeError, OSError):
                pass
        complete = True
        for process, _ in self.children.values():
            try:
                if process.poll() is None:
                    # Only these task-owned readers/pmset are reaped; never an owner/helper or daily App.
                    process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    complete = False
        if hasattr(self, 'read_fd'):
            try:
                os.close(self.read_fd)
            except OSError:
                pass
        return complete


def validate_field(bundle, manifest, field):
    require(manifest['version'] == 1 and manifest['scope'] == SCOPE and set(manifest['files']) == {
        'scripts/diagnose-recovery-baseline.py', 'scripts/calibrate-recovery-clock.py',
        'scripts/verify-guard-interleavings.py', 'scripts/verify-guard-drill.py', 'bin/extilume-probe'},
        'invalid-candidate-manifest')
    require(Path(manifest['budgetDirectory']).is_absolute(), 'absolute-budget-required')
    private_directory(bundle / 'scripts')
    private_directory(bundle / 'bin')
    require(field['approved'] is True and field['scope'] == SCOPE
            and field['candidate'] == manifest['candidate']
            and field['manifestSHA256'] == digest(bundle / 'manifest.json')
            and field['probeSHA256'] == manifest['files']['bin/extilume-probe'], 'field-authorization-required')
    require(field.get('confirmationMethod', 'terminal') in ('terminal', 'local-dialog'), 'invalid-confirmation-method')
    require(field['rescueOperator'] == 'user' and isinstance(field['rescueActions'], list)
            and len(field['rescueActions']) > 0
            and field['calibrationApplicable'] is True and field['lidOpenAndUnlocked'] is True,
            'field-handoff-or-calibration-missing')
    require(field['macOS'] == platform.mac_ver()[0] and field['architecture'] == platform.machine(), 'environment-changed')
    require(uuid.UUID(field['bootSession']).int != 0, 'invalid-boot')
    require(field['internalHardwareIdentity']['bootSession'].lower() == field['bootSession'].lower()
            and type(field['internalHardwareIdentity']['registryEntryID']) is int
            and field['internalHardwareIdentity']['registryEntryID'] > 0, 'invalid-internal-proof')
    validate_record_inventory(field)
    signature(field['expectedC'])
    for name, expected in manifest['files'].items():
        path = bundle / name
        require(not path.is_symlink() and digest(path) == expected, 'frozen-tool-changed')


def prepare(directory, probe):
    repo = Path(__file__).resolve().parents[1]
    directory = Path(directory).absolute()
    directory.mkdir(mode=0o700)
    private_directory(directory)
    (directory / 'scripts').mkdir(mode=0o700)
    (directory / 'bin').mkdir(mode=0o700)
    names = ['diagnose-recovery-baseline.py', 'calibrate-recovery-clock.py',
             'verify-guard-interleavings.py', 'verify-guard-drill.py']
    for name in names:
        target = directory / 'scripts' / name
        target.write_bytes((repo / 'scripts' / name).read_bytes())
        target.chmod(0o600)
    target = directory / 'bin/extilume-probe'
    target.write_bytes(Path(probe).read_bytes())
    target.chmod(0o700)
    budget = repo / '.local/verification/dg1-budget'
    budget.mkdir(mode=0o700, parents=True, exist_ok=True)
    private_directory(budget)
    manifest = dict(version=1, scope=SCOPE, candidate=str(uuid.uuid4()), budgetDirectory=str(budget),
                    files={str(p.relative_to(directory)): digest(p) for p in directory.rglob('*') if p.is_file()},
                    sources={str(p.relative_to(repo)): digest(p) for d in ('Sources', 'Tests', 'scripts')
                             for p in (repo / d).rglob('*') if p.is_file() and '__pycache__' not in p.parts},
                    macOS=platform.mac_ver()[0], architecture=platform.machine(), fieldReady=False)
    manifest['sources']['Package.swift'] = digest(repo / 'Package.swift')
    save_new(directory / 'manifest.json', manifest)
    save_new(directory / 'field.template.json', dict(
        approved=False, scope=SCOPE, candidate=manifest['candidate'], manifestSHA256=digest(directory / 'manifest.json'),
        probeSHA256=manifest['files']['bin/extilume-probe'], macOS=manifest['macOS'], architecture=manifest['architecture'],
        bootSession=None, expectedC=None, internalHardwareIdentity=None, records=[], daily=None,
        rescueOperator=None, rescueActions=[], calibrationApplicable=False, lidOpenAndUnlocked=False,
        confirmationMethod='local-dialog'))
    return dict(scope=SCOPE, prepared=True, fieldReady=False, hardwareAcceptance=False)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prep = commands.add_parser('prepare', help='仅复制工具和写未授权模板，不运行任何候选')
    prep.add_argument('--directory', required=True)
    prep.add_argument('--probe', required=True)
    run = commands.add_parser('run', help='仅现场单独授权后使用；包含一次普通睡眠')
    run.add_argument('--bundle', required=True)
    run.add_argument('--field', required=True)
    args = parser.parse_args(argv)
    journal = None
    try:
        if args.command == 'prepare':
            report = prepare(args.directory, args.probe)
        else:
            bundle = private_directory(args.bundle)
            require(Path(__file__).resolve() == bundle / 'scripts/diagnose-recovery-baseline.py', 'run-frozen-copy-required')
            manifest, field = CLOCK.load_private(bundle / 'manifest.json'), CLOCK.load_private(args.field)
            validate_field(bundle, manifest, field)
            require(sys.platform == 'darwin', 'macOS-required')
            journal = Journal(manifest['budgetDirectory'], manifest['candidate'], digest(args.field))
            report = Session(Mac(bundle, field), field, journal).execute()
            save_new(bundle / 'result.json', report)
        print(json.dumps(report, ensure_ascii=False))
        return 0 if report.get('prepared') or report.get('informationSufficient') else 1
    except Exception:
        print('Dg1 未就绪或已停止；不重试，不清责任。请检查私有准备清单及已有配额。', file=sys.stderr)
        return 1
    finally:
        if journal is not None:
            journal.close()


if __name__ == '__main__':
    raise SystemExit(main())
