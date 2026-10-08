---
title: Protocols
description: HTTP/2, WebSocket, gRPC and Protobuf in Reqly.
---

## HTTP/2

For the hosts it decrypts, Reqly speaks HTTP/2 or HTTP/1.1 with apps, and HTTP/2 or HTTP/1.1 with servers, whichever each side prefers. The two can differ. A request's **Overview** shows both under **Connection**: **Protocol** is what the app used, and **To the server** is what the server used. Plain HTTP goes over HTTP/1.1.

The **Raw** tab writes HTTP/2 requests the way HTTP/1.1 does, so they're easy to read.

## WebSocket

A WebSocket connection shows in the list as a request with status 101. Select it, and open the **Messages** tab (⌘6):

- ↑ marks the messages the app sent, and ↓ the messages from the server.
- Each row shows the message's kind (**Text**, **Binary**, **Close**, **Ping** or **Pong**), a preview, its size, and when it went, counted from the start of the connection.
- **Filter messages** finds text in messages, and **All**, **Sent** and **Received** show one direction or both.
- Select a message to see all of it, or right-click it and choose **Copy Message**.

Reqly keeps up to 1 MB of each message. For `wss://` connections, it shows the messages when it decrypts the host.

## gRPC and Protobuf

Reqly decodes gRPC bodies, gRPC-Web and Connect included, and Protobuf bodies. It recognizes them by their content type. Without the `.proto` files, each field shows by its number, with a guess at its value.

### Add your .proto files

1. Open **Reqly › Settings…**, and choose **Protobuf**.
2. Click **+**, and choose `.proto` files, or folders that hold them. Add the folders with the files that others import, too.

Reqly reads the files each time it opens, or when you click **Reload**. Anything it can't make sense of, such as a type it can't find, is listed under **Problems**.

### Message types

Reqly picks each body's message type from the gRPC method, or from the content type. To choose one yourself, use the menu above the body. Reqly remembers your choice for that host and path. **Automatic** goes back to Reqly's choice.

The body shows as **Formatted**, **Tree** or **Hex**. For gRPC calls, the details show the gRPC status, and the Response tab shows the trailers. Streams fill in as their messages arrive.
