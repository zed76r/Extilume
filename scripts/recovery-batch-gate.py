"""恢复批次的离线可测门禁；控制适配器仅由已记账请求调用，本模块没有现场运行入口。"""
import ctypes
import errno
import importlib.util
import os
import json
import subprocess
import select
import fcntl
import stat
import sys
import threading
import time
from pathlib import Path
import uuid

spec = importlib.util.spec_from_file_location('dg1', Path(__file__).with_name('diagnose-recovery-baseline.py'))
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)

ACTIONS = ('start', 'restore', 'confirm-user', 'sleep', 'stop')
ROLES = ('app', 'owner', 'helper')
LIFECYCLE_STAGES = frozenset("""
sleepRequested sleepWaitFinished powerAcknowledged systemHasPoweredOn firstConnectionInvalidation restorationStarted
internalReadStarted internalReadFinished enableStarted enableFinished layoutReadStarted layoutReadFinished
originsStarted originsFinished restorationVerified layoutRestoreRejected recoveryTopologyObserved observerDrainStarted
observerDrainFinished pauseVerificationStarted pauseVerificationFinished enableIdentityReadStarted enableIdentityReadFinished enablePreValidationStarted
enablePreValidationFinished enableBeginStarted enableBeginFinished enableConfigureStarted enableConfigureFinished enablePostValidationStarted
enablePostValidationFinished enableCompleteStarted enableCompleteFinished enableCancelStarted enableCancelFinished restorationFailed
powerAcknowledgementStarted powerAcknowledgementFinished internalIdentityRejected internalCandidateUnavailable witnessSpawnStarted witnessSpawnFinished
witnessRequestStarted witnessRequestFinished witnessReplyStarted witnessReplyFinished witnessExitStarted witnessExitFinished
witnessFailed witnessCleanupStarted witnessCleanupFinished witnessRequestReceived witnessReadStarted witnessReadFinished
internalOnlineReadStarted internalOnlineReadFinished internalActiveReadStarted internalActiveReadFinished internalCandidateReadStarted internalCandidateReadFinished
configurationConfirmationStarted configurationConfirmationFinished configurationConfirmationFailed
disableStarted disableFinished disableFailed wakeTopologyCheckStarted wakeTopologyWaiting wakeTopologyReady
wakeTopologyRejected linkReconfigurationStarted linkReconfigurationCollected linkReconfigurationVerified linkReconfigurationFailed
recoveryEnableNativeStarted recoveryEnableNativeFinished recoveryEnableNativeBoundaryUnavailable
""".split())

RECOVERY_ENABLE_BOUNDARIES = {'recoveryEnableNativeStarted', 'recoveryEnableNativeFinished',
                              'recoveryEnableNativeBoundaryUnavailable'}

NATIVE_FAILURE_CODES = frozenset("""
connection-confirmation-required enable-symbol-unavailable enable-invalid-display enable-begin-failed
enable-configure-failed enable-complete-failed enable-unsafe-topology online-list active-list display-read
identity-conflict recovery-invalid-record recovery-unresolved-source recovery-unfinished-transaction
recovery-invalid-transition guard-spawn guard-identity guard-missing-record guard-protection-lost
guard-access-denied guard-unstable guard-external-topology-pending power-access-denied recovery-store
channel-timeout channel-closed channel-system-call channel-invalid witness-spawn witness-communication
witness-timeout witness-invalid-state witness-unavailable witness-exit witness-cleanup
internal-state-changed internal-information-unavailable external-state-changed unclassified
""".split())


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


def _query_process_info(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                    ctypes.c_void_p, ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    info = ProcessBSDInfo()
    size = ctypes.sizeof(info)
    ctypes.set_errno(0)
    result = library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size)
    if result == 0 and ctypes.get_errno() == errno.ESRCH:
        return None
    D.require(result == size, 'process-info-unavailable')
    return info


def _read_process_info(pid):
    info = _query_process_info(pid)
    D.require(info is not None, 'process-exited-or-changed')
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


def process_has_exited(binding):
    process_key(binding)
    info = _query_process_info(binding['pid'])
    if info is None:
        return True
    D.require(all(getattr(info, key) == binding[key] for key in
                  ('pid', 'uid', 'startSeconds', 'startMicroseconds')), 'process-reused-or-changed')
    if info.status == 5:
        return True  # A zombie has terminated; never reap an owner/helper owned by the App.
    D.require(D.Mac.pid_path(binding['pid']) == binding['executable'], 'role-image-mismatch')
    return False


