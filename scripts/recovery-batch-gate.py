"""恢复批次的离线可测门禁；本模块没有显示控制动作或现场运行入口。"""
import ctypes
import importlib.util
import os
from pathlib import Path
import uuid

spec = importlib.util.spec_from_file_location('dg1', Path(__file__).with_name('diagnose-recovery-baseline.py'))
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)

ACTIONS = ('start', 'restore', 'confirm-user', 'sleep', 'stop')
ROLES = ('app', 'owner', 'helper')


def process_key(value):
    D.require(isinstance(value, dict) and set(value) == {
        'pid', 'uid', 'parentPID', 'startSeconds', 'startMicroseconds', 'executable'}, 'invalid-process-binding')
    for key in ('pid', 'uid', 'parentPID', 'startSeconds', 'startMicroseconds'):
        D.require(type(value[key]) is int and value[key] >= 0, 'invalid-process-binding')
    D.require(value['pid'] > 1 and value['parentPID'] > 0 and value['startSeconds'] > 0
              and value['startMicroseconds'] < 1_000_000
              and value['uid'] == os.getuid(), 'invalid-process-binding')
    D.require(isinstance(value['executable'], str) and Path(value['executable']).is_absolute(),
              'invalid-process-binding')
    return tuple(value[key] for key in sorted(value))


# Darwin proc_bsdinfo, from the SDK sys/proc_info.h (MAXCOMLEN = 16).
class ProcessBSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'parentPID', 'uid', 'gid', 'ruid',
        'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'jobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('startSeconds', ctypes.c_uint64),
                ('startMicroseconds', ctypes.c_uint64)]


def _read_process_info(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                    ctypes.c_void_p, ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    info = ProcessBSDInfo()
    size = ctypes.sizeof(info)
    D.require(library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) == size,
              'process-info-unavailable')
    D.require(info.pid == pid and info.status != 5, 'process-exited-or-changed')
    return {key: getattr(info, key) for key in (
        'pid', 'uid', 'parentPID', 'startSeconds', 'startMicroseconds')}


def read_process_identity(pid):
    D.require(type(pid) is int and 1 < pid <= 2**31 - 1, 'invalid-process-binding')
    before = _read_process_info(pid)
    path = D.Mac.pid_path(pid)
    after = _read_process_info(pid)
    D.require(before == after and path == D.Mac.pid_path(pid), 'process-reused-or-changed')
    result = dict(after, executable=path)
    process_key(result)
    return result


def application_checkpoint(action, reply, events, requested_at, observed_at, deadline):
    """核验绑定采集器给出的请求后事件与最新App状态；人工确认和退出使用各自凭证。"""
    D.require(action in ('start', 'restore'), 'unsupported-application-checkpoint')
    D.require(all(type(value) is int for value in (requested_at, observed_at, deadline))
              and 0 <= requested_at <= observed_at < deadline, 'invalid-completion-window')
    expected = 'applied' if action == 'start' else 'manualConfiguration'
    D.require(isinstance(reply, dict) and reply.get('result') == 'status'
              and reply.get('sessionState') == {expected: {}}
              and reply.get('selectedMode') == reply.get('stateMode') == 'externalOnly'
              and reply.get('requiresExplicitActivation') is False, 'application-not-completed')
    stages = ('disableStarted', 'disableFinished') if action == 'start' else (
        'restorationStarted', 'restorationVerified', 'pauseVerificationStarted', 'pauseVerificationFinished')
    D.require(isinstance(events, list), 'invalid-completion-events')
    position, previous = 0, requested_at
    for event in events:
        D.require(isinstance(event, dict) and event.get('type') == 'internal-lifecycle'
                  and event.get('role') == 'controller'
                  and event.get('clock') == 'mach_continuous_time/ns', 'invalid-completion-events')
        at, stage = event.get('continuousNs'), event.get('stage')
        D.require(type(at) is int and previous <= at <= observed_at and isinstance(stage, str),
                  'invalid-completion-events')
        previous = at
        D.require(event.get('succeeded') is not False and 'failureCode' not in event
                  and not stage.endswith(('Failed', 'Rejected'))
                  and stage not in ('firstConnectionInvalidation', 'sleepRequested'), 'completion-fault')
        if action == 'start':
            D.require(stage not in ('restorationStarted', 'enableStarted', 'enableBeginStarted'),
                      'unexpected-restoration')
        if action == 'restore':
            D.require(stage not in ('disableStarted', 'disableFinished'), 'unexpected-disable')
        if stage in stages:
            D.require(position < len(stages) and stage == stages[position], 'completion-event-order')
            if stage == 'disableFinished':
                D.require(event.get('succeeded') is True and event.get('operation') == 'disable',
                          'disable-not-confirmed')
            position += 1
    D.require(position == len(stages), 'completion-endpoint-missing')
    return True


