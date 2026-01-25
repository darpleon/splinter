const server = Bun.serve({
  port: 3000,
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname === "/" ? "/index.html" : url.pathname;
    const file = Bun.file(`./zig-out/bin${path}`);

    if (!(await file.exists())) {
      return new Response("Not Found", { status: 404 });
    }
    return new Response(file);
  },
});
console.log(`Serving at http://localhost:${server.port}`);