def application_checkpoint(action, reply, events, requested_at, observed_at, deadline):
    """核验绑定采集器给出的请求后事件与最新App状态；人工确认和退出使用各自凭证。"""
    D.require(action in ('start', 'restore', 'confirm-user'), 'unsupported-application-checkpoint')
    D.require(all(type(value) is int for value in (requested_at, observed_at, deadline))
              and 0 <= requested_at <= observed_at < deadline, 'invalid-completion-window')
    expected = 'applied' if action == 'start' else 'manualConfiguration'
    D.require(isinstance(reply, dict) and reply.get('result') == 'status'
              and reply.get('sessionState') == {expected: {}}
              and reply.get('selectedMode') == reply.get('stateMode') == 'externalOnly'
              and reply.get('requiresExplicitActivation') is False, 'application-not-completed')
    stages = {'start': ('disableStarted', 'disableFinished'),
              'restore': ('restorationStarted', 'restorationVerified', 'pauseVerificationStarted', 'pauseVerificationFinished'),
              'confirm-user': ('configurationConfirmationStarted', 'configurationConfirmationFinished')}[action]
    D.require(isinstance(events, list), 'invalid-completion-events')
    position, previous = 0, requested_at
    for event in events:
        D.require(isinstance(event, dict) and event.get('type') == 'internal-lifecycle'
                  and event.get('role') == 'controller'
                  and event.get('clock') == 'mach_continuous_time/ns', 'invalid-completion-events')
        at, stage = event.get('continuousNs'), event.get('stage')
        D.require(type(at) is int and previous <= at <= observed_at and isinstance(stage, str) and stage in LIFECYCLE_STAGES,
                  'invalid-completion-events')
        previous = at
        D.require(event.get('succeeded') is not False and 'failureCode' not in event
                  and not stage.endswith(('Failed', 'Rejected'))
                  and stage not in ('firstConnectionInvalidation', 'sleepRequested'), 'completion-fault')
        if action == 'start':
            D.require(stage not in ('restorationStarted', 'enableStarted')
                      and (stage != 'enableBeginStarted' or event.get('operation') == 'disable'),
                      'unexpected-restoration')
        if action in ('restore', 'confirm-user'):
            D.require(stage not in ('disableStarted', 'disableFinished'), 'unexpected-disable')
        if action == 'confirm-user':
            D.require(stage not in ('restorationStarted', 'enableStarted', 'enableBeginStarted', 'originsStarted'),
                      'unexpected-confirmation-write')
        if stage == 'configurationConfirmationFinished':
            D.require(event.get('succeeded') is True, 'configuration-not-confirmed')
        if stage in stages:
            D.require(position < len(stages) and stage == stages[position], 'completion-event-order')
            if stage == 'disableFinished':
                D.require(event.get('succeeded') is True and event.get('operation') == 'disable',
                          'disable-not-confirmed')
            position += 1
    D.require(position == len(stages), 'completion-endpoint-missing')
    return True


CONNECTION_ENUMS = {
    'role': {'controller', 'helper', 'recoveryEntry', 'witness', 'observer'},
    'event': {'matched', 'interest', 'terminated', 'watchFailed'},
    'registryScope': {'unknown', 'target', 'other', 'expected-internal', 'identity-conflict'},
    'messageArgument': {'zero', 'one', 'two', 'other'},
    'messageClassification': {'protectionChanged', 'audioLinkStart', 'videoLinkStart', 'audioLinkStarted',
                              'videoLinkStarted', 'audioLinkStop', 'videoLinkStop', 'audioLinkStopped',
                              'videoLinkStopped', 'unknown'},
    'observedLocation': {'external', 'embedded', 'unavailable', 'other'},
    'disposition': {'registered', 'unchanged', 'revoked', 'controlledEmbeddedTermination',
                    'informational', 'pendingReconfiguration'},
    'scope': {'unknown', 'other', 'expected-internal'},
    'invalidationReason': {'cg-remove', 'cg-disabled'},
}
CONNECTION_CANDIDATE_ENUMS = {
    'role': {'unidentified', 'unregistered', 'registeredExternal', 'registeredEmbedded', 'retiredEmbedded'},
    'service': {'DCPAVDeviceProxy', 'DCPAVServiceProxy', 'DCPAVVideoInterfaceProxy'},
}


def anonymous_connection(event):
    kind = event.get('type')
    D.require(kind in ('connection-observation', 'display-connection-observation')
              and event.get('clock') == 'mach_continuous_time/ns', 'invalid-connection-observation')
    fields = {'role', 'observerStartedAtNanoseconds', 'continuousNs'}
    if kind == 'connection-observation':
        fields |= {'event', 'candidateOrdinal', 'registryScope', 'messageType', 'messageArgument',
                   'messageClassification', 'observedLocation', 'initial', 'disposition', 'invalidated'}
    else:
        fields |= {'flags', 'scope', 'invalidationReason'}
    result = {'type': kind, 'clock': 'mach_continuous_time/ns'}
    for key in fields & event.keys():
        value = event[key]
        if key in CONNECTION_ENUMS:
            D.require(type(value) is str and value in CONNECTION_ENUMS[key], 'invalid-connection-observation')
        elif key in ('initial', 'invalidated'):
            D.require(type(value) is bool, 'invalid-connection-observation')
        else:
            limit = 2**32 - 1 if key in ('flags', 'messageType') else 2**64 - 1
            D.require(type(value) is int and 0 <= value <= limit, 'invalid-connection-observation')
        result[key] = value
    required = {'role', 'continuousNs'} | ({'event', 'candidate', 'registryScope', 'disposition', 'invalidated'}
               if kind == 'connection-observation' else {'flags', 'scope'})
    D.require(required <= event.keys(), 'invalid-connection-observation')
    if kind == 'connection-observation':
        candidate = event['candidate']
        D.require(isinstance(candidate, dict) and 'role' in candidate, 'invalid-connection-observation')
        result['candidate'] = {}
        for key in CONNECTION_CANDIDATE_ENUMS.keys() & candidate.keys():
            value = candidate[key]
            D.require(type(value) is str and value in CONNECTION_CANDIDATE_ENUMS[key], 'invalid-connection-observation')
            result['candidate'][key] = value
    return result


