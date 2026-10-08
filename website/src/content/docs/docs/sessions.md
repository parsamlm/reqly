---
title: Sessions and sharing
description: Save a session and open it later, export and open HAR files, and copy requests as cURL.
---

Reqly keeps captured traffic only while it runs: quitting deletes it. To keep it, save it as a session.

## Save a session

Choose **File › Save Session…** (⌘S). Reqly saves everything in the window, not only what the filters show, into one `.reqly` file, with every body and your pins, colors and comments. Capturing goes on while it saves.

Before you share a session, turn on **Hide authorization headers and cookies**. Their values are then saved as "(hidden)". Bodies aren't changed, so they can still hold personal data.

## Open a session or a HAR file

Choose **File › Open…** (⌘O), or double-click the file in Finder. Each file opens in a window of its own, with the same tools as the main window, apart from capturing. Reqly works on a copy, so the file itself doesn't change.

## Export as HAR

HAR files open in browsers' developer tools, and in many other tools.

1. Choose **File › Export as HAR…** (⇧⌘E), or right-click a request and choose **Export as HAR…**.
2. Choose **Selected request**, or **All requests in this list**, as filtered and searched.
3. Choose whether to **Include response bodies**, and whether to **Hide authorization headers and cookies**. Hiding them is on to begin with.
4. Click **Export…**.

Encrypted connections are left out, since their requests can't be read. WebSocket messages are included.

## Copy a request

From the **Request** menu, or a request's right-click menu:

- **Copy URL** (⇧⌘C).
- **Copy as cURL** (⌥⌘C): a `curl` command that sends the same request. It includes authorization headers and cookies as they are, so check it before you share it.
- **Copy Response Body**, unpacked. Images copy as images.

In a request's details, you can also copy its headers, its body, the raw request or response, and a single value from the tree view.
