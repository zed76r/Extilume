#!/usr/bin/env python3
"""Opt-in, bounded Release UI matrix using an isolated test-owned status menu."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
TRACE_PATH = None
TRACE_SCENARIO = None
PRIMARY = "外屏主屏"
ONLY = "仅外屏（停用内屏）"
MARKER = "开发版 · 仅外屏尚未准入日用"
SETTINGS = "打开显示设置"
QUIT = "退出并恢复"
RESTORE = "恢复双屏以调整排列"
CONFIRM = "设为恢复布局"
SETTINGS_CALL = "openSettings:x-apple.systempreferences:com.apple.Displays-Settings.extension"
STATES = {
    # Expected public UI contract: title, mode selectable, quit enabled, retry, recovery, confirmation.
    "waiting": ("等待外屏连接", True, True, None, False, False),
    "unsupported": ("暂不支持：测试受控条件不符：外接显示器身份尚未确认，模式不会应用", True, True, None, False, False),
    "applying": ("正在应用外屏主屏…", False, True, None, False, False),
    "applied": ("外屏主屏已生效", True, True, None, False, False),
    "manualConfiguration": ("排列已确认，可切换主屏", True, True, "设为外屏主屏", False, False),
    "manualConfigurationForQuit": ("排列已确认，可以退出", False, True, None, False, False),
    "applicationFailedRestored": ("应用失败，已恢复", True, True, "重试", False, False),
    "recoveryIncomplete": ("恢复未完成", False, False, None, True, False),
    "unconfirmed": ("请确认退出时恢复的排列", False, False, None, True, True),
    "confirmationFailed": ("排列确认失败", False, False, None, True, True),
    "restoringAndQuitting": ("正在恢复并退出…", False, False, None, False, False),
    "quitFailed": ("恢复失败，尚未退出", False, False, None, True, True),
    "quitWaitingForDisplays": ("显示器未齐，等待恢复退出", False, False, None, True, False),
}


def trace(event, **values):
    if TRACE_PATH is not None:
        with TRACE_PATH.open("a") as output:
            output.write(json.dumps(dict(event=event, scenario=TRACE_SCENARIO, uptime=time.monotonic(), **values), ensure_ascii=False) + "\n")


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    path.chmod(0o600)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expected_menu(mode, state, variant=None):
    title, selectable, can_quit, retry, recover, confirm = STATES[state]
    applied = state == "applied"
    restore = mode == "externalOnly" and applied
    settings = True
    if mode == "externalOnly":
        title = {"applying": "正在停用内屏…", "applied": "仅外屏已生效",
                 "manualConfiguration": "双屏已恢复，可调整或确认排列"}.get(state, title)
        if state == "manualConfiguration":
            retry, confirm = "应用仅外屏", True
        if state == "quitFailed":
            confirm = False
    if variant in ("unselected", "explicit", "mismatch"):
        title = {"unselected": "请选择显示模式", "explicit": "已选择仅外屏，等待点击模式应用",
                 "mismatch": "已选择模式，尚未应用"}[variant]
        applied, restore = False, False
    if variant in ("restore-busy", "confirm-busy", "quit-busy"):
        title = {"restore-busy": "正在恢复…", "confirm-busy": "正在确认排列…",
                 "quit-busy": "正在恢复并退出…"}[variant]
        selectable, can_quit, applied, restore, retry, recover, confirm = False, False, False, False, None, False, False
        settings = variant != "confirm-busy"
    rows = [(PRIMARY, selectable, applied and mode == "externalPrimary"),
            (ONLY, selectable, applied and mode == "externalOnly"), (MARKER, False, False), (title, False, False)]
    if retry:
        rows.append((retry, True, False))
    if recover:
        rows.append(("重试恢复", True, False))
    if restore:
        rows.append((RESTORE, True, False))
    if confirm:
        rows.append((CONFIRM, True, False))
    rows += [(SETTINGS, settings, False), (QUIT, can_quit, False)]
    return [dict(title=t, enabled=e, mark="✓" if checked else "missing value") for t, e, checked in rows]


def scenarios(matrix):
    result = []

    def add(name, mode, state, *, action=None, method="AXPress", calls=(), reuse=False, variant=None,
            explicit=False, mismatch=None, complete=None, after=None, navigate=False):
        rows = expected_menu(mismatch or mode, state or "applying", variant)
        disabled = [r["title"] for r in rows if not r["enabled"] and r["title"] in (PRIMARY, ONLY, QUIT, SETTINGS)]
        result.append(dict(name=name, mode=mode, state=state, reuse=reuse, explicitActivation=explicit,
                           mismatchedMode=mismatch, expectedCalls=list(calls), completeQuit=complete,
                           expectedAfterCompletion=after, expectedMenu=rows, action=action, method=method,
                           disabledAttempts=disabled, keyboardCancel=navigate))

    if not matrix:
        add("unselected", None, "waiting", variant="unselected", navigate=True)
        add("applied-only", "externalOnly", "applied", action=RESTORE, calls=["restoreForConfiguration"])
        add("restore-busy", "externalOnly", None, reuse=True, variant="restore-busy", calls=["restoreForConfiguration"])
        result[-1]["disabledAttempts"] = [ONLY]
        return result
    for mode, prefix in [("externalPrimary", "primary"), ("externalOnly", "only")]:
        for state in STATES:
            action, method, calls = None, "AXPress", []
            if state == "waiting" and mode == "externalPrimary":
                action, calls = SETTINGS, [SETTINGS_CALL]
            elif state == "applied":
                if mode == "externalOnly":
                    action, calls = RESTORE, ["restoreForConfiguration"]
                else:
                    action, method, calls = QUIT, "keyboard", ["requestTermination", "quitApplication"]
            elif state == "manualConfiguration":
                action, calls = ("应用仅外屏" if mode == "externalOnly" else "设为外屏主屏"), ["retryApplication"]
            elif state == "applicationFailedRestored":
                action, calls = "重试", ["retryApplication"]
            elif state == "recoveryIncomplete":
                action, calls = "重试恢复", ["recoverApplication"]
            elif state == "unconfirmed":
                action, calls = CONFIRM, ["confirmCurrentConfiguration"]
            elif state == "quitFailed" and mode == "externalPrimary":
                action, calls = "重试恢复", ["requestTermination", "quitApplication"]
            add(prefix + "-" + state, mode, state, action=action, method=method, calls=calls)
            if state == "applied" and mode == "externalPrimary":
                add(prefix + "-quit-busy", mode, None, reuse=True, variant="quit-busy", calls=calls,
                    complete=True, after=calls + ["replyTermination:true"])
            elif state == "applied" and mode == "externalOnly":
                add(prefix + "-restore-busy", mode, None, reuse=True, variant="restore-busy", calls=calls)
                add(prefix + "-restore-complete", mode, "manualConfiguration", reuse=True, calls=calls)
            elif state == "recoveryIncomplete":
                add(prefix + "-recover-busy", mode, None, reuse=True, variant="restore-busy", calls=calls)
                add(prefix + "-recover-complete", mode, "applicationFailedRestored", reuse=True, calls=calls)
            elif state == "unconfirmed":
                add(prefix + "-confirm-busy", mode, None, reuse=True, variant="confirm-busy", calls=calls)
                add(prefix + "-confirm-complete", mode, "manualConfiguration", reuse=True, calls=calls)
            elif state == "quitFailed" and mode == "externalPrimary":
                add(prefix + "-retry-quit-busy", mode, None, reuse=True, variant="quit-busy", calls=calls,
                    complete=False, after=calls + ["replyTermination:false"])
    add("unselected-keyboard-only", None, "waiting", variant="unselected", action=ONLY, method="keyboard", calls=["selectMode:externalOnly"])
    add("unselected-ax-primary", None, "waiting", variant="unselected", action=PRIMARY, calls=["selectMode:externalPrimary"])
    add("saved-only-explicit", "externalOnly", "waiting", variant="explicit", explicit=True, navigate=True)
    add("selected-mode-mismatch", "externalPrimary", "applied", variant="mismatch", mismatch="externalOnly")
    add("only-quit-action", "externalOnly", "applied", action=QUIT, calls=["requestTermination", "quitApplication"])
    add("only-quit-busy", "externalOnly", None, reuse=True, variant="quit-busy", calls=["requestTermination", "quitApplication"],
        complete=True, after=["requestTermination", "quitApplication", "replyTermination:true"])
    representatives = {"primary-confirm-busy": SETTINGS, "only-restore-busy": ONLY,
                       "only-recover-busy": PRIMARY, "only-quit-busy": QUIT}
    for case in result:
        case["disabledAttempts"] = [representatives[case["name"]]] if case["name"] in representatives else []
        assert not case["disabledAttempts"] or (not case["action"] and not case["keyboardCancel"])
    return result


def freeze_plan(matrix):
    cases = scenarios(matrix)
    assert len(cases) <= 50 and len({c["name"] for c in cases}) == len(cases)
    return {"kind": "matrix" if matrix else "pilot", "scenarios": cases,
            "bounds": {"scenarios": len(cases), "statusMenuOpens": len(cases), "screenshots": len(cases),
                       "enabledCommands": sum(c["action"] is not None for c in cases),
                       "disabledAXAttempts": sum(len(c["disabledAttempts"]) for c in cases),
                       "keyboardNavigationPerAction": 12, "perScenarioSeconds": 20, "totalSeconds": 600},
            "failurePolicy": "Stop first failed scene; remaining not run; close only this host; no command retries",
            "disabledEquivalence": [
                {"scene": "primary-applying", "inherited": True, "targets": [PRIMARY, ONLY], "renderer": "canSelectMode / render modeItems", "handler": "selectMode guard canSelectMode"},
                {"scene": "primary-quit-busy", "inherited": True, "targets": [PRIMARY, ONLY, QUIT], "renderer": "terminationPending / busy", "handler": "selectMode / quitApplication guards"},
                {"scene": "primary-recoveryIncomplete", "inherited": True, "targets": [PRIMARY, ONLY, QUIT], "renderer": "needsRecovery / canQuit", "handler": "selectMode / quitApplication guards"},
                {"scene": "primary-confirm-busy", "targets": [SETTINGS], "renderer": "settingsItem !confirmationInProgress", "handler": "openDisplaySettings guard !confirmationInProgress"},
                {"scene": "only-restore-busy", "targets": [ONLY], "renderer": "recoveryInProgress / busy", "handler": "selectMode shared guard; externalOnly context"},
                {"scene": "only-recover-busy", "targets": [PRIMARY], "renderer": "recoveryInProgress / busy", "handler": "selectMode shared guard; cross-mode payload"},
                {"scene": "only-quit-busy", "targets": [QUIT], "renderer": "terminationPending / canQuit", "handler": "quitApplication guard; externalOnly context"}],
            "allStatePermissionOracleRetained": True,
            "forcedDispatchRegression": "Existing MenuBarApplicationTests inject disabled selectors to cover handler guards; not rerun here"}


def osa(script):
    return subprocess.run(["/usr/bin/osascript", "-"], input=script, text=True,
                          capture_output=True, timeout=5, check=True).stdout.strip()


def menu_script(pid, body, require_visible=True):
    guard = 'set menuDimensions to size of foundMenu\n if item 1 of menuDimensions <= 0 then error "Test menu is closed"' if require_visible else ""
    return f'''tell application "System Events"
 set p to first application process whose unix id is {pid}
 set testButton to missing value
 repeat with bar in menu bars of p
  repeat with candidate in menu bar items of bar
   if description of candidate is "Extilume TEST menu host" then set testButton to contents of candidate
  end repeat
 end repeat
 if testButton is missing value then error "Exact test status button absent"
 set foundMenu to menu 1 of testButton
 {guard}
 {body}
end tell'''


def menu_is_open(pid):
    return osa(menu_script(pid, 'set dimensions to size of foundMenu\n return item 1 of dimensions > 0', require_visible=False)) == "true"


def open_menu(pid):
    # A disabled AX action can dismiss the menu while its selected/geometry cache is still closing.
    deadline = time.monotonic() + 1.5
    previously_closed = False
    while time.monotonic() < deadline:
        state = osa(menu_script(pid, '''set AppleScript's text item delimiters to ","
 return (selected of testButton as text) & "," & (size of foundMenu as text)''', require_visible=False))
        trace("close-observation", pid=pid, state=state)
        closed = state == "false,0,0"
        if closed and previously_closed:
            break
        previously_closed = closed
        time.sleep(0.1)
    else:
        raise RuntimeError("Previous menu close did not settle; no new opening action")
    trace("open-AXPress-once", pid=pid)
    return osa(menu_script(pid, '''set dimensions to size of foundMenu
 if item 1 of dimensions > 0 or selected of testButton is true then error "Test menu not closed; no toggle"
 perform action "AXPress" of testButton
 return "open exact TEST menu once"''', require_visible=False))


def read_open_menu(pid):
    # Observe animation settling without ever repeating the opening action.
    deadline = time.monotonic() + 1.5
    previous_rect = None
    while time.monotonic() < deadline:
        visible = menu_is_open(pid)
        trace("open-observation", pid=pid, visible=visible)
        if visible:
            try:
                menu = read_menu(pid)
            except subprocess.CalledProcessError as error:
                if "Test menu is closed" not in error.stderr:
                    raise
                previous_rect = None
            else:
                if menu["rect"] == previous_rect:
                    return menu
                previous_rect = menu["rect"]
        else:
            previous_rect = None
        time.sleep(0.1)
    raise RuntimeError("Menu did not remain visible after its single opening action")


def attempt_disabled(pid, title):
    result = osa(menu_script(pid, f'''set q to menu item "{title}" of foundMenu
 if enabled of q is true then error "Expected disabled item enabled"
 try
  perform action "AXPress" of q
 on error messageText number errorNumber
  return "AX_REJECTED" & tab & errorNumber & tab & messageText
 end try
 return "AX_PERFORMED"'''))
    if result == "AX_PERFORMED":
        return {"status": "performed", "reachedPerformAXPress": True}
    if result.startswith("AX_REJECTED\t"):
        return {"status": "rejected-by-AX", "reachedPerformAXPress": True, "AXError": result}
    raise ValueError("Unrecognized disabled-action evidence: " + result)


def self_check():
    from unittest.mock import patch
    for response, expected in [("AX_PERFORMED", "performed"), ("AX_REJECTED\t-25204\trefused", "rejected-by-AX")]:
        with patch(__name__ + ".osa", return_value=response):
            assert attempt_disabled(1, PRIMARY)["status"] == expected
    guard_error = subprocess.CalledProcessError(1, ["osascript"], stderr="Expected disabled item enabled")
    with patch(__name__ + ".osa", side_effect=guard_error):
        try:
            attempt_disabled(1, PRIMARY)
        except subprocess.CalledProcessError as error:
            assert error is guard_error
        else:
            raise AssertionError("Guard error incorrectly accepted as disabled rejection")
    with patch(__name__ + ".osa", return_value="Expected disabled item enabled"):
        try:
            attempt_disabled(1, PRIMARY)
        except ValueError:
            pass
        else:
            raise AssertionError("Unknown evidence accepted")
    print("4 disabled-action classification checks passed; no UI")


def read_menu(pid):
    raw = osa(menu_script(pid, '''set AppleScript's text item delimiters to ","
 set output to "RECT" & tab & (position of foundMenu as text) & "," & (size of foundMenu as text) & linefeed
 repeat with i in menu items of foundMenu
  set helpText to "missing value"
  try
   set helpText to help of i as text
  end try
  set output to output & "ITEM" & tab & (name of i as text) & tab & (enabled of i as text) & tab & (value of attribute "AXMenuItemMarkChar" of i as text) & tab & (value of attribute "AXSelected" of i as text) & tab & helpText & linefeed
 end repeat
 return output'''))
    rows = raw.splitlines()
    rect = [int(v) for v in rows[0].split("\t")[1].split(",")]
    assert rect[2] > 0 and rect[3] > 0
    items = []
    for row in rows[1:]:
        _, title, enabled, mark, selected, help_text = row.split("\t")
        items.append(dict(title=title, enabled=enabled == "true", mark=mark, selected=selected == "true", help=help_text))
    return {"pid": pid, "rect": rect, "items": items, "raw": raw, "buttonIdentity": "Extilume TEST menu host"}


def assert_menu(menu, case, ready):
    actual = [{key: item[key] for key in ("title", "enabled", "mark")} for item in menu["items"] if item["title"] != "missing value"]
    assert actual == case["expectedMenu"], {"scenario": case["name"], "expected": case["expectedMenu"], "actual": actual}
    internal_visible = [item["title"] for item in ready["items"] if not item["hidden"]]
    assert internal_visible == [item["title"] for item in actual], "External visibility and host hidden flags disagree"


def ledger(directory):
    return json.loads((directory / "ledger.json").read_text())


def settled_ledger(directory, scenario, check_id, deadline):
    write(directory / "ledger-check-request.json", {"scenario": scenario, "id": check_id})
    while time.monotonic() < deadline:
        path = directory / "ledger-check-result.json"
        if path.exists():
            result = json.loads(path.read_text())
            if result["scenario"] == scenario and result["id"] == check_id:
                return result
        time.sleep(0.05)
    raise TimeoutError("Host main-queue ledger acknowledgment: " + check_id)


def keyboard_action(pid, target=None):
    # Every navigation step and activation is scoped to a proven, visible host menu.
    body = '''set trace to ""
 repeat with stepIndex from 1 to 12
  key code 125
  delay 0.05
  set selectedTitle to ""
  repeat with i in menu items of foundMenu
   if value of attribute "AXSelected" of i is true then set selectedTitle to name of i as text
  end repeat
  set trace to trace & stepIndex & ":" & selectedTitle & linefeed
'''
    if target is not None:
        body += f'''  if selectedTitle is "{target}" then
   if enabled of menu item "{target}" of foundMenu is not true then error "Keyboard target disabled"
   key code 36
   return trace & "Return once: {target}"
  end if
 end repeat
 error "Exact keyboard target not reached; no Return"'''
    else:
        body += '''  if stepIndex is 2 then exit repeat
 end repeat
 key code 126
 delay 0.05
 set selectedTitle to ""
 repeat with i in menu items of foundMenu
  if value of attribute "AXSelected" of i is true then set selectedTitle to name of i as text
 end repeat
 if selectedTitle is not "外屏主屏" then error "Up navigation did not return to first mode"
 key code 53
 return trace & "Up:外屏主屏; Escape once; no command"'''
    return osa(menu_script(pid, body))


def build_binding(directory):
    pointer = Path("/private/tmp/extilume-current-menu-acceptance-basis")
    basis_path = Path(pointer.read_text().strip()) / "basis.private.json"
    basis = json.loads(basis_path.read_text())
    product_sources = basis["sourceBindings"]
    assert len(product_sources) == 50, "Unexpected approved product source boundary"
    for name, digest in product_sources.items():
        assert sha(ROOT / name) == digest, "Product source drift: " + name
    candidate = json.loads(Path(basis["currentCandidateManifest"]).read_text())
    for name, digest in candidate["bundleFiles"].items():
        assert sha(ROOT / name) == digest, "Product bundle drift: " + name
    log_path = directory / "host.log"
    build_env = dict(os.environ)
    build_env.pop("EXTILUME_MENU_PRESENTATION", None)
    build_env.pop("EXTILUME_MENU_PRESENTATION_DIRECTORY", None)
    with log_path.open("w") as log:
        subprocess.run(["swift", "test", "--verbose", "-c", "release", "--disable-sandbox", "--filter", "MenuPresentationTests"],
                       cwd=ROOT, env=build_env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    assert "Test skipped" in log_path.read_text(), "Default interactive test did not skip"
    host_binaries = [p for p in (ROOT / ".build/release").glob("*.xctest/Contents/MacOS/*") if p.is_file()]
    assert host_binaries, "No Release XCTest binaries"
    runner = Path(subprocess.check_output(["xcrun", "--find", "xctest"], text=True).strip())
    sources = [ROOT / "Tests/ExtilumeNativeTests/MenuPresentationTests.swift", Path(__file__).resolve()]
    frozen = directory / "frozen-host"
    frozen.mkdir(mode=0o700)
    for path in sources + host_binaries:
        shutil.copyfile(path, frozen / path.name)
        (frozen / path.name).chmod(0o600)
    binding = {"productSourceBindings": product_sources, "productBundleBindings": candidate["bundleFiles"],
               "candidateManifestSHA256": sha(Path(basis["currentCandidateManifest"])),
               "hostFiles": {str(p.relative_to(ROOT)): sha(p) for p in sources + host_binaries},
               "xctestRunner": {"path": str(runner), "sha256": sha(runner)},
               "configuration": "Release XCTest; same product sources, different test binary",
               "swift": subprocess.check_output(["swift", "--version"], text=True),
               "sdkPath": subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip(),
               "sdkVersion": subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip(),
               "enableTestingFlagObservedInBuildLog": "-enable-testing" in log_path.read_text(),
               "differences": ["Release XCTest uses @testable/-enable-testing; not product binary",
                               "Regular policy, test window and test-created labeled status item",
                               "Product MenuBarApplicationDelegate.menu; no product lifecycle/status button",
                               "Controller, termination, reply and settings calls go only to recorders",
                               "Product resource digests bound separately; popup does not load product icon",
                               "Controlled states do not establish native backend events or recovery"]}
    if not binding["enableTestingFlagObservedInBuildLog"]:
        binary_key = ".build/release/ExtilumeNativeTests.xctest/Contents/MacOS/ExtilumeNativeTests"
        for prior_path in sorted((ROOT / ".local/verification").glob("menu-presentation-*/binding.json"), key=lambda p: p.stat().st_mtime, reverse=True):
            prior = json.loads(prior_path.read_text())
            if (prior.get("enableTestingFlagObservedInBuildLog")
                    and prior.get("hostFiles", {}).get(binary_key) == binding["hostFiles"].get(binary_key)):
                producer_log = prior_path.with_name("host.log")
                assert "-enable-testing" in producer_log.read_text()
                binding["matchingBinaryCompilerEvidence"] = {"binding": str(prior_path), "buildLog": str(producer_log),
                                                             "buildLogSHA256": sha(producer_log), "flag": "-enable-testing"}
                break
        assert "matchingBinaryCompilerEvidence" in binding, "No actual compile-flag evidence for cached test binary"
    write(directory / "binding.json", binding)
    return binding


def main():
    global TRACE_PATH, TRACE_SCENARIO
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--pilot", action="store_true")
    mode.add_argument("--matrix", action="store_true")
    mode.add_argument("--self-check", action="store_true")
    parser.add_argument("--plan-only", action="store_true")
    parser.add_argument("--scenario", help="Bounded diagnostic of one independent non-reuse scene")
    parser.add_argument("--resume-from", type=Path, help="Retain verified prefix from a stopped run")
    args = parser.parse_args()
    if args.self_check:
        self_check()
        return
    os.umask(0o077)
    directory = Path(tempfile.mkdtemp(prefix="menu-presentation-", dir=ROOT / ".local/verification"))
    TRACE_PATH = directory / "input-trace.jsonl"
    plan = freeze_plan(args.matrix)
    original_cases = list(plan["scenarios"])
    plan["revision"] = {"reason": "Retain every visual/permission/command case; replace repeated disabled AX pressure with shared guard representatives. One final disabled attempt per selected scene; no same-scene reopen.",
                        "supersededPressureBounds": {"scenarios": 44, "screenshots": 44, "statusMenuOpens": 114, "disabledAXAttempts": 70, "enabledCommands": 15, "totalSeconds": 600},
                        "revisedFullBounds": dict(plan["bounds"]),
                        "caseOracleChanged": False, "enabledCommandMappingChanged": False}
    previous_reports = {}
    previous_binding = None
    if args.resume_from:
        if args.scenario:
            parser.error("Resume and diagnostic are separate operations")
        previous = args.resume_from.resolve()
        old_plan = json.loads((previous / "plan.json").read_text())
        old_result = json.loads((previous / "matrix-result.json").read_text())
        previous_binding = json.loads((previous / "binding.json").read_text())
        old_prefix = len(old_plan.get("resume", {}).get("verifiedPrefix", []))
        def oracle(cases):
            return [{key: value for key, value in case.items() if key != "disabledAttempts"} for case in cases]
        assert oracle(old_plan["scenarios"]) == oracle(original_cases[old_prefix:]), "Resume visual/command oracle changed"
        for case in original_cases:
            prior = old_result["scenarios"][case["name"]]
            if prior["status"] != "pass":
                break
            previous_reports[case["name"]] = dict(prior, evidenceDirectory=prior.get("evidenceDirectory", str(previous)))
        assert previous_reports and len(previous_reports) < len(original_cases)
        start_index = len(previous_reports)
        setup_replay = []
        while original_cases[start_index]["reuse"]:
            start_index -= 1
            setup_replay.insert(0, original_cases[start_index]["name"])
        for name in setup_replay:
            previous_reports.pop(name)
        plan["scenarios"] = original_cases[start_index:]
        plan["resume"] = {"directory": str(previous), "verifiedPrefix": list(previous_reports),
                          "previousResultSHA256": sha(previous / "matrix-result.json"),
                          "previousBindingSHA256": sha(previous / "binding.json"),
                          "fullPlannedScenes": len(original_cases), "newHostSetupReplay": setup_replay}
        remaining = plan["scenarios"]
        plan["bounds"].update(scenarios=len(remaining), screenshots=len(remaining),
                              statusMenuOpens=len(remaining),
                              enabledCommands=sum(c["action"] is not None for c in remaining),
                              disabledAXAttempts=sum(len(c["disabledAttempts"]) for c in remaining))
    if args.scenario:
        cases = [case for case in plan["scenarios"] if case["name"] == args.scenario and not case["reuse"]]
        if len(cases) != 1:
            parser.error("Diagnostic scene must be an independent planned scene")
        plan["scenarios"] = cases
        plan["bounds"].update(scenarios=1, statusMenuOpens=1, screenshots=1,
                              enabledCommands=int(cases[0]["action"] is not None),
                              disabledAXAttempts=len(cases[0]["disabledAttempts"]))
        plan["diagnosticOnly"] = True
    write(directory / "plan.json", plan)
    print(directory, flush=True)
    print(json.dumps(plan["bounds"], ensure_ascii=False), flush=True)
    if args.plan_only:
        return
    binding = build_binding(directory)
    if previous_binding is not None:
        assert binding["productSourceBindings"] == previous_binding["productSourceBindings"]
        assert binding["productBundleBindings"] == previous_binding["productBundleBindings"]
    log = (directory / "host.log").open("a")
    env = dict(os.environ, EXTILUME_MENU_PRESENTATION=plan["kind"], EXTILUME_MENU_PRESENTATION_DIRECTORY=str(directory))
    process = subprocess.Popen(["swift", "test", "-c", "release", "--skip-build", "--disable-sandbox",
                                "--filter", "MenuPresentationTests/testInteractivePresentation"],
                               cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    pid, current, completed = None, None, []
    reports = {case["name"]: previous_reports.get(case["name"], {"status": "not-run"}) for case in original_cases if not args.scenario or case["name"] == args.scenario}
    deadline = time.monotonic() + plan["bounds"]["totalSeconds"]
    menu_opens = 0
    try:
        for case in plan["scenarios"]:
            current = case["name"]
            TRACE_SCENARIO = current
            phase_deadline = min(time.monotonic() + 20, deadline)
            while True:
                if process.poll() is not None:
                    raise RuntimeError("Host ended before " + current)
                ready_path = directory / "ready.json"
                if ready_path.exists():
                    ready = json.loads(ready_path.read_text())
                    if ready["scenario"] == current:
                        pid = ready["pid"]
                        break
                if time.monotonic() > phase_deadline:
                    raise TimeoutError("Host readiness: " + current)
                time.sleep(0.05)
            write(directory / (current + "-ready.json"), ready)
            open_menu(pid)
            menu_opens += 1
            menu = read_open_menu(pid)
            assert_menu(menu, case, ready)
            write(directory / (current + "-ax.json"), menu)
            rect = ",".join(str(v) for v in menu["rect"])
            subprocess.run(["/usr/sbin/screencapture", "-x", "-R" + rect, str(directory / (current + ".png"))], check=True, timeout=5)
            before = ledger(directory)
            disabled_results = []
            for index, title in enumerate(case["disabledAttempts"]):
                assert len(case["disabledAttempts"]) == 1 and not case["action"] and not case["keyboardCancel"]
                assert menu_is_open(pid), "Representative target menu dismissed before disabled attempt"
                with (directory / (current + f"-disabled-receipt-{index}.json")).open("x") as out:
                    json.dump({"pid": pid, "title": title, "method": "AXPress", "expectedEnabled": False, "count": 1}, out, ensure_ascii=False)
                disabled_results.append({"title": title, **attempt_disabled(pid, title)})
                settled = settled_ledger(directory, current, current + f"-disabled-{index}", phase_deadline)
                disabled_results[-1]["mainQueueSettledLedger"] = settled
                assert settled["calls"] == before["calls"], "Disabled action produced a call: " + title
                write(directory / (current + "-disabled-actions.json"), {"attempts": disabled_results, "ledgerBefore": before, "ledgerAfter": ledger(directory)})
            if case["action"] or case["keyboardCancel"]:
                assert menu_is_open(pid), "Test menu dismissed before planned input; no reopening"
            assert menu_opens <= plan["bounds"]["statusMenuOpens"]
            write(directory / (current + "-disabled-actions.json"), {"attempts": disabled_results, "ledgerBefore": before, "ledgerAfter": ledger(directory)})
            # Permit the host to advance only after all external evidence checks succeed.
            (directory / (current + "-continue")).touch(mode=0o600)
            if case["action"]:
                with (directory / (current + "-action-receipt.json")).open("x") as out:
                    json.dump({"pid": pid, "title": case["action"], "method": case["method"], "count": 1}, out, ensure_ascii=False)
                if case["method"] == "keyboard":
                    action_result = keyboard_action(pid, case["action"])
                else:
                    action_result = osa(menu_script(pid, f'''set q to menu item "{case['action']}" of foundMenu
 if enabled of q is not true then error "Command disabled"
 perform action "AXPress" of q
 return "exact command AXPress once"'''))
            elif case["keyboardCancel"]:
                action_result = keyboard_action(pid)
            elif menu_is_open(pid):
                action_result = osa(menu_script(pid, 'key code 53\n return "Escape once"'))
            else:
                assert disabled_results, "Menu dismissed unexpectedly before planned cancel"
                action_result = "Final representative disabled AX attempt dismissed menu; zero new calls; no reopen"
            write(directory / (current + "-input-result.json"), {"result": action_result})
            host_result = directory / (current + "-host-result.json")
            while not host_result.exists():
                if process.poll() is not None or time.monotonic() > phase_deadline:
                    raise RuntimeError("No verified command-count result: " + current)
                time.sleep(0.05)
            observed = json.loads(host_result.read_text())
            expected = case["expectedAfterCompletion"] if case["completeQuit"] is not None else case["expectedCalls"]
            assert observed["calls"] == expected, observed
            reports[current] = {"status": "pass", "screenshot": current + ".png", "host": observed,
                                "disabledAttempts": len(disabled_results), "action": case["action"]}
            completed.append(current)
            write(directory / "progress.json", reports)
            print("PASS " + current, flush=True)
        assert process.wait(timeout=10) == 0
        for name, digest in binding["productSourceBindings"].items():
            assert sha(ROOT / name) == digest, "Product source drift during run"
        for name, digest in binding["productBundleBindings"].items():
            assert sha(ROOT / name) == digest, "Product bundle drift during run"
        write(directory / "matrix-result.json", {"passed": True, "hostPID": pid, "hostExited": True,
                                                 "completedThisRun": len(completed), "totalVerified": len(completed) + len(previous_reports),
                                                 "actualMenuOpens": menu_opens, "bounds": plan["bounds"], "scenarios": reports,
                                                 "productStatusButtonAcceptance": False})
        print(plan["kind"] + " passed", flush=True)
    except Exception as error:
        if current is not None:
            reports[current] = {"status": "fail", "error": str(error),
                                "stderr": getattr(error, "stderr", None), "stdout": getattr(error, "stdout", None)}
        write(directory / "abort.json", {"scenario": current, "reason": str(error)})
        write(directory / "matrix-result.json", {"passed": False, "hostPID": pid, "completedThisRun": len(completed), "actualMenuOpens": menu_opens, "scenarios": reports})
        if pid is not None:
            try:
                osa(menu_script(pid, 'key code 53\n return "cancel exact host menu"'))
            except Exception:
                pass
        process.wait(timeout=25)
        raise
    finally:
        log.close()


if __name__ == "__main__":
    main()
