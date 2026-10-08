---
title: Rules
description: Pause, answer, redirect, rewrite, block and slow down traffic as it passes.
---

Rules change matching traffic as it passes through Reqly. Open them with **Rules › Show Rules** (⌥⌘R).

The Rules window's sidebar lists the kinds of rules: **Breakpoints**, **Map Local**, **Map Remote**, **Rewrite**, **Block**, **Scripts** and **Slow Network**. Each kind has a switch at the top of its pane and in the **Rules** menu, and each rule has a switch of its own. A rule acts only when both are on. A green dot in the sidebar shows the kinds that are on.

Rules act on requests that start after you change them.

## Add a rule

- In the Rules window, select a kind and click **+**.
- Or right-click a request in the list, and choose **Add Rule**, then a kind. The rule starts out with the request's host, path and method.

Saving a new rule turns its kind on. As you edit a rule, it says how many of the requests captured so far it matches.

Double-click a rule to edit it. Right-click it to **Duplicate**, **Move Up**, **Move Down** or **Delete** it. To remove a rule, you can also select it and press Delete.

## Which requests a rule matches

A rule matches a **Host**, a **Path** and a **Method**. Leave a field empty to match anything.

- `*` matches anything, or nothing: `/v2/*` matches `/v2/forecast` and `/v2/forecast/hourly`.
- `*.example.com` matches the subdomains of example.com, but not example.com itself.
- Hosts match in any case. Paths match case exactly.
- A path matches without the query, unless the pattern has a `?` in it. So `/v2/forecast` matches `/v2/forecast?city=amsterdam`, and `/v2/forecast?city=*` matches only requests with a city.
- To match one port, add it to the host: `localhost:8080`.
- A rule matches both http and https.

Rules match the request as the app sent it. They act on requests you [send from Reqly](/docs/sending/) too. Of an encrypted connection, which Reqly doesn't decrypt, only the host is known, so only a Block rule for any path acts on it.

## Breakpoints

A breakpoint pauses a matching request, its response, or both, so you can change it before it goes on. Turn breakpoints on with the **Breakpoints** switch in the toolbar, or with **Rules › Breakpoints** (⇧⌘B).

Something that's paused shows as **Paused** in the list, and its details become an editor:

- **A request:** its method, URL, headers and body.
- **A response:** its status, reason, headers and body.

Then click **Continue** (⌘↩) to send it on, or **Cancel Request** (**Cancel Response** for a response) to stop it, and the app gets a 502 error. **Rules › Continue All Paused Requests** (⌥⌘↩) sends everything that's paused on, unchanged.

A pause lasts until you decide. Reqly lays out JSON bodies for editing, and sets Content-Length from the body.

## Map Local

Answers matching requests with a file on your Mac. The server never sees them.

- **File:** click **Choose…** to pick it. Reqly reads it for every request, so changing the file changes the answer.
- **Status:** 200 to begin with.
- **Content type:** from the file's extension, unless you enter one.

When you add the rule from a request, **Save the Response as a File…** saves that request's response, ready to edit.

## Map Remote

Sends matching requests to another server, such as staging instead of production. Enter the server in **Send to**, such as `https://staging.example.com`. A path there replaces the request's path, and the query stays.

The request in the list stays the way the app sent it. Its Overview says where it went.

## Rewrite

Changes matching traffic as it passes. Click **Add Change** for each change:

- **Set Header** and **Remove Header**, in the request or the response.
- **Set Query Parameter** and **Remove Query Parameter**, in the request.
- **Replace Body Text**, in the request or the response. It replaces every match, and matches case exactly.
- **Set Status**, in the response.

## Block

Stops matching requests, so the server never sees them: **With a status** (403 to begin with), or **By closing the connection, as a failing network would**. For a host Reqly doesn't decrypt, a Block rule for any path blocks the whole host.

## Scripts

JavaScript that changes requests and responses as they pass, or answers requests itself. See [Scripts](/docs/scripts/).

## Slow network

Slows traffic down to the speed of a slower network, to see how apps cope. Turn it on with the **Slow Network** switch in the toolbar, or with **Rules › Slow Network** (⇧⌘T).

Choose a **Profile**:

| Profile | Download | Upload | Latency | Packet loss |
|---|---|---|---|---|
| **3G** | 780 kbit/s | 330 kbit/s | 100 ms | None |
| **LTE** | 12,000 kbit/s | 4,000 kbit/s | 50 ms | None |
| **Lossy** | 1,000 kbit/s | 1,000 kbit/s | 300 ms | 5% |

Or set **Download**, **Upload**, **Latency** and **Packet loss** yourself, which makes the profile **Custom**. Under **Hosts**, list the hosts to slow down. With none listed, every host is slowed down. Changes apply to new connections.

## When several rules match

- **Breakpoints, Map Local, Map Remote and Block:** the first matching rule in the list acts. A Block rule acts before Map Local.
- **Rewrite and Scripts:** every matching rule acts, in the order of the list.

Kinds act in this order. Block and Map Local answer first, and if one does, nothing else acts. Otherwise: Map Remote, then the request's rewrites, scripts and breakpoint, then the server, then the response's rewrites, scripts and breakpoint.

Each rule that acted is listed under **Rules** in the request's Overview.
