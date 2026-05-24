// Tiny in-process HTTP fixture so tests don't hit the public internet.
// Keeps the suite deterministic + hermetic (AGENTS.md §3.6).

import http from "node:http";
import type { AddressInfo } from "node:net";

export interface FixtureServer {
  url: string;
  close: () => Promise<void>;
}

export async function startFixture(): Promise<FixtureServer> {
  const server = http.createServer((req, res) => {
    if (req.url === "/" || req.url === "/index.html") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(
        "<!doctype html><html><head><title>nullalis fixture</title></head>" +
          "<body><h1 id='hello'>hello</h1>" +
          "<input id='name' type='text'/>" +
          "<button id='go'>Go</button>" +
          "<script>document.getElementById('go').onclick=()=>{" +
          "document.body.appendChild(Object.assign(document.createElement('div'),{id:'clicked',innerText:'clicked'}));" +
          "};</script>" +
          "</body></html>",
      );
      return;
    }
    if (req.url?.startsWith("/cookie")) {
      // Set a cookie based on query string ?v=
      const url = new URL(req.url, "http://x");
      const v = url.searchParams.get("v") ?? "none";
      res.writeHead(200, {
        "content-type": "text/html; charset=utf-8",
        "set-cookie": `fixturecookie=${v}; Path=/`,
      });
      res.end(`<!doctype html><body>cookie set to ${v}</body>`);
      return;
    }
    if (req.url === "/show-cookie") {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end(`cookie:${req.headers.cookie ?? ""}`);
      return;
    }
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const addr = server.address() as AddressInfo;
  const url = `http://127.0.0.1:${addr.port}`;
  return {
    url,
    close: () =>
      new Promise<void>((resolve, reject) =>
        server.close((err) => (err ? reject(err) : resolve())),
      ),
  };
}