def anonymous_recovery_boundary(event):
    D.require(event.get('type') == 'internal-lifecycle' and event.get('clock') == 'mach_continuous_time/ns'
              and type(event.get('role')) is str and event['role'] in CONNECTION_ENUMS['role']
              and type(event.get('stage')) is str and event['stage'] in RECOVERY_ENABLE_BOUNDARIES
              and type(event.get('continuousNs')) is int and 0 <= event['continuousNs'] < 2**64,
              'invalid-recovery-boundary')
    fields = ('type', 'clock', 'role', 'stage', 'continuousNs', 'cgErrorCode')
    if 'cgErrorCode' in event:
        D.require(type(event['cgErrorCode']) is int and -(2**31) <= event['cgErrorCode'] < 2**31,
                  'invalid-recovery-boundary')
    return {key: event[key] for key in fields if key in event}


class LifecyclePipe:
    """消费启动器交付的独占stdout管道；只关闭自己的副本，不向进程发信号。"""
    def __init__(self, fd, connection_path=None):
        D.require(stat.S_ISFIFO(os.fstat(fd).st_mode), 'lifecycle-not-pipe')
        D.require(fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY, 'lifecycle-not-readable')
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.pending = []
        self.error = None
        self.eof = False
        self.connection_file = None
        self.connection_context = None
        self.connection_count = 0
        self.connection_error = False
        self.thread = threading.Thread(target=self.read, daemon=False)
        self.fd = os.dup(fd)
        try:
            if connection_path is not None:
                self.connection_context = D.CLOCK.private_file(connection_path, create=True)
                self.connection_file = self.connection_context.__enter__()
            os.set_blocking(self.fd, False)
            self.thread.start()
        except BaseException:
            if self.connection_file is not None:
                self.connection_context.__exit__(None, None, None)
            os.close(self.fd)
            raise

    def read(self):
        buffer = b''
        reached_eof = False
        try:
            while not self.stop.is_set():
                if not select.select([self.fd], [], [], 0.1)[0]:
                    continue
                try:
                    chunk = os.read(self.fd, 4096)
                except BlockingIOError:
                    continue
                with self.lock:
                    if not chunk:
                        reached_eof = True
                        if buffer and self.error is None:
                            self.error = 'lifecycle-truncated'
                            self.connection_error = self.connection_file is not None
                        return
                    if self.error is not None:
                        continue  # Keep draining so diagnostic output cannot block the owner.
                    buffer += chunk
                    while b'\n' in buffer:
                        line, buffer = buffer.split(b'\n', 1)
                        D.require(len(line) <= 8192, 'lifecycle-line-too-large')
                        if not line.lstrip().startswith(b'{'):
                            D.require(b'internal-lifecycle' not in line
                                      and '内屏生命周期计时不可用'.encode() not in line, 'lifecycle-invalid-line')
                            continue
                        try:
                            event = json.loads(line)
                        except (ValueError, UnicodeError):
                            raise RuntimeError('lifecycle-invalid-line') from None
                        D.require(isinstance(event, dict), 'lifecycle-invalid-line')
                        if event.get('type') in ('connection-observation', 'display-connection-observation'):
                            if self.connection_file is not None:
                                try:
                                    D.require(self.connection_count < 4096, 'connection-observation-overflow')
                                    self.connection_file.write(json.dumps(anonymous_connection(event), separators=(',', ':')) + '\n')
                                    self.connection_file.flush()
                                    self.connection_count += 1
                                except (OSError, ValueError, RuntimeError):
                                    self.connection_error = True
                                    raise
                            continue
                        if (self.connection_file is not None and event.get('type') == 'internal-lifecycle'
                                and type(event.get('stage')) is str and event['stage'] in RECOVERY_ENABLE_BOUNDARIES):
                            try:
                                D.require(self.connection_count < 4096, 'connection-observation-overflow')
                                self.connection_file.write(json.dumps(anonymous_recovery_boundary(event), separators=(',', ':')) + '\n')
                                self.connection_file.flush()
                                self.connection_count += 1
                            except (OSError, ValueError, RuntimeError):
                                self.connection_error = True
                                raise
                        if 'stage' in event or event.get('type') == 'internal-lifecycle':
                            D.require(event.get('type') == 'internal-lifecycle', 'lifecycle-invalid-line')
                            D.require(len(self.pending) < 4096, 'lifecycle-overflow')
                            self.pending.append(event)
                    D.require(len(buffer) <= 8192, 'lifecycle-line-too-large')
        except (OSError, ValueError, RuntimeError):
            with self.lock:
                self.error = 'lifecycle-reader-failed'
                if self.connection_file is not None:
                    self.connection_error = True
            # No further writes are allowed once this is observed; keep the pipe drained until handoff.
            while not self.stop.is_set():
                try:
                    if select.select([self.fd], [], [], 0.1)[0] and not os.read(self.fd, 4096):
                        reached_eof = True
                        return
                except BlockingIOError:
                    continue
                except OSError:
                    return
        finally:
            if self.connection_file is not None:
                if not reached_eof:
                    self.connection_error = True
                try:
                    self.connection_file.flush()
                    os.fsync(self.connection_file.fileno())
                except (OSError, ValueError):
                    with self.lock:
                        self.connection_error = True
                        self.error = 'lifecycle-reader-failed'
                finally:
                    try:
                        self.connection_context.__exit__(None, None, None)
                    except (OSError, ValueError):
                        with self.lock:
                            self.connection_error = True
                            self.error = 'lifecycle-reader-failed'
                if self.connection_error:
                    print('connection-evidence-incomplete', file=sys.stderr, flush=True)
            with self.lock:
                self.eof = reached_eof

    def take(self):
        with self.lock:
            events, self.pending = self.pending, []
            return events, self.eof, self.error

    def close(self):
        if self.fd is None:
            return
        self.stop.set()
        self.thread.join(timeout=1)
        D.require(not self.thread.is_alive(), 'lifecycle-close-timeout')
        os.close(self.fd)
        self.fd = None


