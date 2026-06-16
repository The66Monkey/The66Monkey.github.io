# USB Linux: your system, in your pocket!

I needed a Linux environment for my laptop that didn’t touch my main drive and didn’t forget everything every reboot. That shouldn’t be a big ask in 2026, but here we are.
Live USBs exist. They’re great for troubleshooting, but not something you actually want to use daily. Persistence can help, but getting it to behave reliably is more work than it’s worth. I want my browser set up, my plugins in place, the right keyboard layout, dark mode, WiFi — the basics. Doing that every boot gets old fast.

So I went with a full install instead. Not on a fancy SSD-in-a-stick — just an old SanDisk Cruzer Blade. The kind of device you don’t trust with anything important. It works, but it’s slow. Not benchmark slow, not theoretical slow — real “why is my terminal thinking about this” slow. The laptop itself is fine, so the problem clearly wasn’t the whole system.
A standard Linux install assumes storage is reasonably fast. It writes logs, updates access times, swaps memory to disk, and constantly touches the filesystem. On an NVMe drive, that’s fine. On a USB stick, it isn’t. Cheap flash also doesn’t fail gracefully — it wears out. I’ve already had two drives die, one locking itself into read-only mode with no warning. At that point the goal becomes obvious: reduce writes as much as possible.

The first step was removing disk swap. The system had a swap file, so I disabled it, removed it from `/etc/fstab`, and deleted it. In its place I used zram, which provides compressed swap in RAM. Same purpose, but without hitting the disk. That alone removes one of the worst slowdowns.

Next was `/tmp`. A lot of programs use it constantly for temporary data, and on slow storage that adds up. Moving it into RAM with:

```
tmpfs /tmp tmpfs defaults,noatime,size=4G 0 0
```

means those operations never touch the USB at all. It’s not flashy, but it makes the system feel much smoother.

The rest was small but important adjustments: using `noatime` to stop updating file access timestamps, and adding `commit=60` to batch writes instead of constantly syncing them. That reduces background disk activity significantly. The tradeoff is you can lose up to a minute of data in a crash, which for this kind of use is acceptable.

The result is a full Linux system running from a cheap USB stick that’s actually usable. It boots, it remembers everything, and once it’s up it behaves like a normal machine instead of fighting the storage.

After trying a few options, I ended up using MX Linux. Mint works well, but it felt heavier than needed for this setup. MX is a better fit for slow storage — it still gives you a full desktop, but with less overhead and fewer background tasks. It boots quicker, writes less, and stays closer to what the hardware can handle. At the same time it’s still Debian-based, so everything is familiar.
This turned out to be a surprisingly comfortable system given the constraints. Running a full install from a USB drive is niche, but it’s also something Linux handles extremely well. You can control memory usage, disk behavior, and make the system adapt to hardware in a way that simply isn’t possible on Windows or macOS.

There probably should be a proper “USB install” profile at some point. Not because this is difficult, but because the capabilities are already there — they’re just not presented as a standard option.
