# Migration: job status + cancel onto `/api/jobs`

Tracking issue: [#12](https://github.com/Comfy-Org/ComfySwiftSDK/issues/12)

The SDK currently reads job status and cancels jobs through endpoints that the
ComfyUI front-facing OpenAPI contract has moved past. The `OpenAPI Contract` CI
check flags both as non-blocking warnings until this migration lands.

| SDK use | Current | Target |
|---|---|---|
| `Transport.fetchJobStatus` | `GET /api/prompt/{prompt_id}` (not in contract) | `GET /api/jobs/{job_id}` |
| `Transport.cancelJob` | `POST /api/queue {"delete":[id]}` (deprecated) | `POST /api/jobs/{job_id}/cancel` |

**`prompt_id` == `job_id`.** `JobHandle.id` is already the correct path parameter;
no id mapping is required.

## Status remap

`GET /api/jobs/{job_id}` returns a "user-friendly" status enum, not the legacy
ComfyUI strings:

| `/api/jobs` | legacy | `JobEvent` |
|---|---|---|
| `pending` | `queued` | `.queued` |
| `in_progress` | `running` | `.progress` |
| `completed` | `success` | `.complete` |
| `failed` | `error` | `.failed` |
| `cancelled` | `cancelled` | `.cancelled` |

`JobDetailDTO.legacyEquivalentStatus` performs this mapping so the cutover is a
drop-in for the existing `PollingFallback` / `ReattachCoordinator` switches.

**`outputs` is unchanged** — the contract describes it as the "Full outputs object
from ComfyUI", the same node-keyed dict the SDK already decodes. The `/api/view`
byte-fetch path does not change.

## Status of this work

- **Done (this PR):** `JobDetailDTO` / `JobCancelDTO` + the status remap, unit-tested
  against the documented response shapes.
- **Next (cutover, on top of the comment-purge PR #10):** point `Transport.fetchJobStatus`
  at `GET /api/jobs/{job_id}`, `Transport.cancelJob` at `POST /api/jobs/{job_id}/cancel`,
  update the `PollingFallback` / `ReattachCoordinator` / `WebSocketSession` call sites and
  their tests, and move the two entries in `Scripts/contract/sdk-endpoints.yml` onto `/api/jobs`.
- **Gate before merge of the cutover:** a staging smoke test against `cloud.comfy.org`
  for a real submit → status → output → cancel round-trip — the one thing the unit
  suite cannot prove.
