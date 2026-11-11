
## Post-Reinstall Setup for Wi-Fi & Bluetooth **ASUS PCE-AX3000** (Intel AX200 chipset) 

### **1. Enable Wi-Fi Support**
- Make sure your kernel is version **5.1+**:
  ```bash
  uname -r
  ```
  If older, consider upgrading via backports or using a newer Debian release.

- Install the Intel Wi-Fi firmware:
  ```bash
  sudo apt update
  sudo apt install firmware-iwlwifi
  ```

- Reboot or reload the driver:
  ```bash
  sudo modprobe -r iwlwifi
  sudo modprobe iwlwifi
  ```

---

### 🔗 **2. Get Bluetooth Working**
> The AX200’s Bluetooth runs over a **USB header cable**, so make sure that little cable is plugged into your motherboard!

- Install Bluetooth-related packages:
  ```bash
  sudo apt install bluetooth bluez bluez-firmware
  ```

- Optional but helpful: Prevent USB autosuspend (can cause issues)
  ```bash
  echo 'options btusb enable_autosuspend=0' | sudo tee /etc/modprobe.d/btusb.conf
  ```

- Reboot to apply everything.

---

### 🔧 **3. Troubleshooting Bluetooth (Only If Needed)**
If `bluetoothctl` still says `No default controller available`, try:

- Reinstall firmware:
  ```bash
  sudo apt install firmware-intel-sound
  ```

- Manually reload Bluetooth module:
  ```bash
  sudo modprobe -r btusb
  sudo modprobe btusb
  ```

- Check logs for firmware loading:
  ```bash
  dmesg | grep -iE 'firmware|btusb|hci'
  ```
