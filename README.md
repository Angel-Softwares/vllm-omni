# vLLM-Omni Qwen3 TTS L4 Adaptation

This repository is an adaptation of [vllm-project/vllm-omni](https://github.com/vllm-project/vllm-omni), focused on making the Qwen3 TTS / audio generation code run on NVIDIA L4 GPUs.

The original vLLM-Omni project provides omni-modality model serving for text, image, video, and audio models. This fork keeps the upstream project structure, but includes changes aimed at reducing GPU memory pressure and improving compatibility with L4-class hardware.

## Purpose of this fork

The main goal of this repository is to adapt the Qwen3 TTS serving path so it can run on NVIDIA L4 GPUs, which have less VRAM than higher-end inference GPUs such as A100, H100, or L40S.

This fork is intended for:

- running Qwen3 TTS experiments on L4 GPUs
- testing memory-aware serving changes
- deploying lower-cost TTS inference workloads
- keeping a reproducible version of the modifications made on top of vLLM-Omni

## Main changes

This branch includes changes related to:

- adapting the Qwen3 TTS code path for L4 GPU constraints
- reducing memory usage during model loading and inference
- adjusting runtime configuration for smaller GPU memory budgets
- improving compatibility with single-L4 deployments
- keeping the code close to upstream vLLM-Omni where possible

More detailed implementation notes should be added here as the changes stabilize.

## Target hardware

This adaptation targets:

```text
GPU: NVIDIA L4
VRAM: 24 GB
Use case: Qwen3 TTS / audio generation inference