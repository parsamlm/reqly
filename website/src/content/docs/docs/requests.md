---
title: The request list and details
description: "Find your way around the main window: the sidebar, the request list, search, filters, and each request's details."
---

Reqly's main window has three parts: the sidebar on the left, the request list in the middle, and the selected request's details on the right.

## The sidebar

- **All Traffic** shows every request.
- **Pinned** appears once you pin a request. See [Mark what matters](#mark-what-matters).
- **Apps** lists each app or tool that sent requests, with its icon. Once phones, simulators or emulators send traffic too, **Devices** takes its place. It lists **This Mac** and each device, with their apps under them, and the hosts of requests Reqly couldn't credit to an app.
- **Hosts** lists every host your apps talked to.

Select a row to see only its requests. Each section folds away with the arrow next to its name. To fold a device away, use its arrow, or press ← and →.

## The request list

Requests appear in the order they were made. While the list is scrolled to the bottom, it follows new ones.

| Column | What it shows |
|---|---|
| **Status** | The status code, with a colored dot. |
| **Method** | GET, POST and so on. |
| **Request** | The host, then the path and query. |
| **App** | The app or tool that sent it, or the device when Reqly can't tell the app. |
| **Time** | When it started. |
| **Duration** | How long it took. |
| **Size** | How much was received. |

The dot next to the status code:

- **Teal:** success (2xx).
- **Blue:** redirect (3xx).
- **Orange:** client error (4xx).
- **Red:** server error (5xx).
- **Gray:** informational (1xx), such as a WebSocket connection's 101.

For gRPC calls, the dot follows the gRPC status. A request that failed shows a red triangle and **Failed**, and one held at a breakpoint shows **Paused**.

An encrypted connection shows a lock, and **Encrypted connection** in place of its path. To see inside it, [decrypt its host](/docs/https/).

## Search

Type in **Search requests** in the toolbar, or press ⌘F. Search looks through URLs, methods, apps, devices and your comments as you type. From three characters on, it looks through headers and bodies too, compressed ones included. It works together with the sidebar and the filters.

A body is searchable once its request finishes, up to its first megabyte. Images, media, fonts, archives and other binary bodies aren't searched.

## Filters

The bar above the list filters by status: **2xx**, **3xx**, **4xx**, **5xx** and **Failed**. Click several to combine them, or **All** to show every status.

Click **Filters** to filter by **App**, **Device**, **Host**, **Method** and the response's **Content type**: JSON, XML, HTML, JavaScript, CSS, Images, Media or Other. Each filter you set shows above the list. Click its × to remove it, or **Clear All** to remove them all.

## A request's details

Select a request to see its details, in these tabs:

- **Overview** (⌘1): the URL, your comment, the rules that acted on it, and the main facts: method, app, device, status, content type, duration, and how it was sent.
- **Request** (⌘2) and **Response** (⌘3): query parameters, headers, cookies and the body. Authorization headers and cookie values are hidden until you click **Show**. The Response tab also has the trailers, when there are any.
- **Raw** (⌘4): the request and response as text, the way they went.
- **Timing** (⌘5): each step of the request, from **DNS lookup**, **Connecting** and **TLS handshake** to **Waiting for server** and **Downloading**, and the total. Under **Connection**: the protocol, the server's address, the TLS version, and whether the connection was reused.
- **Messages** (⌘6): for WebSocket connections. See [Protocols](/docs/protocols/#websocket).

### Bodies

Reqly unpacks gzip, deflate and Brotli bodies on its own, and shows each body the way that suits it. Switch between the views above the body:

- **Formatted** and **Tree** for JSON. The tree can filter keys and values, and copy a value or its path. **Formatted** for XML too.
- **Preview** for images, with their format and dimensions.
- **Form** for form data.
- **Raw**, or **Text**, for the body as it came, with colors for its syntax.
- **Hex** for any body.

**Copy Body** copies it.

## Mark what matters

- **Pin** a request with the pin button in its details, or with **Request › Pin Request**. Pinned requests stay when you clear the list, and **Pinned** in the sidebar shows them all.
- **Color** a request from **Request › Color**, or from its right-click menu. Its row gets a stripe in that color.
- **Comment** on a request with **Request › Add Comment…**. Search finds comments too.

Session files keep pins, colors and comments. HAR files keep only comments.

## Clear the list

Click the trash button in the toolbar, or choose **Capture › Clear Traffic** (⌘K). Pinned requests stay.
