# dating-coach-infra

Deployment and production infrastructure for [dating-coach](https://github.com/danielliu30/dating-coach).
The app repo holds only product code and its PR checks; everything that
*builds images and changes production* lives here.

## How a merge becomes a deploy

```
app repo: merge to main
  -> .github/workflows/notify-infra.yml
     POST /repos/danielliu30/dating-coach-infra/dispatches
     { event_type: app-merge, client_payload: { sha, before } }

infra repo: all four deploy-*.yml wake on repository_dispatch(app-merge)
  -> changed job: git diff before..sha on the app checkout -> skip if the
     service's paths were untouched
  -> e2e gate: gate-e2e.yml runs the app repo's e2e suite at that SHA
  -> build-push: checkout app @ sha, docker compose build/push :<sha> (+ :latest
     only when the SHA is still the app repo's main tip)
  -> deploy (DEPLOY_TARGET=cloud-run):
       release window -> migrate -> service rollout
```

Each pipeline only owns its piece:

| Workflow | App path | Ships |
|---|---|---|
| `deploy-db.yml` | `backend/migrations/**` | `dating-coach-migrate` image -> Cloud Run job (up-only) |
| `deploy-backend.yml` | `backend/**` | `dating-coach-backend` image -> migrate job -> worker + Pub/Sub + Scheduler -> api wave rollout |
| `deploy-ml.yml` | `ml-analyzer/**` | `dating-coach-ml-analyzer` image -> candidate revision -> Ready check -> 100% |
| `deploy-web.yml` | `app/**` | `dating-coach-web` image -> alpha tag -> wave rollout |

## Wave rollout (api + web)

`scripts/deploy-waves.sh` walks `DEPLOY_WAVE_PLAN` (default
`10:15 25:30 50:45 100:0` — percent:bake-minutes, forward only):

1. The new revision deploys tagged `wave-candidate` with **no traffic** — an
   alpha smoke hits the tag URL directly (synthetic coverage, since real
   traffic hasn't arrived).
2. Each wave shifts `N%` of traffic, then verifies on two axes before
   promoting:
   - **Active probes** — `deploy-probe-suite.sh` runs the per-service contract
     suite (`probe-suite.{api,web}.conf`) against the candidate's tag URL
     before and after the bake: real requests exercising the paths that
     matter, on every wave. They also feed coverage. A semantic break fails
     fast instead of baking quietly.
   - **Traffic metrics** — `deploy-bake-check.sh` reads the revision's request
     logs and requires: **coverage** (`>= BAKE_MIN_REQUESTS` — a quiet wave
     proves nothing), **5xx rate** under `BAKE_MAX_ERROR_RATE`%, **slow-request
     ratio** under `BAKE_MAX_SLOW_RATE`%, and a **service-wide 5xx ceiling**
     across all revisions — a bad canary can hurt customers it doesn't even
     serve.
3. Any breach reverts traffic to the revisions serving before the deploy. A
   passing 100 wave is the only path to full traffic.
4. `BAKE_WATCH_MINUTES` (default 15) then holds a post-promotion watch at 100%
   and re-runs the bake gate — slow-burn regressions under full traffic still
   roll back.

`scripts/release-window.sh` gates deploys to `DEPLOY_WINDOW_DAYS` +
`DEPLOY_WINDOW_START_UTC`/`_END_UTC` (UTC). Restores (`image_tag` dispatch)
skip the window and go straight to 100% — rollback should not wait.

## Manual operations

```bash
# Roll back a service to a published image tag (list tags on Docker Hub)
gh workflow run deploy-backend.yml -R danielliu30/dating-coach-infra -f image_tag=<old-app-sha>

# Deploy an arbitrary app commit (build + gate + rollout)
gh workflow run deploy-web.yml -R danielliu30/dating-coach-infra -f app_sha=<sha>
```

Config-only changes (new secret version, flipped variable) need a fresh
revision to take effect — dispatch `image_tag` with the current tag to roll
new revisions on the same image.

## One-time setup

- `scripts/gcp-bootstrap.sh` — GCP service accounts, WIF trust **scoped to this
  repo's deploy workflows**, Secret Manager secrets, Pub/Sub topics. See
  `docs/deploy-cloud-run.md`.
- App repo: secret `INFRA_DISPATCH_TOKEN` (or `MERGE_BOT_TOKEN` if the PAT
  covers this repo) with `contents:write` here, used by notify-infra.yml.

## Secrets / variables (this repo)

| Name | Kind | Purpose |
|---|---|---|
| `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | secret | image push |
| `DEPLOY_TARGET` | variable | `cloud-run` enables real deploys; unset = print local commands |
| `DEPLOY_WINDOW_DAYS`, `DEPLOY_WINDOW_START_UTC`, `DEPLOY_WINDOW_END_UTC` | variable | release window (UTC); empty = always open |
| `DEPLOY_WAVE_PLAN`, `BAKE_*` | variable | wave staircase and bake thresholds |
| `GCP_*` | variable | project, region, service accounts, WIF provider (from gcp-bootstrap.sh) |
| `API_PUBLIC_URL`, `PUBLIC_APP_URL`, `GOOGLE_CLIENT_ID`, `SMTP_*`, `MAIL_FROM`, `LLM_*`, `*_INSTANCES` | variable | runtime settings baked into services |
| `production` | environment | required by the WIF trust condition — restrict to main |

## Testing the gates offline

```bash
bash scripts/test-release-window.sh
bash scripts/test-deploy-bake-check.sh
bash scripts/test-deploy-waves.sh   # gcloud/sleep/check are stubbed
```

Runs in CI (`ci.yml`) on every PR.
