---
title: Simulators and emulators
description: Capture iOS Simulators and Android emulators, HTTPS included.
---

## iOS Simulators

Simulators use your Mac's network settings, so their traffic shows up while Reqly captures. To see their HTTPS traffic, install Reqly's certificate in each one:

1. Start the simulator, from Xcode or the Simulator app.
2. Choose **Capture › Devices…** (⇧⌘D), and select **Simulators**.
3. Next to the simulator, click **Install Certificate**.

Reqly needs Xcode for this, and HTTPS has to be [set up](/docs/https/) first. After you make a new certificate, install it again.

A simulator's requests are labeled with its name, and with the apps inside it that sent them.

## Android emulators

Reqly points emulators at itself with adb, which comes with Android Studio or the Android SDK Platform Tools.

1. Start the emulator, from Android Studio's Device Manager.
2. Start capturing.
3. Choose **Capture › Devices…**, select **Android Emulators**, and click **Use Reqly** next to the emulator.

To see its HTTPS traffic:

1. Click **Copy Certificate**. Reqly copies **Reqly CA.crt** to the emulator's Downloads, and opens its security settings.
2. There, choose **Encryption & credentials › Install a certificate › CA certificate**, then pick **Reqly CA**. On recent versions of Android, that page is called **Security & privacy**, and **Encryption & credentials** is under **More security & privacy**.

:::caution[Android apps and certificates]
On Android 7 and later, apps trust a certificate you install only if they opt in. Debug builds of your own apps can.
:::

When you're done, click **Stop Using Reqly**. Reqly doesn't change the emulator's proxy back on its own, so an emulator left pointing at Reqly can't reach the internet while Reqly isn't capturing.

An emulator's requests are labeled with its name. While more than one emulator is running, the requests they send over Wi-Fi are labeled **Android Emulator** instead.

### If Reqly can't find adb

Reqly looks for adb in your Android SDK, at `$ANDROID_HOME`, `$ANDROID_SDK_ROOT` or `~/Library/Android/sdk`, and then in Homebrew's folders. Install Android Studio, or the Android SDK Platform Tools, then reopen Reqly.

Phones and tablets connected by USB aren't listed here. Connect them over [Wi-Fi](/docs/phones/) instead.
