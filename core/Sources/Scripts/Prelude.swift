/// What every script starts with: `console`, `Headers` as the Fetch API has it, `respond`,
/// `shared`, and the function Reqly calls, which hands a message to the script's
/// `onRequest` or `onResponse` and returns what came of it, as JSON.
enum Prelude {
    static let source = #"""
        "use strict";

        const __reqly = { logs: [] };

        (() => {
          const format = (value) => {
            if (typeof value === "string") return value;
            if (value instanceof Error) return value.stack ? `${value}\n${value.stack}` : String(value);
            try {
              const json = JSON.stringify(value, null, 2);
              return json === undefined ? String(value) : json;
            } catch {
              return String(value);
            }
          };
          const write = (prefix) => (...values) => {
            if (__reqly.logs.length < 1000) {
              __reqly.logs.push(prefix + values.map(format).join(" "));
            }
          };
          globalThis.console = {
            log: write(""), info: write(""), debug: write(""), warn: write("Warning: "), error: write("Error: "),
          };
        })();

        /// Header fields in order, with names that match without regard to case.
        class Headers {
          #fields;

          constructor(fields) {
            this.#fields = [];
            if (fields instanceof Headers) {
              this.#fields = fields.toJSON();
            } else if (Array.isArray(fields)) {
              for (const [name, value] of fields) this.append(name, value);
            } else if (fields && typeof fields === "object") {
              for (const [name, value] of Object.entries(fields)) this.append(name, value);
            }
          }

          get(name) {
            const values = this.getAll(name);
            return values.length === 0 ? null : values.join(", ");
          }

          getAll(name) {
            const lower = String(name).toLowerCase();
            return this.#fields.filter(([field]) => field.toLowerCase() === lower).map(([, value]) => value);
          }

          has(name) {
            return this.getAll(name).length > 0;
          }

          set(name, value) {
            const lower = String(name).toLowerCase();
            const at = this.#fields.findIndex(([field]) => field.toLowerCase() === lower);
            this.delete(name);
            this.#fields.splice(at === -1 ? this.#fields.length : at, 0, [String(name), String(value)]);
          }

          append(name, value) {
            this.#fields.push([String(name), String(value)]);
          }

          delete(name) {
            const lower = String(name).toLowerCase();
            this.#fields = this.#fields.filter(([field]) => field.toLowerCase() !== lower);
          }

          forEach(callback) {
            for (const [name, value] of this.#fields) callback(value, name, this);
          }

          *entries() { yield* this.#fields.map((field) => [...field]); }
          *keys() { for (const [name] of this.#fields) yield name; }
          *values() { for (const [, value] of this.#fields) yield value; }
          [Symbol.iterator]() { return this.entries(); }

          toJSON() {
            return this.#fields.map((field) => [...field]);
          }
        }

        /// A response for `onRequest` to answer with, so the request never reaches the server.
        function respond(status, body, headers) {
          return { status, body: body ?? "", headers: new Headers(headers ?? {}) };
        }

        /// Kept from one run of the script to the next, while Reqly runs.
        globalThis.shared = {};

        function __reqly_message(raw, isRequest) {
          const message = isRequest
            ? { method: raw.method, url: raw.url }
            : { status: raw.status, reason: raw.reason };
          message.headers = new Headers(raw.headers);
          message.body = raw.body;
          // A JSON body comes parsed, too.
          if (typeof raw.body === "string" && /^\s*[\[{]/.test(raw.body)) {
            try {
              message.json = JSON.parse(raw.body);
            } catch {}
          }
          return message;
        }

        function __reqly_fields(headers) {
          if (headers instanceof Headers) return headers.toJSON();
          return new Headers(headers ?? {}).toJSON();
        }

        /// What goes back to Reqly: the message's parts, with the body from `json` when the
        /// script changed that.
        function __reqly_out(message, raw, isRequest) {
          const out = isRequest
            ? { method: String(message.method ?? raw.method), url: String(message.url ?? raw.url) }
            : { status: Number(message.status ?? raw.status), reason: String(message.reason ?? raw.reason ?? "") };
          out.headers = __reqly_fields(message.headers ?? raw.headers);
          let body = message.body;
          if (message.json !== undefined) {
            const json = JSON.stringify(message.json);
            const before = raw.body === null ? undefined : __reqly_json(raw.body);
            if (json !== before) body = json;
          }
          out.body = body === null || body === undefined ? null : String(body);
          out.bodyChanged = out.body !== raw.body;
          return out;
        }

        function __reqly_json(text) {
          try {
            return JSON.stringify(JSON.parse(text));
          } catch {
            return undefined;
          }
        }

        function __reqly_isResponse(value) {
          return value !== null && typeof value === "object" && typeof value.status === "number"
            && value.method === undefined && value.url === undefined;
        }

        function __reqly_finish(input, request, response, returned) {
          const result = { logs: __reqly.logs };
          if (input.phase === "request") {
            if (__reqly_isResponse(returned)) {
              result.answer = __reqly_out(returned, { status: 200, reason: "", headers: [], body: "" }, false);
            } else {
              result.request = __reqly_out(returned ?? request, input.request, true);
            }
          } else {
            result.response = __reqly_out(returned ?? response, input.response, false);
          }
          try {
            const shared = JSON.stringify(globalThis.shared);
            if (shared !== undefined && shared.length <= 1048576) result.shared = shared;
          } catch {}
          return JSON.stringify(result);
        }

        function __reqly_run(text) {
          const input = JSON.parse(text);
          if (input.shared) globalThis.shared = JSON.parse(input.shared);
          const request = __reqly_message(input.request, true);
          const response = input.response ? __reqly_message(input.response, false) : null;
          // By name, so functions the script declares with const or let count, too.
          const handler = input.phase === "request"
            ? (typeof onRequest === "function" ? onRequest : undefined)
            : (typeof onResponse === "function" ? onResponse : undefined);
          if (typeof handler !== "function") {
            return JSON.stringify({ logs: __reqly.logs, missing: true });
          }
          const returned = input.phase === "request" ? handler(request) : handler(response, request);
          if (returned instanceof Promise) {
            return returned.then((value) => __reqly_finish(input, request, response, value));
          }
          return __reqly_finish(input, request, response, returned);
        }
        """#
}
