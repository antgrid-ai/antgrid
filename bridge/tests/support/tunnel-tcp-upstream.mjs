// Raw net upstream run in its own Node process, because Bun's in-process
// server does not surface the ECONNRESET a peer's reset produces. Writes
// `bytes` to the first connection, then reports what its socket saw as JSON
// lines on stdout: `listening <port>`, `wrote`, `end`, `error <code>`, `close`.
import net from "node:net";

const total = Number(process.argv[2]);
const server = net.createServer((socket) => {
  socket.on("error", (e) => console.log(`error ${e.code}`));
  socket.on("end", () => { console.log("end"); socket.end(); });
  socket.on("close", () => { console.log("close"); server.close(); });
  const chunk = Buffer.alloc(64 * 1024, 0x61);
  let sent = 0;
  const pump = () => {
    while (sent < total) {
      sent += chunk.length;
      if (!socket.write(chunk)) { socket.once("drain", pump); return; }
    }
    console.log("wrote");
  };
  pump();
});
server.listen(0, () => console.log(`listening ${server.address().port}`));
