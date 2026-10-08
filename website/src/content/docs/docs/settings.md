---
title: Settings
description: What each pane of Reqly's settings does.
---

Open **Reqly › Settings…** (⌘,).

## General

**Capturing**

- **Proxy port:** the port Reqly listens on, 9090 to begin with. Change it if another app uses that port. It takes a number from 1024 to 65535, and applies the next time you start capturing. Click **Restart Capturing** to apply it now.
- **Start capturing when Reqly opens.**
- **Show Reqly in the menu bar:** a menu-bar item with a switch to start and stop capturing, the newest request, and switches for breakpoints and slow network.

**Your network settings**

- **Always restored:** Reqly puts your proxy settings back when you stop capturing, even if it quits unexpectedly.
- **Reqly's helper:** sets your proxy while Reqly captures. **Remove Helper…** removes it from your Mac, and Reqly sets it up again the next time you start capturing. Stop capturing first.

**Updates**

- **Check for updates automatically:** once a day. **Check Now** checks right away.

## HTTPS

Reqly's certificate, and the hosts it decrypts. See [Decrypt HTTPS](/docs/https/).

## Upstream Proxy, Reverse Proxy and Client Certificates

See [Connections](/docs/connections/).

## Protobuf

Your `.proto` files. See [Protocols](/docs/protocols/#grpc-and-protobuf).

## Elsewhere

- Whether phones and tablets can connect is in the Devices window: **Capture › Devices…**. See [Phones and tablets](/docs/phones/).
- Rules are in the Rules window: **Rules › Show Rules**. See [Rules](/docs/rules/).
