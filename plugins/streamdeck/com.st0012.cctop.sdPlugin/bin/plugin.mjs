import { parseArgs, StreamDeckController } from "../lib/controller.mjs";
import { watchDisplayState } from "../lib/state.mjs";

const args = parseArgs(process.argv.slice(2));
if (!args.port || !args.pluginUUID || !args.registerEvent) process.exit(1);

const socket = new WebSocket(`ws://127.0.0.1:${args.port}`);
const controller = new StreamDeckController(socket, args);
let watcher = null;

socket.addEventListener("open", () => {
  controller.register();
  watcher = watchDisplayState(() => controller.refresh());
  if (!watcher) process.exit(1);
  watcher.on("error", () => process.exit(1));
});

socket.addEventListener("message", (event) => {
  controller.handleMessage(typeof event.data === "string" ? event.data : String(event.data));
});

function exit() {
  watcher?.close();
  process.exit(0);
}

socket.addEventListener("close", exit);
socket.addEventListener("error", exit);
