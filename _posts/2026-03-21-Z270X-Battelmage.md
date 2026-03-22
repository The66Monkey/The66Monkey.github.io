## **The trials and tribulations of upgrading an old computer with Battlemage**

Getting Intel’s new Battlemage GPU running smoothly on Linux turned out to be a mix of firmware archaeology, and a few strange quirks.

---

## **1. Motherboard Configuration: Making an Older Platform Accept a New GPU**

This machine started life as a 2016 self built gaming build, and like many aging PCs, it’s been through a long series of upgrades, sidegrades, and questionable decisions.
The original build specs were these:

- Kingston HyperX Fury 120GB SSD (SHFS37A/120G)
- Seagate Barracuda 3TB (64MB / 7200RPM) (ST3000DM001)
- Corsair Obsidian 750D Tower
- Corsair CX 750M / 750W / 80+ Bronze
- Corsair Vengeance LPX Red 16GB (2x8GB) / 3200MHz / DDR4 / CL16 / CMK16GX4M2B3200C16R
- ASUS GeForce GTX 970 4GB TURBO OC (TURBO-GTX970-OC-4GD5)
- Intel Core i7-6700K - 8 thread / 4,0GHz (4,2 Ghz Turbo) / 8MB / Socket 1151 (with a old noctua cooler, from 2012 or so)

During it's life it has hosted a number of different HDD's, a sidegrade to a 1060 gtx 3gb GPU, and a Kingston NV2 M.2 1TB ssd.
I also upgraded it with a ASUS PCE-AX3000 wifi card, getting that fucker to work is listed in another post.

### **BIOS and MB**

The latest BIOS realeased for the system Mar 9, 2018, version F10b and I had updated to that by the end of 2018. But i haven't messed with it much when it comes to settings since then
- **Set PCIe slot to Gen3 manually**  
  The board can’t negotiate Gen4/Gen5 properly with Battlemage, so forcing Gen3 avoids link‑training failures.
  The setting was under M.I.S.C or something like that because i think this was an update pushed in one of the later bios versions and not originally there.
- **Disable CSM (Compatibility Support Module)**  
  Ensures the GPU boots in pure UEFI mode, which Battlemage expects.
  This bastard fucked me up because I had installed my old Debian OS in legacy and because of this i had to reinstall the OS.
  Luckily with Ventoy and a glut of choices i decided to go with Linux Mint now, so far so good.

---

## **2. Linux Setup: Drivers, Mesa, and the Unexpected VAAPI Crash**

On Linux Mint (Ubuntu 24.04 base), the Mesa stack already supports Battlemage well. 3D acceleration, Vulkan, desktop compositing — all of that worked immediately.

### **What worked out of the box**
- Mesa recognized the GPU
- Vulkan worked
- Desktop animations were smooth
- Games launched normally (Running Heroic Game Launcher)
- Browsers behaved fine

### **What *didn’t* work**
VLC and Celluloid (mpv) **crashed instantly** on video playback.

Terminal output showed:

```
libva info: Trying to open ... iHD_drv_video.so
Bus error (core dumped)
```

This revealed the real culprit:

### **Battlemage’s VAAPI driver (iHD) is unstable on Ubuntu/Mint right now.**

VLC loads VAAPI **before** it reads user preferences, so even disabling hardware decoding didn’t help. The crash happened too early in the startup sequence.

---

## **3. The Fix: Block VAAPI Only for VLC**

Instead of ripping out drivers or modifying the system, the cleanest solution was to block VAAPI **only for VLC**, using an environment variable.

### **The wrapper script**
I created:

```
~/bin/vlc-no-vaapi
```

with:

```
#!/bin/bash
LIBVA_DRIVER_NAME=none exec /usr/bin/vlc "$@"
```

This prevents VLC from loading the unstable VAAPI driver, while leaving the rest of the system untouched.

### **Desktop shortcut**
To make it convenient, I added a `.desktop` launcher pointing to the script:

```
[Desktop Entry]
Type=Application
Name=VLC (No VAAPI)
Exec=/home/the66monkey/bin/vlc-no-vaapi
Icon=vlc
Terminal=false
Categories=AudioVideo;Player;Video;
```

Now VLC launches normally from the desktop, without crashes.

### **Result**
- VLC works perfectly  
- The rest of the GPU stack remains fully accelerated  

---

## **4. GravityMark 1440p Results (Linux Vulkan):**

GravityMark 1440p Results (Linux Vulkan):

  Vulkan: 122.5 FPS  
  - Shows the Xe2 Vulkan driver is mature and fast on Linux.
  - No PCIe bottleneck, no thermal throttling, GPU fully utilized.

  Vulkan Ray Tracing: 38.2 FPS  
  - This is limited mostly by the i7‑6700K + Z270 platform, not the GPU.
  - RT workloads depend heavily on modern CPU IPC, memory bandwidth, and BVH traversal performance.
  - Battlemage’s RT path is still early in Mesa, so some overhead is expected.

Summary:  
Battlemage delivers excellent Vulkan performance on Linux Mint.
Ray tracing works, but on a 2015 CPU + Z270 board, the GPU can’t stretch its legs fully. On a modern platform, the RT score would climb significantly.

---

## **5. Lessons Learned**

- ca 2017 seems to be the oldest components you can reliably update to a mid range PC these days, and even so the MB does not support some features one might want to utilize.
- There are still the normal Linux tinkering needed, however compared to the work needed to get Nvidia cards to work I still feel good about the move to Intel GPU. Intel’s open driver stack is still the least painful option on Linux, especially compared to NVIDIA’s DKMS roulette.
- The VAAPI crash issue might disappear once Intel stabilizes the media stack for Xe2, but we never know how commited they are to supporting the card, especially for the Linux community. And fixing it on a fundamental level is beoynd me.... for now!
