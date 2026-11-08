# Public readiness hardening and re-audit - 2026-11-08

This is an evidence ledger, not a guarantee of perfection or absence of vulnerabilities.
Public source collaboration, automated candidate acceptance, and signed production
release acceptance are separate decisions.

## Fixed inputs and historical scan

The implementation starts from main `122eb0499c437491546894cc28a8e5f6eb697dd6`.
Inventory run `42456562344` collected 34 refs and 59 reachable commits, including
public branch, tag and pull-request heads and the Duo experiment branch. It used
Gitleaks 8.30.1 with default rules, no repository ignore file and no inline allows,
and merge-aware history (`--all --full-history -m`). Unreachable objects, external
fork repositories, historical Actions logs and Release attachments are not covered.

There were 32 generic-api-key findings at ten unique checksum lines in three JSON
evidence documents. Each line was read from its exact commit. Each recorded SHA-256
was recomputed against an actual Git source blob. All 32 were verified source
checksums, not confirmed credentials. No finding was suppressed by directory, file
extension, keyword, or a blanket 64-character-hex exception. The exact proof manifest
is `ci/reviewed-source-digests.json`; its ten entries are executable evidence, not an
unconditional allowlist. Changed lines, mismatched source blobs and all other rules
remain blocking findings.

The downloaded inventory ZIP was 5,039,078 bytes with SHA-256
`8c20117a3b0954ab1fb22e62125ab61c417a4a311297b354ad5bc6ff93f441b8`.
The scanner archive SHA-256 was verified against the upstream release metadata.
The final ongoing gate does not publish repository bundles or raw scanner reports.

## Changes and focused evidence

| Area | Change | Evidence and scope |
| --- | --- | --- |
| Secret scanning | Required PR/main snapshot and merge-aware history scan; all visible refs on main pushes; synthetic canary; checksum-verified scanner | Invalid scanner status, shallow history, missing reports, unknown findings and unverified exceptions fail closed. Metadata only is uploaded. |
| Time bounds | Public duration/age/countdown helpers safely handle unsupported values; monitoring epochs share the existing CPA calendar bounds | A standalone probe extracted from the original duration function exited on an extreme finite input; the patched function returned the unknown-duration label. Swift regression tests cover constructor, decoder, date and cooldown boundaries. |
| Cooldown status | An elapsed management cooldown is no longer projected as connected without a successful response | Integration regression exercises a successful connection, injected management 429, deadline expiry, then an explicit successful reconnect. Cached values and individual-account/management separation remain unchanged. |
| Duo | Promote the pinned, isolated inner-display smoke workflow; require portrait instead of optional capture; verify same UUID, hinge, active display, image integrity/geometry and return to cover | Original experiment `42455336529` provides the initial actual simulator evidence. Unit cases test inconsistent/missing states. New candidate CI must produce its own captures. This is not physical-device or all-workspace acceptance. |
| CI supply chain | Checkout updated to a reviewed full v6 commit using Node 24; ordinary validation jobs remain read-only with no persisted checkout credentials | Check names and admin-only ruleset template now include the secret gate and Duo smoke, in addition to the four existing jobs. A template does not activate server protection. |

Local tool tests and test-target compilation were run before submission. The local
Linux Swift runtime has an existing Observation linker issue, so compilation is not
reported as execution of all Swift tests. The exact candidate's macOS package/native
runs, and the merged main run, must be recorded in the PR before claiming completion.
Failures and earlier attempts remain visible rather than being relabeled as passed.

## Remaining independent acceptance

- `main` server-side protection was still disabled at the starting review. The
  connected GitHub interface supports repository code writes but not administration
  writes. No protection, required review, billing, visibility or bypass settings
  were changed. Implementer review is not independent approval.
- A usable private vulnerability-reporting channel has not been verified. A public
  security-page fetch was unavailable; that is not evidence the feature is disabled.
- The three draft Releases and their 19 attachments were not republished. Their
  earlier scans do not cover new artifacts or certify distribution rights.
- MIT and the owner's source/icon authorization statements are present; this work
  does not independently certify third-party ownership. `duoctl` is MIT licensed,
  pinned to `c6ff3e961a9858fb061907448e702d7d1617dc4a`, and used only in CI,
  not linked into or shipped with the app.
- Actual iOS 17 compatibility, physical devices, Keychain locked/unavailable states,
  signed installation, APNs delivery, performance and full accessibility acceptance
  need their specified hardware/service evidence. The legacy FS-03 acceptance label
  is not automatically closed by these time-boundary regressions.

## Re-audit decision rule

A passing result requires all six named checks on the exact candidate, then on the
actual merged main commit, plus review of the exported scan metadata and screenshot
state evidence. Inspect changed files again for secrets, overbroad exceptions,
weakened test assertions, extra permissions and misleading completion claims.
Record the exact commit/run/attempt and all remaining constraints in the PR.

With these gates passing and no unresolved findings in the recorded scope, public
preview collaboration is reasonable. This statement is not a signed-app release
approval, a penetration-test result, or a promise of zero defects.
