---
title: Uninstall Reqly
description: Remove Reqly, its helper, its certificate and its data from your Mac and your devices.
---

## On your Mac

1. Stop capturing.
2. Remove the helper: in **Reqly › Settings… › General**, click **Remove Helper…**, then **Remove Helper**.
3. Remove the certificate: in **Settings › HTTPS**, click **Remove Certificate…**, then **Remove Certificate**, and enter your password.
4. Quit Reqly, and drag it from **Applications** to the Trash.

If you installed Reqly with Homebrew, remove the helper and the certificate first, then run:

```bash
brew uninstall --zap --cask reqly
```

### Reqly's data

These stay on your Mac until you delete them:

- `~/Library/Application Support/Reqly`: your rules, connections, devices and the list of `.proto` files.
- `~/Library/Preferences/net.reqly.Reqly.plist`: your settings.
- In your keychain, if you used them: **Reqly Upstream Proxy**, the upstream proxy's password, and one **Reqly Client Certificate** item for each client certificate. Delete them in Keychain Access.

Homebrew's `--zap` deletes the folder and the settings, but not the keychain items.

## On your devices

- **iPhone and iPad:** remove Reqly's profile in **Settings › General › VPN & Device Management**, and set the Wi-Fi network's proxy back to **Off**.
- **Android:** remove Reqly's certificate in its security settings, and set the Wi-Fi network's proxy back to **None**.
- **Android emulators:** in the Devices window, click **Stop Using Reqly** before you remove Reqly.
