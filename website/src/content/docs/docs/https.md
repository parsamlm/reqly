---
title: Decrypt HTTPS
description: Install Reqly's certificate, and choose the hosts Reqly decrypts.
---

Most traffic is HTTPS, which is encrypted. To show what's inside, Reqly creates its own certificate on your Mac, and macOS trusts it for your user account. Reqly then decrypts only the hosts you choose. Everything else passes through untouched.

## Install the certificate

1. Choose **Capture › Decrypt HTTPS…**. Settings opens on **HTTPS**.
2. Click **Install Certificate…**.
3. Enter your password when macOS asks.

Settings then says **The Reqly certificate is installed and trusted**. Its name is **Reqly CA**, followed by the date and time it was made, and it never leaves your Mac. To find it in your keychain, click **Show in Keychain Access**.

If you cancel the password prompt, the certificate is made but not trusted, and Reqly decrypts nothing. Click **Trust Certificate…** to try again.

## Choose the hosts to decrypt

In **Settings › HTTPS**, under **Decrypt HTTPS for these hosts**:

1. Click **+**.
2. Type a host, such as `api.example.com`, or `*.example.com` for its subdomains.
3. Press Return.

Each host has a switch of its own, so you can stop decrypting it without removing it. To remove a host, select it and press Delete, or click **−**.

You can also decide from the request list. Right-click an encrypted request, and choose **Decrypt** followed by its host. Its next requests show up decrypted. **Stop Decrypting** does the opposite.

### How hosts match

- `*.example.com` matches the subdomains of example.com, such as `api.example.com`, but not `example.com` itself. Add both if you need both.
- The most specific entry wins. An exact host beats a wildcard, and a longer wildcard beats a shorter one. So you can decrypt `*.example.com` but switch off `ads.example.com`.

## Decrypt all hosts

**Decrypt all hosts** decrypts every host except the ones you switch off in the list. It isn't recommended: some apps stop working when their traffic is decrypted.

## Apps that accept only their own certificate

Some apps accept only their own certificate, and their requests fail when Reqly decrypts them. Such a request shows as **Failed**, and its details say the app didn't accept Reqly's certificate. Stop decrypting the host, and its traffic passes through encrypted again.

## Remove the certificate

In **Settings › HTTPS**, click **Remove Certificate…**, then **Remove Certificate**, and enter your password. Reqly stops decrypting, and removes its certificates from your keychain, older ones included.

You can set up HTTPS again at any time. Reqly then makes a new certificate, which phones, tablets and simulators need to install again.
