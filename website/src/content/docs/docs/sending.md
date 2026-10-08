---
title: Sending requests
description: Resend a request, edit it first, or write a new one.
---

Requests you send from Reqly are recorded and timed like any other, and your rules act on them too. They show **Reqly** as their app. You can send requests whether or not Reqly is capturing.

## Resend a request

Select a request, and choose **Request › Resend**, or right-click it and choose **Resend**. Reqly sends it again as it was, and selects the new request.

## Edit it first

Choose **Request › Edit and Resend…**. A window opens with the request's method, URL, headers and body, ready to change. Then click **Send** (⌘↩).

## Write a new request

1. Choose **File › New Request** (⌘N).
2. Choose the method, and enter the URL. If you leave out `https://`, Reqly adds it.
3. Click **Add Header** for each header you need. To leave a header out without deleting it, clear its checkbox.
4. Type a body, if the request needs one.
5. Click **Send** (⌘↩).

Reqly sets Host and Content-Length from the URL and the body. The response shows on the right, with the same tabs as in the main window.
