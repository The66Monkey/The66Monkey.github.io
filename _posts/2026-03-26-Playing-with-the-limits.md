## DeepSeek on Battlemage Through VS Codium

Running DeepSeek locally inside VS Codium made sense for one simple reason: it removes token limits, avoids external dependencies, and paired with a de‑telemetrized editor like Codium, it provides a fully offline coding assistant with none of the usual data collection overhead.

## Reassigning GPU Roles to Fit a Larger Model

Before integrating DeepSeek into VS Codium, the system was running in a different configuration. The Intel Arc B580 originally handled the desktop, while the GTX 970 was reserved for CUDA workloads. This made sense for smaller models and for tools like InvokeAI, which automatically detect and prefer CUDA devices. The Arc stayed free for Vulkan applications and general desktop rendering, and the 970 handled the AI tasks.

That arrangement stopped working once the model size increased. DeepSeek‑Coder‑V2‑Lite requires roughly nine to ten gigabytes of VRAM for full offload, plus additional space for runtime buffers and the KV cache. The Arc B580 is a 12 GB card on paper, but with the desktop running on it, nearly two gigabytes were permanently occupied by the display stack. That left too little headroom for the model to load reliably.

## 1. Reversing the GPU Roles

To free the Arc’s VRAM, the display output had to be moved to the GTX 970. Under Xorg this is straightforward: the NVIDIA card becomes the primary display device, and the Arc is left completely idle until a Vulkan workload is launched. Once the desktop was running on the 970, the Arc reported roughly 10.5 GB of free VRAM, which is just enough for DeepSeek‑Coder‑V2‑Lite in Q4_K_M format.

This change was the turning point. With the display stack off the Arc, the model could finally load without falling back to CPU or failing during initialization.

## 2. Forcing Vulkan to Target the Arc

With two GPUs present, Vulkan does not always select the correct device automatically. KoboldCpp in particular tends to prefer CUDA if it detects an NVIDIA card, even if Vulkan is requested. To avoid this, the Intel ICD file was explicitly exported:

```
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/intel_icd.json
```

This ensures that Vulkan compute work is routed to the Arc B580 rather than the GTX 970.

## 3. Launching DeepSeek with the Required Flags

Once the ICD was set, the model could be launched through KoboldCpp:

```
koboldcpp-linux-x64 \
  --model /path/to/DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf \
  --usevulkan \
  --gpulayers 999 \
  --contextsize 4096
```

Each flag serves a specific purpose.

usevulkan  
Forces the Vulkan backend and prevents accidental fallback to CUDA or CPU.

gpulayers 999  
Requests full layer offload. On the Arc B580, this results in complete GPU execution.

contextsize 4096  
Keeps the KV cache within the available VRAM budget. Larger values risk exhausting memory during longer completions.

With these flags, the model loads entirely on the Arc and remains stable during extended coding sessions.

## 4. Integrating Continue in VS Codium

KoboldCpp exposes an OpenAI‑compatible API on port 5001. Continue can use this directly without modification.

In Continue’s settings:

Provider: OpenAI Compatible  
Endpoint:  
```
http://localhost:5001/v1
```
Model name: deepseek  
API key: (empty)

Once configured, Continue sends all requests to the local DeepSeek instance. Code explanations, refactoring, and inline completions all run through the Arc GPU without involving cloud services.

## 5. Why the Reconfiguration Was Necessary

The initial layout worked for smaller models, but DeepSeek‑Coder‑V2‑Lite needed nearly the entire VRAM budget of the Arc. The display stack alone consumed close to two gigabytes, leaving too little room for the model and its runtime buffers. Moving the desktop to the GTX 970 freed the Arc completely, allowing the model to load and run as intended.

The end result is a mixed‑GPU system where each card has a clear role: the GTX 970 drives the desktop, and the Arc B580 handles all Vulkan‑based LLM workloads. This configuration allows a 2016 platform to run a modern coding model inside VS Codium with no external dependencies.
