import assert from "node:assert/strict";
import test from "node:test";
import {
  EMPTY_BG,
  EMPTY_FG,
  escapeXml,
  keyImageFor,
  renderEmptyKey,
  renderSessionKey,
  svgToDataURL,
  textColorFor,
  wrapName,
} from "../com.st0012.cctop.sdPlugin/lib/render.mjs";

function session(overrides = {}) {
  return { id: "one", name: "my session", status: "working", color: "#7EAA6E", ...overrides };
}

test("escapes XML and emits non-ASCII as numeric references", () => {
  assert.equal(escapeXml(`<b>&"'`), "&lt;b&gt;&amp;&quot;&apos;");
  assert.equal(escapeXml("hi 🚀"), "hi &#128640;");
  const svg = renderSessionKey(session({ name: `<b>&"' 🚀` }), 1);
  assert.ok(!svg.includes("<b>"));
  assert.ok(!/[^\x00-\x7F]/.test(svg));
});

test("chooses the higher-contrast black or white text", () => {
  assert.equal(textColorFor("#FABD2F"), "#000000");
  assert.equal(textColorFor("#7EAA6E"), "#000000");
  assert.equal(textColorFor("#DD5353"), "#000000");
  assert.equal(textColorFor("#282828"), "#FFFFFF");
  assert.equal(textColorFor("#FFFFFF"), "#000000");
  assert.equal(textColorFor("#000000"), "#FFFFFF");
});

test("wraps and ellipsizes names without splitting grapheme clusters", () => {
  assert.deepEqual(wrapName("api server"), ["api server"]);
  assert.deepEqual(wrapName("fix login flow"), ["fix login", "flow"]);
  assert.deepEqual(wrapName("supercalifragilistic"), ["supercalif", "ragilistic"]);
  assert.deepEqual(wrapName("123456789🚀abc", { maxChars: 10 }), ["123456789🚀", "abc"]);
  assert.deepEqual(
    wrapName("e\u0301e\u0301e\u0301", { maxChars: 2 }),
    ["e\u0301e\u0301", "e\u0301"]
  );
  const lines = wrapName("a very long session name that keeps going and going");
  assert.equal(lines.length, 3);
  assert.ok(lines[2].endsWith("…"));
});

test("renders session and unavailable keys as SVG data URLs", () => {
  const empty = renderEmptyKey(4);
  assert.ok(empty.includes(`fill="${EMPTY_BG}"`));
  assert.ok(empty.includes(`fill="${EMPTY_FG}"`));
  assert.ok(empty.includes(">4</text>"));

  const rendered = renderSessionKey(session({ status: "waiting_permission" }), 1);
  assert.ok(rendered.includes(">waiting permission</text>"));
  assert.ok(renderSessionKey(session({ color: "invalid" }), 1).includes('fill="#444444"'));

  const dataURL = svgToDataURL("<svg></svg>");
  assert.equal(decodeURIComponent(dataURL.slice("data:image/svg+xml,".length)), "<svg></svg>");
  assert.ok(keyImageFor(session(), 1).startsWith("data:image/svg+xml,"));
  assert.ok(keyImageFor(null, 2).startsWith("data:image/svg+xml,"));
});
