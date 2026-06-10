# ID-BLU Wrapper Refactor Plan

## Summary

This repository is currently serving two roles:

1. it is a fork of `vllm-project/vllm-omni`
2. it contains the internal ID-BLU TTS wrapper, deployment manifests, and release workflows

That split creates ongoing maintenance cost. Any upstream update can force us to:

- rebase or merge the fork
- rebuild and publish a full custom image
- retest the combined runtime
- redeploy wrapper and upstream changes together

The goal of this refactor is to stop treating the fork as the delivery unit for the internal wrapper. The agreed end state is:

- upstream `vllm-omni` runs from the official published image with no code patching
- the ID-BLU wrapper lives in a dedicated private repository named `id-blu-tts`
- the wrapper and upstream server run as separate containers in the same pod
- the `qwen3_tts_smooth.yaml` deploy profile is managed outside the fork and mounted into the upstream container as a file
- the new private repository becomes the source of truth
- this fork is retired after cutover and then archived or deleted

This keeps the wrapper private, reduces fork drift, and makes upstream updates materially cheaper.

## Current State

### Internal code and packaging currently inside this fork

The internal wrapper is implemented in:

- `idblu_tts_wrapper/app.py`
- `idblu_tts_wrapper/config.py`
- `idblu_tts_wrapper/voice_registry.py`
- `idblu_tts_wrapper/pod_warmup.py`

It is packaged into this repo's Python distribution via:

- `pyproject.toml`

### Current runtime model

The current production shape is a single custom image that starts:

- `vllm-omni` on port `8091`
- the wrapper on port `8080`
- an in-container warmup process

This is wired by:

- `docker/Dockerfile.idblu_tts`
- `docker/start-idblu-tts.sh`
- `examples/online_serving/qwen3_tts/run_server.sh`

### Current deployment model

The deployment manifests live inside this fork under:

- `idblu_tts_wrapper/k8s/base`
- `idblu_tts_wrapper/k8s/staging`
- `idblu_tts_wrapper/k8s/release`
- `idblu_tts_wrapper/k8s/production`

The current pod model is one container exposing both:

- wrapper HTTP on `8080`
- upstream HTTP on `8091`

Shared storage is already in place for:

- model cache under `/cache`
- voice cache under `/data/voices`

### Current CI/CD model

Wrapper-specific build and promotion workflows also live in this fork:

- `.github/workflows/deploy-idblu-tts-staging.yml`
- `.github/workflows/promote.yml`

### Fork delta that matters for the refactor

Most wrapper-specific changes are operational and packaging-related. The main non-wrapper deltas currently in the fork are:

- custom Qwen3-TTS startup/config selection in `examples/online_serving/qwen3_tts/run_server.sh`
- custom deploy profiles in `vllm_omni/deploy/qwen3_tts_safe.yaml` and `vllm_omni/deploy/qwen3_tts_smooth.yaml`
- logging and observability changes in `vllm_omni/entrypoints/openai/serving_speech.py`

This is favorable. It means the wrapper can be separated without first rewriting large portions of upstream runtime code.

## Problems To Solve

### Operational problems

- Upstream sync and internal wrapper delivery are coupled.
- A small wrapper change requires rebuilding the full combined image.
- A small upstream change can force unnecessary retesting of internal wrapper code.
- Release workflows are tied to a fork that should ideally remain close to upstream.

### Ownership problems

- The internal wrapper code is mixed into an open-source fork.
- Kubernetes manifests and release logic for an internal service live beside upstream project code.
- It is harder to define clear ownership boundaries between upstream tracking and internal product delivery.

### Upgrade problems

- The fork must stay synchronized with upstream manually.
- Any future move to a different upstream image tag or version still requires custom image maintenance.
- The current image entrypoint embeds both orchestration and policy decisions that are not native to upstream.

## Target State

## Preferred target architecture

Use a dedicated private repository for the wrapper and deploy two containers in one pod:

1. `wrapper` container
2. `vllm-omni` container based on a standard published upstream image

