import { focusURL, openCctopURL, TOGGLE_URL } from "./launcher.mjs";
import { keyImageFor } from "./render.mjs";
import {
  commandSessionForSlot,
  displaySessionForSlot,
  readDisplayState,
} from "./state.mjs";

export const SESSION_ACTION = "com.st0012.cctop.session";
export const TOGGLE_ACTION = "com.st0012.cctop.toggle-panel";
const CCTOP_APP_BUNDLE_ID = "com.st0012.CctopMenubar";

export function parseArgs(argv) {
  const args = { port: null, pluginUUID: null, registerEvent: null, info: {} };
  for (let index = 0; index < argv.length - 1; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "-port") args.port = Number(value);
    else if (flag === "-pluginUUID") args.pluginUUID = value;
    else if (flag === "-registerEvent") args.registerEvent = value;
    else if (flag === "-info") {
      try {
        args.info = JSON.parse(value);
      } catch {
        args.info = {};
      }
    } else {
      continue;
    }
    index += 1;
  }
  return args;
}

export function defaultSlot(coordinates, columns) {
  const row = coordinates?.row;
  const column = coordinates?.column;
  if (!Number.isInteger(row) || row < 0) return null;
  if (!Number.isInteger(column) || column < 0) return null;
  if (!Number.isInteger(columns) || columns < 1 || column >= columns) return null;
  return row * columns + column + 1;
}

/// Runtime controller for the one Stream Deck WebSocket supplied at launch.
/// The socket is the only injected collaborator; state and command transport
/// are fixed production boundaries rather than test-configurable seams.
export class StreamDeckController {
  constructor(socket, { pluginUUID, registerEvent, info }) {
    this.socket = socket;
    this.pluginUUID = pluginUUID;
    this.registerEvent = registerEvent;
    this.deviceColumns = new Map();
    this.sessionContexts = new Map();
    for (const device of info?.devices ?? []) {
      if (device?.id && Number.isInteger(device.size?.columns)) {
        this.deviceColumns.set(device.id, device.size.columns);
      }
    }
  }

  register() {
    this.send({ event: this.registerEvent, uuid: this.pluginUUID });
  }

  handleMessage(raw) {
    try {
      const message = typeof raw === "string" ? JSON.parse(raw) : raw;
      this.dispatch(message);
    } catch {
      this.log("Ignored malformed Stream Deck event");
    }
  }

  refresh() {
    if (this.sessionContexts.size === 0) return;
    const state = readDisplayState();
    for (const [context, entry] of this.sessionContexts) {
      this.renderContext(context, entry, state);
    }
  }

  dispatch(message) {
    switch (message?.event) {
      case "willAppear":
        this.handleWillAppear(message);
        break;
      case "willDisappear":
        this.sessionContexts.delete(message.context);
        break;
      case "didReceiveSettings":
        this.handleDidReceiveSettings(message);
        break;
      case "keyDown":
        this.handleKeyDown(message);
        break;
      case "deviceDidConnect":
        if (message.device && Number.isInteger(message.deviceInfo?.size?.columns)) {
          this.deviceColumns.set(message.device, message.deviceInfo.size.columns);
        }
        break;
      case "applicationDidLaunch":
      case "applicationDidTerminate":
        if (message.payload?.application === CCTOP_APP_BUNDLE_ID) this.refresh();
        break;
      default:
        break;
    }
  }

  handleWillAppear({ action, context, device, payload }) {
    if (action !== SESSION_ACTION || typeof context !== "string") return;
    const settings = payload?.settings;
    const hasSlot = settings != null && Object.prototype.hasOwnProperty.call(settings, "slot");
    let slot = hasSlot ? settings.slot : null;
    if (!hasSlot) {
      slot = defaultSlot(payload?.coordinates, this.deviceColumns.get(device));
      if (slot !== null) this.send({ event: "setSettings", context, payload: { slot } });
    } else if (!Number.isInteger(slot) || slot < 1) {
      slot = null;
    }
    const entry = { slot };
    this.sessionContexts.set(context, entry);
    this.renderContext(context, entry, readDisplayState());
  }

  handleDidReceiveSettings({ action, context, payload }) {
    if (action !== SESSION_ACTION) return;
    const entry = this.sessionContexts.get(context);
    const slot = payload?.settings?.slot;
    if (!entry) return;
    if (!Number.isInteger(slot) || slot < 1) {
      entry.slot = null;
      this.renderContext(context, entry, readDisplayState());
      return;
    }
    entry.slot = slot;
    this.renderContext(context, entry, readDisplayState());
  }

  handleKeyDown({ action, context }) {
    if (action === TOGGLE_ACTION) {
      this.launch(TOGGLE_URL, context);
      return;
    }
    if (action !== SESSION_ACTION) return;
    const entry = this.sessionContexts.get(context);
    if (!entry) {
      this.alert(context);
      return;
    }
    // Send exactly the permanent id this key last rendered — never re-resolve the slot, or a
    // press could target whichever session shifted into it after the image was drawn.
    // The permanent id resolves to the first current target in cctop's canonical panel order;
    // a missing id can never retarget the key to an unrelated session.
    if (entry.renderedCctopSessionId) {
      this.launch(focusURL(entry.renderedCctopSessionId), context);
      return;
    }
    const state = readDisplayState();
    if (state?.app_running === true) {
      this.alert(context);
      return;
    }
    // A key first shown while cctop is down has no rendered id. A recent graceful-quit
    // snapshot may still resolve its slot so the press cold-launches that session.
    const session = commandSessionForSlot(state, entry.slot);
    const url = session ? focusURL(session.cctopSessionId) : null;
    if (!url) {
      this.alert(context);
      return;
    }
    this.launch(url, context);
  }

  renderContext(context, entry, state) {
    const session = displaySessionForSlot(state, entry.slot);
    entry.renderedCctopSessionId = session?.cctopSessionId ?? null;
    const slotLabel = Number.isInteger(entry.slot) ? entry.slot : "";
    this.send({
      event: "setImage",
      context,
      payload: { image: keyImageFor(session, slotLabel), target: 0 },
    });
  }

  launch(url, context) {
    openCctopURL(url).catch(() => {
      this.log("Failed to deliver command to cctop");
      this.alert(context);
    });
  }

  alert(context) {
    if (typeof context === "string") this.send({ event: "showAlert", context });
  }

  log(message) {
    this.send({ event: "logMessage", payload: { message: `cctop: ${message}` } });
  }

  send(message) {
    try {
      this.socket.send(JSON.stringify(message));
    } catch {
      // Stream Deck owns recovery by relaunching disconnected plugins.
    }
  }
}
