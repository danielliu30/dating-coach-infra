# dating-coach-infra guardrails

Deployment + production infrastructure for the dating-coach app repo.
The app repo keeps product code and PR checks; this repo owns image
publishing, GCP provisioning and every change to live traffic.

## Non-negotiables

- **Waves only, forward only.** Public traffic moves through the
  `DEPLOY_WAVE_PLAN` staircase (alpha tag -> percent waves -> 100%). No step
  skips ahead, no ad-hoc `update-traffic` in workflow code outside
  deploy-waves.sh and the rollback path. Public rollouts are serialized:
  the api and web `deploy` jobs share the repo-wide `public-rollout`
  concurrency group, so the two services can never be mid-rollout at once.
- **Every wave is verified twice.** The probe suite (active contract checks
  on the candidate's tag URL) and the bake check (coverage + 5xx + slow
  ratio on the revision, 5xx ceiling service-wide) both gate each promotion.
  Re-running CI unit tests at a wave tests nothing new — live verification
  is what catches real breakage.
- **Auto-rollback, never wait.** A failed probe, bake gate or post-rollout
  health check reverts traffic to the previous revisions and fails the run.
- **Migrations up-only.** Every migration must be backward-compatible; the
  migrate job never rolls schema back.
- **Gates fail closed.** Unresolvable before-SHA => treat as changed and
  deploy; insufficient bake coverage => refuse to promote.
- **No secrets in the repo.** GCP creds come from WIF (deploy workflows on
  main in the `production` environment only); registry + runtime secrets come
  from GitHub secrets / Secret Manager. Scripts log names, never values.
- **Tests ship with the script they cover** (`test-*.sh` harnesses; `ci.yml`
  runs them on every PR).

## Layout

- `.github/workflows/deploy-{db,backend,ml,web}.yml` — the four pipelines
- `.github/workflows/gate-e2e.yml` — reusable e2e gate against an app SHA
- `scripts/` — `gcp-bootstrap.sh`, `release-window.sh`,
  `deploy-bake-check.sh`, `deploy-waves.sh` + `test-*.sh`
- `docs/` — deployment runbooks
