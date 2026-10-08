---
title: Install Reqly
description: Download Reqly or install it with Homebrew, and open it for the first time.
---

Reqly runs on macOS 26 or later.

## Download it

1. Download Reqly from [reqly.net](https://reqly.net), or from its [releases on GitHub](https://github.com/parsamlm/reqly/releases).
2. Open the zip file, and drag **Reqly** to your **Applications** folder.
3. Open Reqly.

Reqly is signed and notarized, so macOS opens it like any other app.

## Or install it with Homebrew

```bash
brew install --cask parsamlm/reqly/reqly
```

## The first time Reqly opens

The **Welcome to Reqly** window walks you through three steps. You can do them in any order:

1. **Capture your Mac's traffic.** Click **Start Capturing**. See [Capture your first request](/docs/first-capture/).
2. **Install the Reqly certificate.** Click **Install Certificate…**, so Reqly can read HTTPS traffic. See [Decrypt HTTPS](/docs/https/).
3. **Choose hosts to decrypt.** Click **Choose Hosts…** to pick the hosts Reqly decrypts.

Each step shows a check mark once it's done. Click **Skip for Now** to do the rest later. To open the window again, choose **Help › Welcome to Reqly**.

## Updates

Reqly looks for a newer version once a day, and installs it when you agree. To check yourself, choose **Reqly › Check for Updates…**.

To stop the daily check, open **Reqly › Settings…** (⌘,), and in **General**, turn off **Check for updates automatically**.
