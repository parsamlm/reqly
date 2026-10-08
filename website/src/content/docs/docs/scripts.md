---
title: Scripts
description: Write JavaScript that changes requests and responses as they pass, or answers requests itself.
---

A script is a rule with JavaScript in it. It can change matching requests before they go to the server, change responses before they go back to the app, or answer requests itself.

## Add a script

1. Open **Rules › Show Rules** (⌥⌘R), select **Scripts**, and click **+**. Or right-click a request, and choose **Add Rule › Script…**.
2. Enter the **Host**, **Path** and **Method** to match, as for any [rule](/docs/rules/#which-requests-a-rule-matches).
3. Write the script, or start from one in **Examples**.
4. Click **Save**.

Reqly checks the script as you type, and takes you to the line with a problem. The ⓘ button shows a short reference.

## Try it first

Under **Try it on**, pick a request captured earlier, and click **Try It**. Reqly runs the script on it, and shows what it would change and what it logs. Nothing is sent.

## Write a script

A script has an `onRequest` function, an `onResponse` function, or both:

```js
function onRequest(request) {
  // Runs before each matching request goes to the server.
}

function onResponse(response, request) {
  // Runs before each matching response goes back to the app.
}
```

Change what they get, and it goes on changed.

### Change a request

```js
function onRequest(request) {
  request.headers.set("Authorization", "Bearer YOUR-TOKEN");
}
```

Change the URL to send the request somewhere else:

```js
function onRequest(request) {
  request.url = request.url.replace("https://api.example.com", "https://staging.example.com");
}
```

### Change a JSON response

```js
function onResponse(response, request) {
  if (response.json) {
    response.json.isPremium = true;
  }
}
```

### Answer a request yourself

Return `respond(status, body, headers)` from `onRequest`, and the server never sees the request:

```js
function onRequest(request) {
  return respond(503, JSON.stringify({ error: "Down for maintenance" }), {
    "Content-Type": "application/json",
  });
}
```

### Keep something from one run to the next

Each run starts afresh, so variables don't carry over, but `shared` does, while Reqly runs:

```js
function onResponse(response, request) {
  if (request.url.endsWith("/login") && response.json?.token) {
    shared.token = response.json.token;
    console.log("Remembered a token");
  }
}

function onRequest(request) {
  if (shared.token) {
    request.headers.set("Authorization", `Bearer ${shared.token}`);
  }
}
```

## Reference

### request

| Property | What it is |
|---|---|
| `method` | The method, such as `"GET"`. |
| `url` | The whole URL, such as `"https://api.example.com/v1/forecast?city=amsterdam"`. Change it to send the request somewhere else; the Host header follows. |
| `headers` | The headers. See [headers](#headers). |
| `body` | The body as text, `""` when there's none, or `null` when it isn't text or is over 8 MB. |
| `json` | The body parsed, when it's JSON. Change it, and the body changes too. |

In `onResponse`, `request` is the request as it went to the server. Changing it there does nothing.

### response

| Property | What it is |
|---|---|
| `status` | The status code, such as `200`. |
| `reason` | The reason phrase, such as `"OK"`. A new status gets its standard reason. |
| `headers`, `body`, `json` | As for the request. |

### headers

Headers work as in the Fetch API, and their names match in any case:

- `get(name)`: the value, or `null`. Several values are joined with `", "`.
- `getAll(name)`: every value.
- `has(name)`, `set(name, value)`, `append(name, value)` and `delete(name)`.
- `forEach()`, `entries()`, `keys()` and `values()`, and `for…of`.

### respond(status, body, headers)

Makes a response to return from `onRequest`. The body is text, so turn objects into text first, with `JSON.stringify`.

### shared

An object kept for each script from one run to the next, while Reqly runs. It holds what JSON can, so not functions, up to about 1 MB.

### console

`console.log`, `info`, `debug`, `warn` and `error` write to the request's Overview, under **Script output**, up to 1,000 lines a run.

### Everything else

Scripts have standard JavaScript, including `JSON`, `Date`, `RegExp`, `Map`, `Set`, promises and `async` functions, and `atob` and `btoa`. They don't have `fetch`, timers, `URL` or `crypto`, and they can't reach your files or the network.

## How scripts run

- Every matching script runs, in the order of the list, each on what the one before it left. Scripts run after Rewrite rules and before breakpoints.
- Reqly waits for a whole request or response, body included, before a script gets it.
- Each run has 1 second and 128 MB of memory.
- A script that fails, or runs out of time, leaves the traffic as it was. The request's Overview says what went wrong, and on which line.
- Bodies that aren't text reach scripts as `null`, and go on unchanged unless the script sets a new body. Scripts don't see WebSocket messages.
