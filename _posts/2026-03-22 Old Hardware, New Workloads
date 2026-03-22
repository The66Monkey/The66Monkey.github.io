
## **Dual GPUs on a 2016 Z270 Board: Old Hardware, New Workloads**

When I built this system in 2016, NVIDIA was still pushing SLI as the next big thing. I even considered buying a second GTX 970, but the scaling numbers were already questionable and support was fading. So I stuck with one card and moved on.

Ironically, almost a decade later, the machine *does* run two GPUs — just not in any way NVIDIA intended. No SLI bridges, no linked rendering, just two independent cards doing completely different jobs.

---

## **1. Hardware Layout: Three PCIe Slots Used Properly for Once**

The Gigabyte Z270X‑Gaming 5 has three full‑length PCIe slots, which makes this setup straightforward:

- **Top x16:** Intel Arc B580 (Battlemage)  
- **Middle x8:** ASUS GTX 970  
- **Bottom x4:** ASUS PCE‑AX3000 Wi‑Fi card  

The Wi‑Fi card sits in the bottom slot because putting it in the middle slot blocks the Arc’s fan. The Arc gets the top slot for airflow and bandwidth, the 970 sits in the middle without complaint, and everything runs at PCIe Gen3 — which is fine for this workload.

---

## **2. Desktop Stack: Cinnamon Xorg Still Makes the Most Sense**

Linux Mint 22.3 ships with an experimental Cinnamon Wayland session, so I tested it. With mixed GPUs (Intel + NVIDIA), it wasn’t usable:

- Arc acceleration was unreliable  
- Multi‑GPU handling was inconsistent  
- Steam and some GTK apps refused to start  

Switching back to the standard Cinnamon Xorg session fixed everything immediately. Arc handles the desktop and games, the 970 stays available in the background, and the system behaves predictably.

---

## **3. Using the GTX 970 for Local AI (InvokeAI)**

The main reason for keeping the 970 installed is simple: CUDA.

InvokeAI detects the NVIDIA card and uses it for model inference:

```
[InvokeAI]::INFO --> Using torch device: NVIDIA GeForce GTX 970
...
VRAM in use: ~3.0G
```

The Arc stays free for desktop rendering and Vulkan workloads, while the 970 becomes a dedicated AI accelerator. With only 4 GB VRAM it’s not fast — roughly 10 minutes for a 30‑step SDXL run — but it works reliably and keeps the system responsive.

This is a better use of an old GPU than letting it sit in a drawer.

---

## **4. LM Studio: Not There Yet on This Setup**

I also tried running LM Studio, but it wasn’t stable on this configuration. Even under Xorg, it consistently crashed during startup or model load. We tested different backends, toggled GPU settings, and tried both GPUs, but nothing made it usable.

Right now LM Studio simply doesn’t behave well on this mixed‑GPU, older‑platform setup. It might improve with future updates, but at the moment it’s not an option here.

---

## **5. Why This Setup Still Makes Sense**

- A 2016 motherboard can still run a modern Intel GPU and a legacy NVIDIA card at the same time  
- Cinnamon Xorg remains the stable option for mixed‑vendor, dual‑GPU setups  
- The GTX 970 is still useful as a CUDA device for local AI workloads  
- LM Studio isn’t stable yet, but InvokeAI works reliably  
- Reusing old hardware for specific tasks is more satisfying than replacing everything  

It’s not a modern build, but it does exactly what I need: Arc for the desktop, 970 for AI, and a Z270 board quietly holding the whole thing together.