The wrapper continues to call the upstream server over localhost:

- `IDBLU_TTS_UPSTREAM_URL=http://127.0.0.1:8091`

The pod continues to share:

- model cache volume
- voice cache volume
- secrets

The wrapper remains the externally exposed API and retains responsibility for:

- admin auth
- voice resolution
- request shaping
- warmup coordination
- readiness gating

The upstream container remains responsible only for model serving.

## Agreed repository and deployment model

The new private repository will be named `id-blu-tts` and will contain everything required to deploy the service to EKS:

- wrapper application code
- Kubernetes manifests and overlays
- mounted deploy profile files
- deployment and rollback runbooks
- GitHub Actions workflows

The deployment model remains operationally compatible with the current service:

- current naming stays `idblu-tts` for Kubernetes objects, image naming, and workflow naming where practical
- environment model stays `staging`, `release`, and `production`
- ingress hostnames, auth model, request/response schema, readiness semantics, and voice storage semantics remain unchanged
- rollout happens sequentially: `staging`, then `release`, then `production`

## Why sidecar instead of a separate remote service

Sidecar deployment is the safer first refactor because it:

- preserves the existing localhost dependency model
- avoids introducing service-to-service networking and new failure modes
- keeps shared PVC usage simple
- allows independent images without changing the client-facing wrapper API

A fully separate wrapper service can remain a later option if we need independent scaling or routing.

## Non-Goals

This refactor should not initially try to:

- redesign the wrapper API
- change the external ingress contract
- change voice storage semantics
- redesign model cache storage
- replace Kubernetes overlays or environment naming
- solve every remaining upstream fork delta in one pass

The first objective is to decouple delivery and ownership, not to redesign the whole system.

## Migration Strategy

## Phase 0: Baseline and decision checkpoint

### Objective

Create a frozen baseline before changing repo boundaries or deployment topology.

### Tasks

- Record the exact upstream image version tag we want to standardize on.
- Record the exact current fork commit used for deployments.
- Capture the runtime contract:
  - wrapper port
  - upstream port
  - required env vars
  - mounted volumes
  - readiness behavior
  - warmup behavior
- Inventory any behavior that depends on fork-only upstream code.

### Deliverables

- deployment baseline document
- selected upstream image version tag
- short list of required upstream-compatible behaviors

### Exit criteria

- We can describe today's service completely without reading code ad hoc.
- We know which current behaviors are mandatory versus merely convenient.

## Phase 1: Extract the wrapper into a private repository

### Objective

Move internal delivery assets out of this fork without changing runtime behavior yet.

### Scope to move

- `idblu_tts_wrapper/`
- `tests/idblu_tts_wrapper/`
- wrapper-specific Docker assets
- wrapper-specific Kubernetes manifests
- wrapper-specific CI/CD workflows
- mounted deploy config files
- deployment and rollback runbooks

### Tasks

- Create a new private repo named `id-blu-tts`.
- Copy the wrapper application code and tests.
- Build a dedicated wrapper image:
  - Python base image
  - `fastapi`
  - `uvicorn`
  - `httpx`
  - any wrapper-only dependencies
- Re-home the wrapper kustomize overlays and workflows there.
- Re-home local deployment and operations documentation there.
- Remove packaging dependence on `pyproject.toml` in this fork for wrapper delivery.

### Notes

The new wrapper image should not vendor the full `vllm-omni` source tree. It should be small and focused on the API gateway behavior.

### Exit criteria

- Wrapper code builds and tests in the private repo.
- Kubernetes manifests can reference a wrapper image independently from the upstream image.

## Phase 2: Externalize custom TTS launch profiles

### Objective

Remove dependency on the fork for runtime configuration that can live outside the image.

### Current fork-owned items to externalize

- `vllm_omni/deploy/qwen3_tts_safe.yaml`
- `vllm_omni/deploy/qwen3_tts_smooth.yaml`
- launch policy embedded in `examples/online_serving/qwen3_tts/run_server.sh`

### Tasks

