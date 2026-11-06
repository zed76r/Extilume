"""离线检查单轮主控就绪标记；只判断分支覆盖，不授予硬件或计时验收。"""
import argparse
import json
from pathlib import Path

PREFIX = 'wakeTopology'
STAGES = {'wakeTopologyCheckStarted', 'wakeTopologyWaiting', 'wakeTopologyReady', 'wakeTopologyRejected'}
WRITES = {'enableStarted', 'originsStarted', 'disableStarted', 'enableBeginStarted'}
STOPS = {'sleepRequested', 'restorationFailed', 'firstConnectionInvalidation'}


def require(value):
    if not value:
        raise ValueError('invalid-wake-topology-evidence')


def assess(document):
    wake = document['wakeNanoseconds']
    require(type(wake) is int and 0 <= wake < (1 << 64) - 10_000_000_000)
    events = document['events']
    require(isinstance(events, list))
    checking = waiting = ready = rejected = False
    checks = waits = 0
    previous = wake
    for event in events:
        require(isinstance(event, dict) and isinstance(event.get('stage'), str))
        stage = event['stage']
        relevant = stage.startswith(PREFIX)
        if not relevant and (ready or rejected or stage not in WRITES | STOPS):
            continue
        at = event.get('continuousNs')
        require(type(at) is int and wake <= at < wake + 10_000_000_000 and at >= previous)
        require(event.get('type') == 'internal-lifecycle' and event.get('clock') == 'mach_continuous_time/ns')
        previous = at
        if not relevant:
            require(not waiting and not checking)
            continue
        require(stage in STAGES and event.get('role') == 'controller' and not ready and not rejected)
        if stage in ('wakeTopologyWaiting', 'wakeTopologyReady'):
            external = int(stage == 'wakeTopologyReady')
            expected = dict(onlineDisplayCount=1 + external, activeDisplayCount=1 + external,
                            activeBuiltInCount=1, activePhysicalCount=external, activeOtherCount=0)
            counts = event.get('recoveryTopology')
            require(isinstance(counts, dict) and counts == expected
                    and all(type(value) is int for value in counts.values()))
        if stage == 'wakeTopologyCheckStarted':
            require(not checking and 'succeeded' not in event)
            checking = True
            checks += 1
        elif stage == 'wakeTopologyWaiting':
            require(checking and 'succeeded' not in event)
            checking, waiting = False, True
            waits += 1
        elif stage == 'wakeTopologyReady':
            require(checking and event.get('succeeded') is True)
            checking, waiting, ready = False, False, True
        else:
            require(checking and event.get('succeeded') is False and isinstance(event.get('failureCode'), str))
            checking, rejected = False, True
    coverage = 'rejected' if rejected else 'covered' if ready and waits > 0 else 'not-observed' if ready else 'incomplete'
    return dict(branchCoverage=coverage, checks=checks, waits=waits,
                hardwareAcceptance=False, recoveryAcceptance=False,
                candidateAndProcessBindingVerified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path, help='含wakeNanoseconds和同轮events数组的JSON')
    args = parser.parse_args()
    try:
        print(json.dumps(assess(json.loads(args.evidence.read_text())), ensure_ascii=False))
    except (ValueError, KeyError, TypeError, OSError):
        parser.exit(1, '就绪标记不完整或不一致；不能判定分支覆盖。\n')


if __name__ == '__main__':
    main()
