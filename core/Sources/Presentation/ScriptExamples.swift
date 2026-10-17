import Foundation

/// Scripts to start from, as the script editor's Examples menu offers them. Each app titles them
/// in its own style, by their IDs.
public enum ScriptExamples {
    public struct Example: Identifiable, Hashable, Sendable {
        public let id: String
        public let code: String
    }

    /// What a new script starts as.
    public static let starter = """
        // onRequest runs before each matching request goes to the server, and onResponse
        // before each response goes back to the app. Change what they get, and it goes on
        // changed. The Examples menu has more to start from.

        function onRequest(request) {
          // request.method, request.url, request.headers, request.body, request.json
        }

        function onResponse(response, request) {
          // response.status, response.headers, response.body, response.json
        }

        """

    public static let all: [Example] = [
        Example(
            id: "addHeader",
            code: """
                // Adds a header to each matching request before it goes to the server.
                function onRequest(request) {
                  request.headers.set("Authorization", "Bearer YOUR-TOKEN");
                }

                """),
        Example(
            id: "changeJSON",
            code: """
                // Changes a field in each matching JSON response before the app gets it.
                function onResponse(response, request) {
                  if (response.json) {
                    response.json.isPremium = true;
                  }
                }

                """),
        Example(
            id: "answer",
            code: """
                // Answers matching requests itself, so you can see how the app copes with an error.
                function onRequest(request) {
                  return respond(503, JSON.stringify({ error: "Down for maintenance" }), {
                    "Content-Type": "application/json",
                  });
                }

                """),
        Example(
            id: "sendElsewhere",
            code: """
                // Sends matching requests to staging instead of production.
                function onRequest(request) {
                  request.url = request.url.replace("https://api.example.com", "https://staging.example.com");
                }

                """),
        Example(
            id: "rememberToken",
            code: """
                // Keeps the token a sign-in returns, and sends it with the requests after it.
                // `shared` keeps what you put in it from one run to the next, while Reqly runs.
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

                """),
        Example(
            id: "log",
            code: """
                // Writes each matching request and response to the request's Overview.
                function onRequest(request) {
                  console.log(request.method, request.url);
                }

                function onResponse(response, request) {
                  console.log(response.status, response.headers.get("Content-Type"));
                }

                """),
    ]
}