- Move custom deploy YAMLs into the private `id-blu-tts` repo.
- Standardize on `qwen3_tts_smooth.yaml` for all environments initially.
- Mount the chosen deploy YAML into the upstream container as a file from Kubernetes-managed configuration.
- Replace the current custom startup wrapper with an explicit container command for the stock image.
- Preserve current tunables:
  - deploy config path
  - host/port
  - GPU memory override
  - max instructions length override
  - worker multiprocessing mode

### Agreed direction

The standard upstream image already supports `--deploy-config`, so the target implementation is to run the official image directly with mounted deploy YAML and deployment-level command/args. A thin startup script should be avoided unless a later validation proves it is strictly necessary.

### Exit criteria

- The upstream container can be launched from a standard image using mounted config and deployment-level command/args.
- No fork-owned file is required just to select the TTS profile.

## Phase 3: Convert the pod to a sidecar model

### Objective

Replace the single combined container with two containers in one pod.

### Target pod shape

#### Wrapper container

Responsibilities:

- expose public/internal API on `8080`
- enforce auth
- list and resolve voices
- translate incoming request shape
- forward to upstream on `8091`
- expose `/health` and `/ready`
- run or coordinate warmup gating

#### Upstream container

Responsibilities:

- run standard `vllm-omni` model server
- expose `8091` only inside the pod
- consume mounted deploy profile and shared model cache

### Tasks

- Split the current single-container Deployment into two containers.
- Keep shared mounts:
  - `/cache`
  - `/data/voices`
  - secret mount if still required by the wrapper
- Keep the wrapper as the Service target on `8080`.
- Ensure wrapper readiness still validates:
  - voice assets are present
  - upstream `/health` is good
  - warmup has completed

### Probe design

- `wrapper`:
  - startup probe on `/health`
  - readiness probe on `/ready`
  - liveness probe on `/health`
- `upstream`:
  - startup and liveness can be direct, but traffic should still be gated by wrapper readiness

### Exit criteria

- The external ingress and service contract remain unchanged.
- The wrapper and upstream images can be upgraded independently.

## Phase 4: Rebuild CI/CD around the new repo boundary

### Objective

Move release ownership to the private repo and remove wrapper delivery logic from this fork.

### Tasks

- Recreate staging deploy workflow in the private repo.
- Recreate release and production promotion workflow in the private repo.
- Split image concerns:
  - wrapper image pipeline
  - deployment promotion pipeline
- Pin the upstream image by version tag in deployment manifests.
- Store the upstream image pin in a shared base location with per-environment override capability for migration windows.

### Recommended rules

- Wrapper image tags should be immutable and commit-derived.
- Upstream image is pulled directly from the official registry at deploy time.
- Promotion should not require rebuilding upstream.
- The wrapper remains the only Service and Ingress target; the upstream container remains pod-internal only.

### Exit criteria

- Deploying a wrapper change does not rebuild `vllm-omni`.
- Advancing upstream image versions does not require repackaging wrapper code.

## Phase 5: Reduce or remove the fork

### Objective

Retire this repository after the cutover, with archiving or deletion after the new private repository is established as the source of truth.

### Tasks

- Re-evaluate the remaining diff against `upstream/main`.
- Classify each remaining patch:
  - required functional change
  - observability-only change
  - no longer needed
- Drop logging-only patches unless they are still operationally necessary.
- Confirm that no remaining functional patch is required for production once the official image plus mounted deploy YAML path has been validated.
- Archive or delete this fork after cutover.

### Exit criteria

- the new private repository is the only active delivery repository
- this fork is no longer part of the deployment path
- the fork has been archived or deleted

## Workstreams

## Workstream A: Wrapper extraction

Owner focus:

- repository creation
- dependency isolation
- build and test setup
- Python packaging cleanup

Key outputs:

- private repo `id-blu-tts`
- dedicated wrapper image
- wrapper unit/integration tests
- local deployment and rollback documentation

## Workstream B: Deployment refactor

Owner focus:

