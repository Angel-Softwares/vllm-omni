`idblu_tts_wrapper/k8s` contains a `kustomize` layout for deploying the `idblu-tts` wrapper on EKS with three namespaces:

- `staging`
- `release`
- `production`

Layout:

- `base/`: shared Deployment, Service, Jobs, PVCs, StorageClass, and default runtime config
- `staging/`, `release/`, `production/`: environment overlays with namespace creation and nodegroup pinning

Storage model:

- Model cache (`/cache`): one cross-environment shared EFS-backed PV/PVC. This is intentionally shared so all envs can reuse downloaded model artifacts and reduce cold-start download time.
- Voice cache (`/data/voices`): per-environment EFS-backed PVCs created through dynamic EFS CSI provisioning. This is intentionally isolated by namespace/env because each env syncs a different S3 voice prefix.

Apply an environment:

```bash
kubectl apply -k idblu_tts_wrapper/k8s/staging
kubectl apply -k idblu_tts_wrapper/k8s/release
kubectl apply -k idblu_tts_wrapper/k8s/production
```

CI/CD behavior:

- Pushes to `idblu-tts-*` branches automatically build and deploy the `staging` overlay.
- Manual GitHub Actions runs can deploy `release` or `production`.
- The workflow pushes both a commit-specific image tag and the environment tag consumed by the overlay (`staging`, `release`, or `production`).

Before applying:

1. Install the Secrets Store CSI driver and the AWS provider in the cluster.
2. Install the EFS CSI driver in the cluster.
3. Ensure the EFS CSI driver can access the existing TTS EFS file system `fs-00875f3440f5a7f74` from the EKS worker nodes.
4. Confirm the shared model-cache access point `fsap-0af9d9b5487be6413` exists on that file system.
5. Create an AWS Secrets Manager secret containing JSON keys `IDBLU_TTS_ADMIN_KEY` and `HF_TOKEN`.
6. Review the env-specific patch files for nodegroup, IRSA role ARN, secret name, voice S3 prefix, and image tag.
7. The overlays expect environment tags on the same ECR repository: `:staging`, `:release`, and `:production`. Adjust the image references if your tagging scheme differs.
8. Ensure the IRSA role used by `idblu-eks-tts-runtime` can read the Secrets Manager secret and `s3://voice-agent-audio-registry/<env-prefix>`.

Current env-specific values are defined directly in these patch files:

- `staging/deployment-patch.yaml`
- `staging/serviceaccount-patch.yaml`
- `staging/secretproviderclass-patch.yaml`
- `release/deployment-patch.yaml`
- `release/serviceaccount-patch.yaml`
- `release/secretproviderclass-patch.yaml`
- `production/deployment-patch.yaml`
- `production/serviceaccount-patch.yaml`
- `production/secretproviderclass-patch.yaml`

Render an overlay:

```bash
kubectl kustomize idblu_tts_wrapper/k8s/production
```

Apply an overlay:

```bash
kubectl apply -k idblu_tts_wrapper/k8s/production
```

Operational notes:

- Secrets are sourced from AWS Secrets Manager through `SecretProviderClass` and synced into the pod as the `idblu-tts-secrets` Kubernetes Secret at mount time by the CSI driver.
- The `idblu-eks-tts-runtime` ServiceAccount is intended for IRSA. Each environment overlay should point it at an IAM role that can call `secretsmanager:GetSecretValue` for that environment's secret.
- `staging` uses `angel-idblu-staging-tts-env`. `release` and `production` both use `angel-idblu-tts-prod`.
- All three overlays currently target the shared GPU nodegroup `idblu-eks-shared-gpu` in cluster `idblu-eks-shared`.
- EFS file system: `fs-00875f3440f5a7f74`
- Shared model-cache access point: `fsap-0af9d9b5487be6413`
- Voice assets live on per-environment EFS-backed PVCs and are hydrated from S3 by both a blocking deployment init container and the `idblu-tts-voice-sync` CronJob.
- The voice cache stays env-scoped even though all envs use the same EFS filesystem; dynamic provisioning creates separate PVC-backed paths per namespace.
- Model artifacts under `/cache` live on one fixed cross-environment shared EFS-backed PV/PVC so new pods in any namespace can reuse downloaded model files and reduce cold-start download time.
- The `idblu-tts-warmup` Job waits for the service to become ready and sends a short streaming TTS request to reduce first-request latency.
- The wrapper readiness endpoint (`/ready`) depends on both the upstream vLLM process and the default voice assets being available.
- The Docker image already exposes the wrapper on `8080` and the upstream server on `8091`, so no container change was required for the initial EKS manifest set.
