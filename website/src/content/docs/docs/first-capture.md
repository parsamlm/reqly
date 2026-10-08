---
title: Capture your first request
description: Start capturing, allow Reqly's helper once, and watch your apps' requests come in.
---

While Reqly captures, it's your Mac's proxy: apps send their requests through it, and Reqly shows each one. When you stop, your network settings come back as they were.

## Start capturing

Do any of these:

- Click **Start Capturing** in the toolbar.
- Choose **Capture › Start Capturing** (⌘R).
- Turn on the switch in Reqly's menu-bar item.

While Reqly captures, the toolbar button reads **Capturing**, with a green dot, and the status bar at the bottom says **Capturing on port 9090**.

## Allow the helper, once

The first time you start capturing, Reqly asks you to allow its helper. The helper is a small program that changes your Mac's proxy settings while Reqly captures, and always puts them back.

1. In the **Allow Reqly to Set Your Proxy** sheet, click **Open System Settings**.
2. In **General › Login Items & Extensions**, turn on **Reqly** under **Allow in the Background**.

Capturing starts as soon as you allow it.

:::note[Your settings always come back]
The helper changes only the HTTP and HTTPS proxy of your Mac's network services. It puts them back when you stop capturing, when you quit Reqly, and even if Reqly quits unexpectedly. If your Mac shuts down while Reqly captures, the helper puts them back when the Mac starts up again.
:::

## Watch requests come in

Open an app or a web page, and its requests appear in the list, each with the app that sent it. HTTPS requests show as **Encrypted connection** until you decrypt their host. See [Decrypt HTTPS](/docs/https/).

Select a request to see its headers, body and timing. See [The request list and details](/docs/requests/).

## Stop capturing

Click **Capturing** in the toolbar, or press ⌘R again. Reqly puts your proxy settings back.

The requests stay in the list until you clear them with **Capture › Clear Traffic** (⌘K), or quit Reqly. Quitting deletes them, unless you [save them as a session](/docs/sessions/).

## Start capturing when Reqly opens

Open **Reqly › Settings…**, and in **General**, turn on **Start capturing when Reqly opens**.

## Apps that don't use the Mac's proxy

Most apps use your Mac's proxy settings, but some command-line tools and apps with networking of their own don't. Point them at Reqly yourself, at `127.0.0.1` and Reqly's port. For example:

```bash
curl -x 127.0.0.1:9090 http://example.com
```

For an app that can't use a proxy at all, use a [reverse proxy](/docs/connections/#reverse-proxies).
