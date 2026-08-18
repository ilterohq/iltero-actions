# Plan-to-apply provenance attestation

This feature proves that the exact infrastructure change Iltero checked for
compliance is the same change that was deployed. It is **on by default** —
anti-substitution is one of Iltero's core guarantees, so it is enforced unless
you explicitly turn it off (`attest: false`).

The deploy applies the exact evaluated change and Iltero enforces, fail-closed,
that it matches what was checked. This stops a different change being deployed
than the one that was checked.

Units that can't be bound (for example, those not on an S3 backend) degrade
gracefully: they deploy as before and are reported honestly as *not bound*,
rather than failing. The deploy is only blocked on an actual mismatch.

If your pipeline deliberately **re-plans at apply time** (to pick up drift or
time-dependent data sources), set `attest: false` to keep that behaviour —
applying the saved plan instead of a fresh one is exactly what this feature
enforces.

## What it does, in plain terms

1. When Iltero checks a change, it records a **fingerprint** of that exact change.
2. At deploy time, instead of regenerating the change, the deploy applies the
   **saved** change and Iltero re-checks its fingerprint against what was
   recorded — the deploy is blocked if they don't match.

A unit is only "provenance-bound" when this binding holds. Units that can't be
bound (see [Coverage](#coverage)) are reported honestly as *not bound* rather
than being silently treated as proven.

## Quick start

It's on by default, so there's nothing to switch on. To get units actually
**bound** (rather than degrading to "not bound"):

1. **Commit `.terraform.lock.hcl`** for each unit and pin the **same Terraform
   version** in the check job and the deploy job (see [Prerequisites](#prerequisites)).
2. **Use an S3 backend** for any unit you want bound (see [Prerequisites](#prerequisites)).

```yaml
jobs:
  deploy:
    steps:
      - uses: actions/checkout@<sha>
      - uses: ilterohq/iltero-actions/setup@ac5d3a90e14bdb9a9593f37cba9ed67ba41afb3a # v0.2.0
      - uses: ilterohq/iltero-actions@ac5d3a90e14bdb9a9593f37cba9ed67ba41afb3a # v0.2.0
        with:
          mode: deploy
          # attest defaults to true; set attest: false to opt out
```

### Using the granular `evaluate` / `deploy` actions

The root action above runs both phases, so it's the simplest path. If you instead
call the granular `evaluate` and `deploy` actions directly (often in separate jobs
with an approval gate between), **`attest` must match across the pair**:

- Both `evaluate` and `deploy` default to `attest: true`, so leaving them at the
  default keeps them aligned. If you set `attest: false` on one, set it on both —
  binding on evaluate but not attesting deploy would re-plan instead of applying
  the saved plan, silently breaking the guarantee.
- `evaluate` takes `attest` and `s3-sse` (it fingerprints + stores the plan).
- `deploy` takes `attest` (it fetches and applies the saved plan, enforced at the
  deploy gate).

### Configuration reference (`ILTERO_*` env)

The actions are thin wrappers that set these environment variables, which the
underlying scripts read. This is the single source of truth for the contract:

| Env var | From input | Meaning |
|---------|-----------|---------|
| `ILTERO_ATTEST` | `attest` | Enable enforcement (`true`/`false`; default `true`). |
| `ILTERO_S3_SSE` | `s3_sse` | Plan-artifact encryption mode. |

## Prerequisites

- **A committed `.terraform.lock.hcl` per unit**, and the **same Terraform version**
  in the check job and the deploy job. The deploy applies the *saved* plan, and
  Terraform refuses to apply a saved plan if the provider versions or Terraform
  version differ. A mismatch **fails the deploy with a clear error** — it does not
  silently fall back to regenerating the plan.
- **An S3 backend** for any unit you want bound. The saved plan is handed from the
  check job to the deploy job through the unit's existing S3 backend bucket. Units
  on other backends aren't bound yet (reported honestly as not bound).

## Backend bucket posture and permissions

The saved plan is stored in the same bucket as your Terraform state, so it
inherits that bucket's protection. Ensure:

- **Block Public Access is on** and the bucket has **default encryption** (or set
  `s3_sse: AES256` / `s3_sse: aws:kms` to force a mode on upload).
- The unit's backend config sets `region` explicitly (a unit relying on an
  ambient `AWS_REGION` is reported not bound).
- IAM: the **check job** needs `s3:PutObject` and the **deploy job** needs
  `s3:GetObject` on the `…/plans/*` prefix (note: being able to read state does
  **not** automatically grant reading that prefix). Add `kms:Decrypt` on the
  relevant key if you use `aws:kms`. Keep the set of principals that can write that
  prefix small.
- Consider an S3 lifecycle rule expiring the `plans/` prefix (longer than your
  maximum approval-pause window).

## Coverage

Not every unit can be bound, and the run summary says which were:

- **bound (enforced)** — applied the saved plan; the deploy gate enforced that its
  fingerprint matches what was checked.
- **best-effort (not bindable)** — checked before its dependencies existed, so the
  checked change isn't the deployable one. Not bound by design.
- **not provenance-bound** — no saved plan (e.g. not an S3 backend, or attestation
  was off for that run).

If you enable attestation but no unit is bound, the run summary says so loudly.
Common causes: your installed Iltero CLI is older than the version that computes
the fingerprint, the units aren't on an S3 backend, or they were checked
best-effort.

## Verification

This action enforces the plan-to-apply binding at deploy time: the deploy is
blocked unless the saved change's fingerprint matches the one Iltero recorded when
it checked the change.