class RecoveryBatchGate:
    def __init__(self, budget_directory, candidate, field_digest, binaries, now, read_process=None):
        D.require(set(binaries) == set(ROLES), 'missing-role-binary')
        self.binaries = {role: dict(binding) for role, binding in binaries.items()}
        for binding in self.binaries.values():
            D.require(set(binding) == {'executable', 'sha256'}
                      and Path(binding['executable']).is_absolute()
                      and D.digest(binding['executable']) == binding['sha256'], 'candidate-binary-mismatch')
        D.require(len(field_digest) == 64 and all(c in '0123456789abcdef' for c in field_digest), 'invalid-field-binding')
        self.now = now
        self.read_process = read_process_identity if read_process is None else read_process
        self.started = now()
        D.require(type(self.started) is int and self.started >= 0, 'invalid-clock')
        self.deadline = self.started + 180 * D.NS
        self.last_time = self.started
        self.journal = D.Journal(budget_directory, str(uuid.UUID(candidate)), field_digest)
        self.roles = {}
        self.next_action = self.confirmed_requests = 0
        self.sleep_request_at = self.wake = self.requested_at = None
        self.verifying = False
        self.stopped = self.inflight = self.closed = False

    def tick(self):
        D.require(not self.closed and not self.stopped, 'batch-stopped')
        current = self.now()
        D.require(type(current) is int and self.last_time <= current < self.deadline, 'batch-deadline')
        self.last_time = current

    def bind(self, role, observed):
        try:
            self.tick()
            D.require(role in ROLES and role not in self.roles, 'role-already-bound')
            key = process_key(observed)
            D.require(observed['executable'] == self.binaries[role]['executable'], 'role-image-mismatch')
            D.require(all(observed['pid'] != value['pid'] for value in self.roles.values()), 'role-pid-alias')
            parent = {'owner': 'app', 'helper': 'owner'}.get(role)
            if parent:
                D.require(parent in self.roles and observed['parentPID'] == self.roles[parent]['pid'], 'role-parent-mismatch')
            D.require(process_key(self.read_process(observed['pid'])) == key, 'process-reused-or-changed')
            D.require(D.digest(observed['executable']) == self.binaries[role]['sha256'], 'candidate-binary-mismatch')
            self.journal.append(dict(event='role-bound', role=role))
            self.roles[role] = dict(observed)
            self.tick()
        except BaseException:
            self.stopped = True
            raise

    def check_roles(self, roles):
        for role in roles:
            D.require(role in self.roles, 'role-not-bound')
            binding = self.roles[role]
            D.require(process_key(self.read_process(binding['pid'])) == process_key(binding), 'process-reused-or-changed')
            D.require(D.digest(binding['executable']) == self.binaries[role]['sha256'], 'candidate-binary-mismatch')

    def request(self, action, send, verify):
        try:
            self.tick()
            D.require(not self.inflight and self.next_action < len(ACTIONS)
                      and action == ACTIONS[self.next_action], 'action-order-or-quota')
            D.require(callable(send) and callable(verify), 'missing-action-adapter')
            required = ('app',) if action == 'start' else ROLES
            self.check_roles(required)
            self.tick()
            # Durable consumption precedes dispatch; failure or a late result never refunds it.
            self.journal.append(dict(event='consume-before-request', action=action))
            if action == 'sleep':
                self.sleep_request_at = self.last_time
            self.next_action += 1
            self.inflight = True
            self.tick()
            self.requested_at = self.last_time
            result = send()
            self.tick()
            D.require(result is True, 'action-not-accepted')
            self.journal.append(dict(event='action-accepted', action=action))
            self.tick()
            self.verifying = True
            D.require(verify() is True, 'action-not-confirmed')
            if action != 'stop':
                self.check_roles(ROLES)
            self.tick()
            self.journal.append(dict(event='action-confirmed', action=action))
            self.tick()
            self.confirmed_requests += 1
        except BaseException:
            self.stopped = True
            raise
        finally:
            self.inflight = self.verifying = False

    def verify_application(self, action, reply, events):
        try:
            self.tick()
            D.require(self.inflight and self.verifying and action == ACTIONS[self.next_action - 1],
                      'no-matching-pending-action')
            return application_checkpoint(action, reply, events, self.requested_at, self.last_time, self.deadline)
        except BaseException:
            self.stopped = True
            raise

    def observe_wake(self, at):
        try:
            self.tick()
            D.require(self.sleep_request_at is not None and self.wake is None
                      and type(at) is int and self.sleep_request_at <= at <= self.last_time,
                      'invalid-wake-boundary')
            self.wake = at
            self.deadline = min(self.deadline, at + 10 * D.NS)
            self.journal.append(dict(event='wake-boundary', continuousNs=at))
            self.tick()
        except BaseException:
            self.stopped = True
            raise

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.stopped = True
        try:
            self.journal.append(dict(event='gate-closed', consumed=self.next_action, confirmed=self.confirmed_requests,
                                     unconfirmedAction=ACTIONS[self.next_action - 1] if self.next_action > self.confirmed_requests else None,
                                     controllerCleanup='requires-bound-safety-handoff'))
        finally:
            self.journal.close()
