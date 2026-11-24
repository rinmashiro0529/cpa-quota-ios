"""Deterministically shard CPAQuotaAppUITests across parallel simulator jobs.

Parses every `func test...()` method in CPAQuotaAppUITests.swift so newly added
tests are always included in exactly one shard without editing the workflow.
Optionally patches TestingEnvironmentVariables in an `.xctestrun` plist.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

# Historical runtimes (seconds) from Xcode 27.1 iPhone 18 Pro CI used solely to
# balance shards evenly. Unlisted tests fall back to DEFAULT_WEIGHT_SECONDS.
KNOWN_WEIGHTS_SECONDS: dict[str, int] = {
    "testLargestDynamicTypeAndDeviceRotationPreservePrimaryActions": 217,
    "testLoginValidatesHTTPSAndRejectsManagement401BeforeConnecting": 183,
    "testCAPAllFourSectionsReadParsedFixtures": 181,
    "testReadingPositionDuringStreamGrowth": 160,
    "testRecentModelPersistsAcrossCreationAndLaunch": 146,
    "testHTMLPreviewKeepsSnapshotWhileConversationStreams": 133,
    "testAppearancePickerChangesRealCanvasAndWidgetSharingDefaultsOff": 120,
    "testCAPRangePanelCancelsWithoutRequestsAndSelectsBoundedHours": 114,
    "testHTMLPreviewRotatesWithLargeTextInDarkAppearance": 111,
    "testQuotaCardShowsRegularCodexWindowsInOrderWithUnknownAndSevenDayOnly": 107,
    "testLargeChatControlsInLightAndDarkLandscape": 104,
    "testCAPMonthOverviewUsesServerSummaryFromInitialOnly": 100,
    "testStopContinueAndCompleteOneReply": 100,
    "testSwipeDismissalDuringSlowConnectionClearsDraftAndRejectsLateResponse": 89,
    "testChatEditCancelRestoresMultilineDraft": 86,
    "testChatReasoningPickerSelectsPersistsAndShowsFallbackNotice": 85,
    "testCloseDuringSlowConnectionClearsDraftAndRejectsLateResponse": 83,
    "testForegroundReturnAndExplicitExpiryKeepOneGeneration": 81,
    "testInterruptedGenerationRestoresWrittenCheckpointWithoutRequest": 79,
    "testFiveNativeTabsAndQuotaDetailKeepTheirSystemNavigation": 76,
    "testChatTranscriptStaysVisibleWhenSendingAgainWithKeyboardOpen": 72,
    "testChatSelectsModelStreamsStopsAndRegenerates": 66,
    "testHTMLFallbackCopiesOriginalMixedFences": 56,
    "testUnconfiguredMonitoringRequiresSeparateCredentials": 53,
    "testMonitoringDeepLinkOpensMonitoringPage": 45,
    "testReasoningIsVisibleBeforeAnswerIsReleased": 45,
    "testLegacyFixedModelSurvivesLaunch": 32,
}
DEFAULT_WEIGHT_SECONDS = 90
UNIT_TEST_TARGET_WEIGHT_SECONDS = 25

# Focused Duo PR suite: exercises adaptive windowing, rotation, AX5 Dynamic Type,
# light/dark appearance, chat composer/popover, HTML preview rotation, and 5-tab
# chrome. Pushes to `main` and `workflow_dispatch` still run the full 3-shard suite.
DUO_PR_FOCUSED_TESTS: tuple[str, ...] = (
    "testLargestDynamicTypeAndDeviceRotationPreservePrimaryActions",
    "testAppearancePickerChangesRealCanvasAndWidgetSharingDefaultsOff",
    "testHTMLPreviewRotatesWithLargeTextInDarkAppearance",
    "testLargeChatControlsInLightAndDarkLandscape",
    "testChatReasoningPickerSelectsPersistsAndShowsFallbackNotice",
    "testFiveNativeTabsAndQuotaDetailKeepTheirSystemNavigation",
)


def _strip_swift_comments(source: str) -> str:
    """Remove // and /* ... */ comments while preserving string literals."""
    out: list[str] = []
    i = 0
    n = len(source)
    in_string = False
    block_depth = 0
    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if block_depth > 0:
            if ch == "/" and nxt == "*":
                block_depth += 1
                i += 2
            elif ch == "*" and nxt == "/":
                block_depth -= 1
                i += 2
            else:
                if ch == "\n":
                    out.append("\n")
                i += 1
            continue
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(source[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
        elif ch == "/" and nxt == "/":
            i += 2
            while i < n and source[i] != "\n":
                i += 1
        elif ch == "/" and nxt == "*":
            block_depth = 1
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def discover_ui_tests(source_path: Path) -> list[str]:
    """Return every `func test...()` method declared in CPAQuotaAppUITests."""
    text = _strip_swift_comments(source_path.read_text(encoding="utf-8"))
    class_match = re.search(r"\bclass\s+CPAQuotaAppUITests\s*:\s*XCTestCase\b", text)
    if not class_match:
        raise ValueError(f"CPAQuotaAppUITests class not found in {source_path}")
    body = text[class_match.end():]
    names = re.findall(r"\bfunc\s+(test[A-Za-z0-9_]+)\s*\(\s*\)", body)
    if not names:
        raise ValueError(f"No UI test methods discovered in {source_path}")
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise ValueError(f"Duplicate UI test methods discovered: {duplicates}")
    return names


def partition_shards(tests: list[str], shard_count: int) -> list[list[str]]:
    """Assign every test to exactly one shard using LPT greedy bin-packing."""
    if shard_count < 1:
        raise ValueError("shard_count must be >= 1")
    shards: list[list[str]] = [[] for _ in range(shard_count)]
    loads: list[int] = [0] * shard_count
    # Shard 1 also runs CPAQuotaTests (~25s).
    loads[0] = UNIT_TEST_TARGET_WEIGHT_SECONDS
    ordered = sorted(
        tests,
        key=lambda name: (-KNOWN_WEIGHTS_SECONDS.get(name, DEFAULT_WEIGHT_SECONDS), name),
    )
    for name in ordered:
        weight = KNOWN_WEIGHTS_SECONDS.get(name, DEFAULT_WEIGHT_SECONDS)
        best = min(range(shard_count), key=lambda idx: (loads[idx], len(shards[idx]), idx))
        shards[best].append(name)
        loads[best] += weight
    for shard in shards:
        shard.sort()
    return shards


def select_only_testing_args(
    source_path: Path,
    mode: str,
    shard_index: int = 1,
    shard_count: int = 3,
) -> tuple[list[str], list[str]]:
    """Return (`only_testing_args`, `selected_ui_tests`) for the requested mode."""
    discovered = discover_ui_tests(source_path)
    discovered_set = set(discovered)
    args: list[str] = []
    if mode == "duo-pr":
        missing = [name for name in DUO_PR_FOCUSED_TESTS if name not in discovered_set]
        if missing:
            raise ValueError(f"DUO_PR_FOCUSED_TESTS missing from {source_path}: {missing}")
        selected = list(DUO_PR_FOCUSED_TESTS)
        args.append("-only-testing:CPAQuotaTests")
    elif mode == "full":
        if not 1 <= shard_index <= shard_count:
            raise ValueError(f"shard_index {shard_index} out of range 1..{shard_count}")
        shards = partition_shards(discovered, shard_count)
        selected = shards[shard_index - 1]
        if shard_index == 1:
            args.append("-only-testing:CPAQuotaTests")
    else:
        raise ValueError(f"Unsupported mode: {mode}")

    for name in selected:
        args.append(f"-only-testing:CPAQuotaAppUITests/CPAQuotaAppUITests/{name}")
    return args, selected


def patch_xctestrun_env(xctestrun_path: Path, env_updates: dict[str, str]) -> int:
    """Inject TestingEnvironmentVariables into FormatVersion 1 or 2 xctestrun plists."""
    if xctestrun_path.is_symlink():
        raise ValueError(f"Refusing to patch symlinked xctestrun: {xctestrun_path}")
    with xctestrun_path.open("rb") as fh:
        plist = plistlib.load(fh)
    if not isinstance(plist, dict):
        raise ValueError("Invalid xctestrun plist root")

    patched_targets = 0
    if "TestConfigurations" in plist and isinstance(plist["TestConfigurations"], list):
        for config in plist["TestConfigurations"]:
            if not isinstance(config, dict):
                continue
            for target in config.get("TestTargets", []):
                if not isinstance(target, dict):
                    continue
                env = target.setdefault("TestingEnvironmentVariables", {})
                if isinstance(env, dict):
                    env.update(env_updates)
                    patched_targets += 1
    else:
        for key, value in plist.items():
            if key == "__xctestrun_metadata__" or not isinstance(value, dict):
                continue
            if "TestBundlePath" in value or "TestingEnvironmentVariables" in value:
                env = value.setdefault("TestingEnvironmentVariables", {})
                if isinstance(env, dict):
                    env.update(env_updates)
                    patched_targets += 1

    if patched_targets == 0:
        raise ValueError(f"No test targets found to patch in {xctestrun_path}")

    with xctestrun_path.open("wb") as fh:
        plistlib.dump(plist, fh, fmt=plistlib.FMT_XML)
    return patched_targets


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--mode", choices=("full", "duo-pr"), required=True)
    parser.add_argument("--shard-index", type=int, default=1)
    parser.add_argument("--shard-count", type=int, default=3)
    parser.add_argument("--emit-args", type=Path, required=True)
    parser.add_argument("--patch-xctestrun", type=Path)
    parser.add_argument("--layout-policy")
    parser.add_argument("--simulator-device")
    args = parser.parse_args(argv)

    only_testing, selected = select_only_testing_args(
        args.source, args.mode, args.shard_index, args.shard_count
    )
    args.emit_args.parent.mkdir(parents=True, exist_ok=True)
    args.emit_args.write_text("\n".join(only_testing) + "\n", encoding="utf-8")

    patched = 0
    if args.patch_xctestrun is not None:
        env_updates: dict[str, str] = {}
        if args.layout_policy:
            env_updates["CPA_UI_LAYOUT_POLICY"] = args.layout_policy
        if args.simulator_device:
            env_updates["CPA_UI_SIMULATOR_DEVICE"] = args.simulator_device
        if env_updates:
            patched = patch_xctestrun_env(args.patch_xctestrun, env_updates)

    est_seconds = sum(KNOWN_WEIGHTS_SECONDS.get(name, DEFAULT_WEIGHT_SECONDS) for name in selected)
    if "-only-testing:CPAQuotaTests" in only_testing:
        est_seconds += UNIT_TEST_TARGET_WEIGHT_SECONDS

    print(json.dumps({
        "mode": args.mode,
        "shardIndex": args.shard_index,
        "shardCount": args.shard_count,
        "includesUnitTests": "-only-testing:CPAQuotaTests" in only_testing,
        "uiTestCount": len(selected),
        "estimatedSeconds": est_seconds,
        "patchedXctestrunTargets": patched,
        "uiTests": selected,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