class RecoveryBatchGate:
    def __init__(self, budget_directory, candidate, field_digest, binaries, now, read_process=None, normal_wake_readiness=False):
        D.require(type(normal_wake_readiness) is bool, 'invalid-normal-wake-readiness')
        self.normal_wake_readiness = normal_wake_readiness
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
        self.native_budget_directory = None
        self.application_process = None
        self.configuration_visual_at = None
        self.configuration_dialog_started = False
        self.roles = {}
        self.stream = None
        self.native_events = []
        self.request_event_start = 0
        self.native_disable_count = 0
        self.native_disable_pending = False
        self.next_action = self.confirmed_requests = 0
        self.sleep_request_at = self.wake = self.requested_at = None
        self.power_event = None
        self.verifying = False
        self.dispatched_controls = set()
        self.stopped = self.inflight = self.closed = False

    def launch_application(self, state_directory, boot_session, spawn=subprocess.Popen):
        """仅供获准的现场启动器调用；创建后一直保留管道与进程句柄供恢复交接。"""
        try:
            self.tick()
            D.require(self.application_process is None and self.stream is None and not self.roles,
                      'application-already-launched')
            D.require(Path(state_directory).is_absolute(), 'absolute-state-directory-required')
            state = D.private_directory(state_directory)
            D.require(not any(state.iterdir()), 'batch-state-not-empty')
            environment = os.environ.copy()
            environment.update(self.prepare_native_budget(boot_session))
            self.journal.append(dict(event='consume-before-application-launch'))
            self.tick()
            process = spawn([self.binaries['app']['executable'], '--recovery-batch', '--state-directory', str(state)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            env=environment, start_new_session=True)
            self.application_process = process
            self.stream = LifecyclePipe(process.stdout.fileno(), self.journal.path.with_suffix('.connections.jsonl'))
            self.bind('app', self.read_process(process.pid))
            return process
        except BaseException:
            self._latch_stop()
            raise

    def confirm_configuration_visual(self, spawn=subprocess.Popen, wait=lambda: time.sleep(.05)):
        process = None
        try:
            self.tick()
            D.require(self.next_action == self.confirmed_requests == 2 and not self.inflight
                      and not self.configuration_dialog_started, 'visual-confirmation-order')
            self.check_roles(ROLES)
            self.configuration_dialog_started = True
            self.journal.append(dict(event='consume-before-configuration-dialog'))
            remaining = max(1, min(180, (self.deadline - self.last_time) // D.NS))
            process = spawn(['/usr/bin/osascript', '-e', D.CONFIRM_DIALOG, 'before', str(remaining)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            while process.poll() is None:
                self.tick()
                wait()
            output, _ = process.communicate(timeout=.5)
            self.tick()
            self.check_roles(ROLES)
            D.require(process.returncode == 0 and isinstance(output, bytes) and len(output) <= 32,
                      'human-dialog-failed')
            answer = output.decode().strip()
            D.require(answer in ('normal', 'abnormal', 'rescue', 'cancel'), 'invalid-human-input')
            self.journal.append(dict(event='configuration-visual', answer=answer))
            D.require(answer == 'normal', 'configuration-not-visually-confirmed')
            self.tick()
            self.configuration_visual_at = self.last_time
            return True
        except BaseException:
            self._latch_stop()
            raise
        finally:
            if process is not None:
                try:
                    if process.poll() is None:
                        process.terminate()  # Only this task-owned dialog, never a display controller.
                        process.wait(timeout=1)
                except (OSError, subprocess.SubprocessError):
                    self._latch_stop()
                    raise RuntimeError('dialog-cleanup-unconfirmed') from None
                finally:
                    if process.stdout is not None:
                        process.stdout.close()

    def wait_for_standby(self, wait=lambda: time.sleep(.05), run=subprocess.run):
        try:
            D.require(self.application_process is not None and self.next_action == 0, 'standby-order')
            path = self.native_budget_directory / 'app-process.json'
            while not path.exists():
                self.tick()
                wait()
            self.bind_registered_process('app')
            while True:
                reply = self.control_application('status', run)
                D.require(reply.get('sessionState') == {'waiting': {}}
                          and reply.get('selectedMode') == 'externalOnly'
                          and reply.get('requiresExplicitActivation') is True, 'application-not-in-standby')
                if reply.get('stateMode') == 'externalOnly':
                    return reply
                self.tick()
                wait()
        except BaseException:
            self._latch_stop()
            raise

    def bind_registered_process(self, role):
        try:
            self.tick()
            D.require(self.native_budget_directory is not None and role in ROLES, 'native-registration-missing')
            value = D.CLOCK.load_private(self.native_budget_directory / (role + '-process.json'))
            D.require(isinstance(value, dict) and set(value) == {'pid', 'startSeconds', 'startMicroseconds'},
                      'invalid-process-registration')
            D.require(all(type(value[key]) is int for key in value), 'invalid-process-registration')
            observed = self.read_process(value['pid'])
            D.require(all(observed[key] == value[key] for key in value), 'stale-process-registration')
            if role in self.roles:
                D.require(process_key(observed) == process_key(self.roles[role]), 'process-reused-or-changed')
            else:
                self.bind(role, observed)
            self.tick()
            return observed
        except BaseException:
            self._latch_stop()
            raise

    def _latch_stop(self):
        self.stopped = True
        if self.native_budget_directory is None:
            return
        path = self.native_budget_directory / 'stopped'
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            return
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        fd = os.open(self.native_budget_directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def prepare_native_budget(self, boot_session):
        """返回候选App专用环境；启动器必须传递，不能更新日常App环境。"""
        try:
            self.tick()
            D.require(not self.roles and self.next_action == 0 and self.native_budget_directory is None,
                      'native-budget-order')
            boot_session = str(uuid.UUID(boot_session))
            path = self.journal.path.with_suffix('.native')
            path.mkdir(mode=0o700)
            self.native_budget_directory = path
            with D.CLOCK.private_file(path / 'policy.json', create=True) as output:
                policy = dict(bootSession=boot_session, started=self.started, deadline=self.deadline)
                if self.normal_wake_readiness:
                    policy['normalWakeReadiness'] = True
                json.dump(policy, output)
                output.flush()
                os.fsync(output.fileno())
            for directory in (path, path.parent):
                fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
            self.journal.append(dict(event='native-budget-prepared'))
            self.tick()
            return {'EXTILUME_RECOVERY_BATCH_DIRECTORY': str(path)}
        except BaseException:
            self._latch_stop()
            raise

    def tick(self):
        try:
            D.require(not self.closed and not self.stopped, 'batch-stopped')
            events, eof, error = self.stream.take() if self.stream else ([], False, None)
            current = self.now()
            D.require(type(current) is int and self.last_time <= current < self.deadline, 'batch-deadline')
            self.last_time = current
            for event in events:
                self._record_lifecycle(event)
            D.require(error is None, 'lifecycle-reader-failed')
            D.require(not eof or self.next_action == len(ACTIONS), 'lifecycle-unexpected-eof')
        except BaseException:
            self._latch_stop()
            raise

    def attach_stream(self, fd):
        try:
            self.tick()
            D.require(self.stream is None and self.next_action == 0 and 'app' in self.roles,
                      'lifecycle-attachment-order')
            self.stream = LifecyclePipe(fd, self.journal.path.with_suffix('.connections.jsonl'))
        except BaseException:
            self._latch_stop()
            raise

    def _record_lifecycle(self, event):
        D.require(isinstance(event, dict) and event.get('type') == 'internal-lifecycle'
                  and event.get('clock') == 'mach_continuous_time/ns'
                  and event.get('role') in ('controller', 'helper', 'witness', 'observer', 'recoveryEntry'),
                  'invalid-lifecycle-event')
        at, stage = event.get('continuousNs'), event.get('stage')
        D.require(type(at) is int and self.started <= at <= self.last_time and isinstance(stage, str) and stage in LIFECYCLE_STAGES,
                  'invalid-lifecycle-event')
        D.require(len(self.native_events) < 4096, 'lifecycle-overflow')
        observed = dict(event='native-observed', role=event['role'], stage=stage, continuousNs=at)
        if 'failureCode' in event:
            code = event['failureCode']
            observed['failureCode'] = code if type(code) is str and code in NATIVE_FAILURE_CODES else 'unclassified'
        if 'recoveryTopology' in event:
            counts = event['recoveryTopology']
            D.require(isinstance(counts, dict) and set(counts) == {
                'onlineDisplayCount', 'activeDisplayCount', 'activeBuiltInCount', 'activePhysicalCount', 'activeOtherCount'}
                and all(type(value) is int and value >= 0 for value in counts.values())
                and counts['activeDisplayCount'] == sum(counts[key] for key in (
                    'activeBuiltInCount', 'activePhysicalCount', 'activeOtherCount')), 'invalid-topology-counts')
            observed['recoveryTopology'] = dict(counts)
        self.native_events.append(event)
        self.journal.append(observed)
        D.require(event.get('succeeded') is not False and 'failureCode' not in event
                  and not stage.endswith(('Failed', 'Rejected')) and stage != 'firstConnectionInvalidation',
                  'native-fault')
        if stage == 'systemHasPoweredOn' and event['role'] == 'controller':
            D.require(self.next_action == 4 and self.sleep_request_at is not None
                      and at >= self.sleep_request_at, 'unexpected-native-wake')
            if self.wake is None:
                self.wake = at
                if not self.normal_wake_readiness:
                    self.deadline = min(self.deadline, at + 10 * D.NS)
                self.journal.append(dict(event='wake-boundary', continuousNs=at))
            else:
                D.require(at >= self.wake, 'invalid-wake-boundary')
            D.require(self.last_time < self.deadline, 'batch-deadline')
        if stage == 'disableStarted':
            was_pending = self.native_disable_pending
            self.native_disable_pending = True
            self.native_disable_count += 1
            self.journal.append(dict(event='native-disable-observed', count=self.native_disable_count))
            first = (self.native_disable_count == 1 and self.next_action == 1
                     and self.requested_at is not None and at >= self.requested_at)
            reapply = self.native_disable_count == 2 and self.next_action == 4 and self.wake is not None and at >= self.wake
            D.require(event['role'] == 'controller' and event.get('operation') == 'disable'
                      and not was_pending and (first or reapply), 'native-disable-outside-budget')
            self.native_disable_pending = True
        elif stage == 'disableFinished':
            D.require(event['role'] == 'controller' and event.get('operation') == 'disable'
                      and event.get('succeeded') is True and self.native_disable_pending, 'native-disable-unpaired')
            self.native_disable_pending = False

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
            self._latch_stop()
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
            self.request_event_start = len(self.native_events)
            if self.native_budget_directory is not None and action in ('start', 'sleep'):
                name = 'initial-authorized.json' if action == 'start' else 'wake-authorized.json'
                with D.CLOCK.private_file(self.native_budget_directory / name, create=True) as output:
                    json.dump(self.requested_at, output)
                    output.flush()
                    os.fsync(output.fileno())
                fd = os.open(self.native_budget_directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
                self.tick()
            result = send()
            self.tick()
            D.require(result is True, 'action-not-accepted')
            self.journal.append(dict(event='action-accepted', action=action))
            self.tick()
            self.verifying = True
            D.require(verify() is True, 'action-not-confirmed')
            self.tick()
            if self.stream is not None and action in ('start', 'restore', 'confirm-user', 'sleep'):
                expected_count = 2 if action == 'sleep' else 1
                D.require(self.native_disable_count == expected_count and not self.native_disable_pending,
                          'native-disable-incomplete')
            if action != 'stop':
                self.check_roles(ROLES)
            self.tick()
            self.journal.append(dict(event='action-confirmed', action=action))
            self.tick()
            self.confirmed_requests += 1
        except BaseException:
            self._latch_stop()
            raise
        finally:
            self.inflight = self.verifying = False

    def control_application(self, action, run=subprocess.run):
        try:
            self.tick()
            reading = action == 'status'
            commands = {'start': 'apply-externalOnly', 'restore': 'restore-for-configuration',
                        'confirm-user': 'confirm-configuration', 'stop': 'quit'}
            D.require((reading and (self.verifying or (self.next_action == 0 and 'app' in self.roles)))
                      or (self.inflight and self.next_action > 0 and not self.verifying
                          and action in commands and action == ACTIONS[self.next_action - 1]),
                      'control-outside-request')
            if action == 'confirm-user':
                D.require(self.configuration_visual_at is not None, 'configuration-needs-human-confirmation')
            self.check_roles(('app',))
            app = self.roles['app']
            target = f"{app['pid']}:{app['startSeconds']}:{app['startMicroseconds']}"
            args = [app['executable'], '--control', 'status' if reading else commands[action]]
            if not reading:
                args.append('--allow-display-write')
            args += ['--target-process', target]
            if not reading:
                D.require(action not in self.dispatched_controls, 'control-already-dispatched')
                self.journal.append(dict(event='control-dispatch', action=action))
                self.dispatched_controls.add(action)
            self.tick()
            response = run(args, capture_output=True, timeout=min(10, (self.deadline - self.last_time) / D.NS))
            self.tick()
            if action != 'stop':
                self.check_roles(('app',))
            self.tick()
            D.require(response.returncode == 0 and isinstance(response.stdout, bytes)
                      and len(response.stdout) <= 65536, 'application-control-unconfirmed')
            reply = json.loads(response.stdout)
            D.require(isinstance(reply, dict) and reply.get('result') == ('status' if reading else 'accepted'),
                      'application-control-unconfirmed')
            return reply
        except (OSError, subprocess.SubprocessError, ValueError, TypeError):
            self._latch_stop()
            raise RuntimeError('application-control-unconfirmed') from None
        except BaseException:
            self._latch_stop()
            raise

    def verify_application(self, action, reply, events=None):
        try:
            self.tick()
            D.require(self.inflight and self.verifying and action == ACTIONS[self.next_action - 1],
                      'no-matching-pending-action')
            if self.stream is not None:
                D.require(events is None, 'lifecycle-input-override')
                events = [event for event in self.native_events[self.request_event_start:] if event['role'] == 'controller'
                          and event['continuousNs'] >= self.requested_at]
            return application_checkpoint(action, reply, events, self.requested_at, self.last_time, self.deadline)
        except BaseException:
            self._latch_stop()
            raise

    def observe_wake(self, at):
        try:
            self.tick()
            D.require(self.sleep_request_at is not None and self.wake is None
                      and type(at) is int and self.sleep_request_at <= at <= self.last_time,
                      'invalid-wake-boundary')
            self.wake = at
            if not self.normal_wake_readiness:
                self.deadline = min(self.deadline, at + 10 * D.NS)
            self.journal.append(dict(event='wake-boundary', continuousNs=at))
            self.tick()
        except BaseException:
            self._latch_stop()
            raise

    def observe_power(self, event, boot_session):
        try:
            self.tick()
            D.require(self.next_action == 4 and self.power_event is None and self.sleep_request_at is not None,
                      'unexpected-power-event')
            sleep = D.CLOCK.uint(event['willSleepAtNanoseconds'])
            wake = D.CLOCK.uint(event['didWakeAtNanoseconds'])
            D.require(str(uuid.UUID(event['bootSession'])) == str(uuid.UUID(boot_session))
                      and self.sleep_request_at <= sleep < wake <= self.last_time, 'invalid-power-event')
            self.power_event = event
            if not self.normal_wake_readiness:
                self.deadline = min(self.deadline, wake + 10 * D.NS)
            self.journal.append(dict(event='power-pair-observed', sleepAt=sleep, wakeAt=wake))
            self.tick()
        except BaseException:
            self._latch_stop()
            raise

    def verify_sleep(self, before, after, evidence, reply, probe_sha256):
        try:
            self.tick()
            D.require(self.inflight and self.verifying and self.next_action == 4 and self.power_event is not None
                      and self.wake is not None, 'sleep-checkpoint-order')
            assessment = D.CLOCK.compare(before, after, evidence)
            self.journal.append(dict(event='sleep-measurement', assessment=assessment))
            D.require(evidence['intervals'][0]['powerEvent'] == self.power_event, 'wake-marker-mismatch')
            D.require(before['probeSHA256'] == probe_sha256
                      and self.started <= D.CLOCK.native_bounds(before['before'])[0]
                      and D.CLOCK.native_bounds(before['after'])[1] <= self.sleep_request_at
                      and D.CLOCK.native_bounds(after['after'])[1] <= self.last_time, 'sleep-capture-outside-batch')
            D.require(assessment['measurementSupported'] is True, 'real-sleep-unproved')
            D.require(reply.get('result') == 'status' and reply.get('sessionState') == {'applied': {}}
                      and reply.get('selectedMode') == reply.get('stateMode') == 'externalOnly'
                      and reply.get('requiresExplicitActivation') is False, 'wake-reapplication-unconfirmed')
            readiness = ('wakeTopologyReady', 'pauseVerificationFinished') if self.normal_wake_readiness else (
                'restorationStarted', 'restorationVerified')
            required = iter(('sleepRequested', 'systemHasPoweredOn', *readiness, 'disableStarted', 'disableFinished'))
            stage = next(required)
            for event in self.native_events[self.request_event_start:]:
                if event['role'] == 'controller' and event['stage'] == stage:
                    stage = next(required, None)
                    if stage is None:
                        break
            D.require(stage is None and self.native_disable_count == 2 and not self.native_disable_pending,
                      'wake-reapplication-endpoint-missing')
            self.tick()
            return True
        except BaseException:
            self._latch_stop()
            raise

    def verify_exit(self, expected_snapshot, expected_hardware, snapshots, internal_reply,
                    has_exited=process_has_exited):
        try:
            self.tick()
            D.require(self.inflight and self.verifying and self.next_action == len(ACTIONS)
                      and isinstance(self.stream, LifecyclePipe) and self.stream.eof
                      and self.native_budget_directory is not None, 'exit-checkpoint-order')
            D.require(self.application_process is not None and self.application_process.poll() == 0,
                      'application-exit-not-normal')
            D.require(set(self.roles) == set(ROLES) and all(has_exited(self.roles[role]) for role in ROLES),
                      'controller-still-running')
            receipt = D.CLOCK.load_private(self.native_budget_directory / 'restoration.json')
            app = {key: self.roles['app'][key] for key in ('pid', 'startSeconds', 'startMicroseconds')}
            D.require(receipt.get('version') == 1 and receipt.get('app') == app
                      and type(receipt.get('verifiedAtNanoseconds')) is int
                      and self.requested_at <= receipt['verifiedAtNanoseconds'] <= self.last_time,
                      'unbound-restoration-receipt')
            expectation, record = receipt['expectation'], receipt['record']
            D.restored(record)
            D.require(record.get('independentGuardVerified') is True
                      and record.get('externalDisplay') is None
                      and record['session'] == expectation['session']
                      and type(record['generation']) is int and record['generation'] > 0
                      and record['generation'] == expectation['generation'], 'unverified-restoration-receipt')
            expected = D.signature(expected_snapshot)
            layout = {'main': expected['builtIn']['identity'], 'origins': []}
            for role in ('builtIn', 'physical'):
                display = expected[role]
                layout['origins'].extend((display['identity'], dict(x=display['x'], y=display['y'])))
            D.require(D.WIRE.layout_key(record['baseline']) == D.WIRE.layout_key(expectation['baseline'])
                      == D.WIRE.layout_key(layout)
                      and str(uuid.UUID(expectation['internalIdentity'])) == expected['builtIn']['identity']
                      and expectation.get('hardware') == expected_hardware, 'restoration-C-mismatch')
            responsibility = record.get('internalDisplay', {})
            D.require(responsibility.get('baseline') is True and responsibility.get('pending') is False
                      and responsibility.get('hardwareIdentity') == expected_hardware
                      and responsibility.get('identity') == expectation['internalIdentity'], 'internal-restoration-unverified')
            D.require(len(snapshots) == 2 and all(D.signature(snapshot) == expected for snapshot in snapshots),
                      'C-or-mode-mismatch')
            inner = next(d for d in snapshots[-1]['displays'] if D.WIRE.identity_case(d['identity']) == 'builtIn')
            state = internal_reply.get('state', {}).get('_0', {})
            D.require(state.get('isBuiltIn') is True and state.get('isOnline') is True and state.get('isActive') is True
                      and state.get('hardwareIdentity') == expected_hardware and state.get('id') == inner['id']
                      and str(uuid.UUID(state['identityUUID'])) == expected['builtIn']['identity']
                      and str(uuid.UUID(state['reportedIdentityUUID'])) == expected['builtIn']['identity'],
                      'internal-identity-unverified')
            D.require(all(has_exited(self.roles[role]) for role in ROLES), 'controller-still-running')
            self.journal.append(dict(event='independent-exit-verified'))
            self.tick()
            return True
        except BaseException:
            self._latch_stop()
            raise

    def close(self):
        if self.closed:
            if isinstance(self.stream, LifecyclePipe) and self.stream.eof:
                self.stream.close()
                if self.application_process is not None:
                    self.application_process.stdout.close()
                D.require(not self.stream.connection_error, 'connection-evidence-incomplete')
            return
        self.closed = True
        try:
            self._latch_stop()
            self.journal.append(dict(event='gate-closed', consumed=self.next_action, confirmed=self.confirmed_requests,
                                     nativeDisableObserved=self.native_disable_count, nativeDisablePending=self.native_disable_pending,
                                     unconfirmedAction=ACTIONS[self.next_action - 1] if self.next_action > self.confirmed_requests else None,
                                     controllerCleanup='requires-bound-safety-handoff',
                                     readerCleanup='retained-until-eof' if isinstance(self.stream, LifecyclePipe) and not self.stream.eof else 'close-requested'))
        finally:
            try:
                # An active writer must keep a consumer while recovery is handed off.
                if self.stream is not None and (not isinstance(self.stream, LifecyclePipe) or self.stream.eof):
                    self.stream.close()
                    if self.application_process is not None:
                        self.application_process.stdout.close()
                    if isinstance(self.stream, LifecyclePipe):
                        D.require(not self.stream.connection_error, 'connection-evidence-incomplete')
            finally:
                self.journal.close()
