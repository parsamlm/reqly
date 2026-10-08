---
title: Connections
description: Use an upstream proxy, reverse proxies and client certificates.
---

Each of these has a pane of its own in **Reqly › Settings…**.

## Upstream proxy

For networks that reach the internet only through another proxy, as many offices do.

1. In Settings, choose **Upstream Proxy**, and turn on **Use an upstream proxy**.
2. Enter its **Server** and **Port**, and a **User name** and **Password** if it asks for them.
3. Under **Reach Directly**, list the hosts that shouldn't go through it, separated by commas, spaces or new lines. Patterns such as `*.corp.example.com` work. **Addresses on the local network** are reached directly too, unless you turn that off. Your Mac itself always is.
4. Click **Apply**.

Reqly works with HTTP proxies, with or without a user name and password, and keeps the password in your Keychain. While Reqly captures, the status bar shows **Via** and the proxy's address. A request's **Overview** shows the upstream proxy it went through.

## Reverse proxies

For apps that can't use a proxy. You point the app at a local address, such as `http://localhost:8080`, and Reqly sends every request it gets there on to one server, and records it.

1. In Settings, choose **Reverse Proxy**, and click **+**.
2. Enter a **Local port**, and the **Server** the requests go to, such as `https://api.example.com`.
3. Click **Add**.
4. Point the app at `http://localhost` and the port you chose.

Reverse proxies listen only while Reqly captures, and only your Mac can reach them. When the server's address starts with `https://`, Reqly connects to it over HTTPS. **Keep redirects on this address**, which is on to begin with, points the server's redirects back at the local address, so the app keeps going through Reqly.

## Client certificates

For servers that ask apps to identify themselves with a certificate.

1. In Settings, choose **Client Certificates**, and click **+**.
2. Enter the **Hosts** to present it to, such as `api.example.com`. `*.example.com` covers the subdomains of example.com, but not example.com itself.
3. Click **Choose…**, and pick the certificate: a `.p12` or `.pfx` file, as Keychain Access exports, or PEM files with the certificate and its private key. If the file is locked, enter its **Password**.
4. Click **Add**.

Reqly keeps certificates and their private keys in your Keychain. It doesn't keep the file's password.

Reqly presents a certificate where it makes the secure connection itself: for hosts it decrypts, for reverse proxies to `https://` servers, and for requests you send from Reqly. If a server asks for a certificate that Reqly doesn't have, the request says so.
