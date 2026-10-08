---
title: Troubleshooting
description: What to do when capturing doesn't start, requests don't show up, or HTTPS requests fail.
---

## Capturing doesn't start

**"Waiting for you to allow Reqly's helper…"**
Reqly needs its helper to set your proxy. In System Settings, open **General › Login Items & Extensions**, and turn on **Reqly** under **Allow in the Background**. Capturing starts as soon as you do.

**"Port 9090 is in use by another app."**
Another app listens on Reqly's port. In **Settings › General**, choose another **Proxy port**, then start capturing again.

**"Reqly couldn't reach its helper."**
Try again. If it keeps happening, stop capturing, click **Remove Helper…** in **Settings › General**, and start capturing again. macOS may ask you to allow the helper again.

**"Reqly's helper is missing from the app."**
Your copy of Reqly is incomplete. [Download it again](/docs/install/).

## An app's requests don't show up

- Check that Reqly is capturing. The status bar says **Capturing on port** and the port.
- Some apps, such as command-line tools, don't use the Mac's proxy settings. Point them at Reqly yourself, at `127.0.0.1` and Reqly's port, or use a [reverse proxy](/docs/connections/#reverse-proxies).
- A request that shows as **Encrypted connection** passes through without Reqly reading it. [Decrypt its host](/docs/https/) to see inside.

## HTTPS requests fail

While Reqly decrypts a host, a request can fail because the app didn't accept Reqly's certificate:

- **The Mac, phone or simulator doesn't trust Reqly's current certificate,** for example after you made a new one. Install it again: see [Phones and tablets](/docs/phones/#after-you-make-a-new-certificate) and [Simulators and emulators](/docs/simulators/).
- **The app accepts only its own certificate.** Stop decrypting its host: right-click the request, and choose **Stop Decrypting** followed by the host. Its traffic then passes through encrypted.
- **On Android 7 and later,** apps trust a certificate you installed only if they opt in. Debug builds of your own apps can.

**"The server's certificate isn't valid, so Reqly didn't send the request."**
Your Mac doesn't trust the certificate the server sent. If it's your own server, with a certificate of its own, make your Mac trust that certificate in Keychain Access.

**"The server asked for a client certificate, and Reqly has none for this host."**
Add the certificate in **Settings › Client Certificates**. See [Connections](/docs/connections/#client-certificates).

## Devices can't connect

- In the Devices window (⇧⌘D), check that **Allow Devices on This Network** is on, and that Reqly is capturing.
- The device has to be on the same network as the Mac.
- If macOS asked whether Reqly can accept incoming network connections, the answer has to be **Allow**. You can change it in **System Settings › Network › Firewall**.
- **"Another app uses port 9090 on the network, so devices can't connect."** Choose another **Proxy port** in **Settings › General**.

## Your proxy settings stayed on

Reqly's helper puts your proxy settings back when Reqly stops capturing, quits or crashes. If Reqly says **Reqly couldn't put your proxy settings back**, quit Reqly, and its helper puts them back.

## Report a problem

Choose **Help › Report a Problem…** to open an issue on GitHub, with your versions of Reqly and macOS filled in.

If Reqly quits unexpectedly, it offers to report it the next time it opens. Reqly opens the issue in your browser for you to read, change and submit. Nothing is sent until you do.