- Deployment split
- ConfigMap and secret wiring
- shared volume verification
- readiness and warmup behavior

Key outputs:

- sidecar Deployment manifests
- updated kustomize overlays
- rollout and rollback instructions

## Workstream C: Upstream compatibility validation

Owner focus:

- official image selection
- startup command design
- deploy profile compatibility
- validation of request behavior and streaming output

Key outputs:

- approved upstream image version
- mounted deploy profile strategy
- compatibility test report

## Workstream D: CI/CD migration

Owner focus:

- workflow migration from this fork to the private repo
- image promotion logic
- digest pinning strategy
- environment promotion policy

Key outputs:

- private repo workflows
- updated release documentation
- decommission plan for fork-hosted workflows

## Risks and Mitigations

## Risk 1: Stock upstream image does not reproduce current L4 behavior

Why it matters:

The service currently depends on custom Qwen3-TTS profiles tuned for L4 constraints.

Mitigation:

- validate with mounted custom deploy YAMLs before changing production
- validate specifically against `qwen3_tts_smooth.yaml`
- keep the single-cutover objective, but fail the cutover if the official image cannot satisfy the runtime contract without patching

## Risk 2: Wrapper startup and warmup behavior regress

Why it matters:

The current readiness model intentionally blocks traffic until warmup succeeds.

Mitigation:

- preserve `pod_warmup.py` semantics in the new repo
- keep wrapper-owned `/ready` contract unchanged initially
- canary in staging and verify readiness timing, first-byte latency, and warmup success rates

## Risk 3: Split-container pod introduces hidden dependency issues

Why it matters:

The current single image masks environment and filesystem coupling.

Mitigation:

- explicitly list required shared paths and env vars
- test shared PVC access from both containers
- keep localhost networking within the same pod to avoid additional network dependencies

## Risk 4: CI/CD migration breaks promotion flow

Why it matters:

Current staging/release/production workflows are embedded in this repo.

Mitigation:

- recreate and validate workflows in the private repo before deleting old ones
- run at least one full staging deployment from the new repo before production cutover
- keep rollback instructions and previous manifests available

## Validation Plan

The staging cutover should validate at minimum:

- pod startup succeeds with split containers
- wrapper can reach upstream on localhost
- voice cache is readable by the wrapper
- model cache is reusable by upstream
- `/ready` stays `503` until warmup completes
- speech generation works for the default voice
- speech generation works for explicit `voice_id`
- streaming behavior matches the current service
- first-byte latency is within acceptable range
- rollout and restart behavior remain stable

## Acceptance Criteria

The refactor is complete when all of the following are true:

- Wrapper code is no longer delivered from this fork.
- Production does not require a custom rebuilt `vllm-omni` image for wrapper changes.
- Upstream image version changes can be tested and deployed independently from wrapper code changes.
- The external API contract remains unchanged for clients.
- The fork either disappears or is reduced to a very small, documented patch set.
- The new private repository `id-blu-tts` is the source of truth for code, config, manifests, runbooks, and workflows.
- This fork is archived or deleted after cutover.

## Proposed Execution Order

1. Baseline current production behavior and choose the standard upstream image version tag.
2. Create the private repo `id-blu-tts` and move wrapper code, tests, k8s, mounted deploy profile files, runbooks, and workflows.
3. Externalize `qwen3_tts_smooth.yaml` and launch the official upstream image with mounted file plus deployment-level args.
4. Build a split-container `staging` deployment using the standard upstream image.
5. Validate behavior and performance in `staging`.
6. Promote sequentially to `release`, then `production`.
7. Remove wrapper delivery assets from this fork.
8. Archive or delete the fork after the cutover and source-of-truth transition are complete.

## Recommended Decision

Proceed with a single-cutover sidecar-based extraction into `id-blu-tts`.

This is the preferred path because it removes the operational coupling to the fork without changing the external service contract. The official upstream image is used directly, the custom deploy profile is mounted as configuration, and the private repository becomes the only active source of truth for application code, deployment config, and promotion workflows.
