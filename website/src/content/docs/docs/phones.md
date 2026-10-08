---
title: Phones and tablets
description: Send an iPhone's, iPad's or Android device's traffic through Reqly over Wi-Fi.
---

A phone or tablet on the same Wi-Fi as your Mac can send its traffic through Reqly. Its requests show up next to your Mac's, each labeled with the device.

## Let devices connect

1. Choose **Capture › Devices…** (⇧⌘D). The Devices window opens on **Phones and Tablets**.
2. Turn on **Allow Devices on This Network**.
3. Start capturing, if Reqly isn't already. Devices can connect only while Reqly captures.

When you turn the switch off again, devices that are connected are disconnected.

:::note
The first time a device connects, macOS may ask whether Reqly can accept incoming network connections. Choose **Allow**, or devices can't reach it.
:::

## Set up the device

Under **Set Up a Device**, Reqly shows a QR code and an address, such as `http://192.168.1.125:9090/`. On the device, scan the code with the camera, or open the address in its browser. The page that opens has Reqly's certificate and the steps for the device. To see HTTPS traffic, [set up HTTPS](/docs/https/) on the Mac first.

### iPhone and iPad

1. Tap **Download the Certificate**, then **Allow**.
2. In Settings, tap **Profile Downloaded**, then **Install**.
3. In **Settings › General › About › Certificate Trust Settings**, turn on Reqly's certificate. Its name starts with **Reqly CA**.
4. In **Settings › Wi-Fi**, tap ⓘ next to your network, then **Configure Proxy › Manual**. Enter the server and port that Reqly shows under **Proxy Settings**.

### Android

1. Tap **Download the Certificate**.
2. In Settings, search for **CA certificate**, and install the file you downloaded.
3. In your Wi-Fi network's settings, set **Proxy** to **Manual**, with the host and port that Reqly shows.

:::caution[Android apps and certificates]
On Android 7 and later, apps trust a certificate you install only if they opt in. Debug builds of your own apps can. Other apps' HTTPS requests fail while Reqly decrypts their hosts.
:::

When you're done, set the device's proxy back to **Off**.

## Let a device in

Reqly asks before it lets a new device in. The first time a device connects, Reqly asks **Let this device use Reqly?**, with the device's address. Give it a name if you like, then choose **Allow**. If the device isn't yours, choose **Don't Allow**.

While a device waits, Reqly's Dock icon shows how many are waiting, and the Devices window lists them under **Waiting for You**.

Reqly remembers the devices you let in, and lets them in again on their own, even when their address changes. They're listed under **Devices You Let In**. **Forget** stops letting a device in: Reqly asks again the next time it connects. A device you don't allow is asked about again after Reqly restarts.

## See a device's traffic

- In the sidebar, **Devices** lists **This Mac** and each device, with its apps and hosts under it. To rename a device, right-click it and choose **Rename…**.
- In the request list, the **App** column shows the device when Reqly can't tell the app.
- In **Filters**, choose a device under **Device**.
- A request's **Overview** has a **Device** row.

## After you make a new certificate

A device that trusted an earlier Reqly certificate rejects the new one, and its HTTPS requests fail. Open the setup page on the device again, install the new certificate, and trust it. On iPhone and iPad, remove the earlier profile in **Settings › General › VPN & Device Management**.
