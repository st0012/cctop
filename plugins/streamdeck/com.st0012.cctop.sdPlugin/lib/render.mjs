const KEY_SIZE = 144;
const NAME_FONT_SIZE = 22;
const NAME_LINE_HEIGHT = 26;
const STATUS_FONT_SIZE = 13;
const FONT_FAMILY = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif";
const graphemeSegmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

export const EMPTY_BG = "#2A2A2A";
export const EMPTY_FG = "#666666";
const FALLBACK_SESSION_BG = "#444444";

export function escapeXml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;")
    .replace(/[\u0080-\u{10FFFF}]/gu, (character) => `&#${character.codePointAt(0)};`);
}

function graphemes(text) {
  return Array.from(graphemeSegmenter.segment(text), ({ segment }) => segment);
}

function normalizeHexColor(color) {
  if (typeof color !== "string") return null;
  const match = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(color.trim());
  if (!match) return null;
  let hex = match[1];
  if (hex.length === 3) hex = hex.replace(/./g, (character) => character + character);
  return `#${hex.toUpperCase()}`;
}

export function relativeLuminance(color) {
  const hex = normalizeHexColor(color);
  if (!hex) return 0;
  const linear = (value) => {
    const channel = value / 255;
    return channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  };
  const red = linear(Number.parseInt(hex.slice(1, 3), 16));
  const green = linear(Number.parseInt(hex.slice(3, 5), 16));
  const blue = linear(Number.parseInt(hex.slice(5, 7), 16));
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

/// The luminance where black and white have equal WCAG contrast is ~0.179.
export function textColorFor(background) {
  return relativeLuminance(background) > 0.179 ? "#000000" : "#FFFFFF";
}

export function wrapName(name, { maxLines = 3, maxChars = 10 } = {}) {
  const words = String(name ?? "").trim().split(/\s+/).filter(Boolean);
  const tokens = [];
  for (const word of words) {
    const characters = graphemes(word);
    for (let index = 0; index < characters.length; index += maxChars) {
      tokens.push(characters.slice(index, index + maxChars).join(""));
    }
  }

  const lines = [];
  let current = "";
  let truncated = false;
  for (const token of tokens) {
    const combinedLength = graphemes(current).length + (current ? 1 : 0) + graphemes(token).length;
    if (!current) {
      current = token;
    } else if (combinedLength <= maxChars) {
      current += ` ${token}`;
    } else if (lines.length === maxLines - 1) {
      truncated = true;
      break;
    } else {
      lines.push(current);
      current = token;
    }
  }
  if (current) lines.push(current);

  if (truncated && lines.length === maxLines) {
    const last = graphemes(lines[maxLines - 1]);
    lines[maxLines - 1] = `${last.slice(0, maxChars - 1).join("").trimEnd()}…`;
  }
  return lines;
}

function svgOpen(background) {
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${KEY_SIZE} ${KEY_SIZE}">` +
    `<rect width="${KEY_SIZE}" height="${KEY_SIZE}" fill="${background}"/>`
  );
}

function textElement({ y, fill, fontSize, fontWeight = "600", opacity = null, content }) {
  const opacityAttribute = opacity === null ? "" : ` opacity="${opacity}"`;
  return (
    `<text x="${KEY_SIZE / 2}" y="${y}" text-anchor="middle" fill="${fill}"` +
    ` font-family="${FONT_FAMILY}" font-size="${fontSize}" font-weight="${fontWeight}"${opacityAttribute}>` +
    `${content}</text>`
  );
}

export function renderSessionKey(session, slot) {
  const background = normalizeHexColor(session.color) ?? FALLBACK_SESSION_BG;
  const fill = textColorFor(background);
  const name = typeof session.name === "string" && session.name.trim() ? session.name : `#${slot}`;
  const lines = wrapName(name);
  const status = typeof session.status === "string" && session.status
    ? session.status.replace(/[_-]+/g, " ")
    : null;
  const centerY = status ? 66 : 72;
  const firstLineCenter = centerY - ((lines.length - 1) * NAME_LINE_HEIGHT) / 2;

  let svg = svgOpen(background);
  lines.forEach((line, index) => {
    const baseline = Math.round(firstLineCenter + index * NAME_LINE_HEIGHT + NAME_FONT_SIZE * 0.35);
    svg += textElement({ y: baseline, fill, fontSize: NAME_FONT_SIZE, content: escapeXml(line) });
  });
  if (status) {
    svg += textElement({
      y: 134,
      fill,
      fontSize: STATUS_FONT_SIZE,
      fontWeight: "500",
      opacity: "0.75",
      content: escapeXml(status),
    });
  }
  return `${svg}</svg>`;
}

export function renderEmptyKey(slot) {
  let svg = svgOpen(EMPTY_BG);
  svg += textElement({ y: 86, fill: EMPTY_FG, fontSize: 40, content: escapeXml(String(slot)) });
  return `${svg}</svg>`;
}

export function svgToDataURL(svg) {
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

export function keyImageFor(session, slot) {
  return svgToDataURL(session ? renderSessionKey(session, slot) : renderEmptyKey(slot));
}
