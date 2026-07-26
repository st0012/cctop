import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const plugin = join(root, "com.st0012.cctop.sdPlugin");
const repository = join(root, "..", "..");
const manifest = JSON.parse(readFileSync(join(plugin, "manifest.json"), "utf8"));

test("manifest targets the supported Stream Deck Node runtime", () => {
  assert.match(manifest.Version, /^\d+\.\d+\.\d+\.\d+$/);
  assert.equal(manifest.Nodejs.Version, "24");
  assert.equal(manifest.SDKVersion, 2);
  assert.equal(manifest.Software.MinimumVersion, "7.1");
  assert.equal(manifest.OS[0].Platform, "mac");
  assert.deepEqual(manifest.ApplicationsToMonitor, {
    mac: ["com.st0012.CctopMenubar"],
  });
});

test("manifest exposes cctop actions and a non-switching default profile", () => {
  assert.equal(manifest.Category, "cctop");
  assert.equal(manifest.CategoryIcon, "imgs/category");
  assert.deepEqual(manifest.Actions.map((action) => action.UUID), [
    "com.st0012.cctop.session",
    "com.st0012.cctop.toggle-panel",
  ]);
  assert.deepEqual(manifest.Profiles, [{
    Name: "profiles/cctop",
    DeviceType: 0,
    AutoInstall: true,
    DontAutoSwitchWhenInstalled: true,
  }]);
});

test("every manifest image and code resource is present", () => {
  assert.ok(existsSync(join(plugin, manifest.CodePath)));
  assert.ok(existsSync(join(plugin, `${manifest.Icon}.png`)));
  assert.ok(existsSync(join(plugin, `${manifest.Icon}@2x.png`)));
  assert.ok(existsSync(join(plugin, `${manifest.CategoryIcon}.svg`)));
  assert.ok(existsSync(join(plugin, `${manifest.CategoryIcon}@2x.svg`)));
  for (const action of manifest.Actions) {
    assert.ok(existsSync(join(plugin, `${action.Icon}.svg`)));
    assert.ok(existsSync(join(plugin, `${action.Icon}@2x.svg`)));
    for (const state of action.States) {
      assert.ok(existsSync(join(plugin, `${state.Image}.svg`)));
      assert.ok(existsSync(join(plugin, `${state.Image}@2x.svg`)));
    }
  }
});

test("plugin identity surfaces use the canonical name lockup", () => {
  assert.equal(manifest.Icon, "imgs/plugin-icon");
  const pluginIcon = readFileSync(join(plugin, "imgs", "plugin-icon.png"));
  const pluginIcon2x = readFileSync(join(plugin, "imgs", "plugin-icon@2x.png"));
  assert.equal(pluginIcon.readUInt32BE(16), 256);
  assert.equal(pluginIcon.readUInt32BE(20), 256);
  assert.equal(pluginIcon2x.readUInt32BE(16), 512);
  assert.equal(pluginIcon2x.readUInt32BE(20), 512);
  assert.notDeepEqual(
    pluginIcon,
    readFileSync(join(
      repository,
      "menubar",
      "CctopMenubar",
      "Assets.xcassets",
      "AppIcon.appiconset",
      "icon_128x128@2x.png"
    ))
  );

  const category = readFileSync(join(plugin, "imgs", "category.svg"), "utf8");
  const category2x = readFileSync(join(plugin, "imgs", "category@2x.svg"), "utf8");
  assert.equal(category2x, category);
  assert.match(category, /clipPath id="bar"/);
  for (const opacity of ["0.62", "0.42", "0.25"]) {
    assert.match(category, new RegExp(`opacity="${opacity}"`));
  }

  const toggleKey = readFileSync(join(plugin, "imgs", "key-toggle.svg"), "utf8");
  const toggleKey2x = readFileSync(join(plugin, "imgs", "key-toggle@2x.svg"), "utf8");
  assert.equal(toggleKey2x, toggleKey);
  assert.doesNotMatch(toggleKey, /clipPath|clip-path/);
  assert.match(toggleKey, /<rect width="144" height="144" rx="23\.04" fill="#0C0D0F"\/>/);
  assert.match(toggleKey, /rx="22\.29" fill="none" stroke="#FFFFFF" stroke-opacity="0\.05"/);
  assert.match(toggleKey, /M46\.26 46\.26H73\.56V57\.18H46\.26A5\.46 5\.46 0 0 1 46\.26 46\.26Z/);
  assert.match(toggleKey, /M93\.84 46\.26H97\.74A5\.46 5\.46 0 0 1 97\.74 57\.18H93\.84Z/);
  assert.match(toggleKey, /<rect x="73\.56" y="46\.26" width="12\.48" height="10\.92"/);
  assert.match(toggleKey, /<rect x="86\.04" y="46\.26" width="7\.8" height="10\.92"/);
  assert.match(toggleKey, /font-family="SF Mono, Menlo, monospace"/);
  assert.match(toggleKey, /font-size="23\.4" font-weight="600" letter-spacing="0\.702">cctop<\/text>/);
  for (const color of ["#8CBF6A", "#E09B56", "#DB6E6E", "#4D5058"]) {
    assert.match(toggleKey, new RegExp(color));
  }
});

test("bundled default profile contains exactly five ordered sessions and one toggle", () => {
  const archive = join(plugin, "profiles", "cctop.streamDeckProfile");
  const entries = execFileSync("/usr/bin/unzip", ["-Z1", archive], { encoding: "utf8" })
    .trim().split("\n");
  assert.equal(entries.length, 1);
  assert.match(entries[0], /^[^/]+\.sdProfile\/manifest\.json$/);
  const profile = JSON.parse(execFileSync(
    "/usr/bin/unzip",
    ["-p", archive, entries[0]],
    { encoding: "utf8" }
  ));
  assert.equal(profile.DeviceModel, "20GBA9901");
  assert.equal(profile.InstalledByPluginUUID, manifest.UUID);
  assert.deepEqual(Object.keys(profile.Actions).sort(), ["0,0", "0,1", "1,0", "2,0", "3,0", "4,0"]);
  for (let slot = 1; slot <= 5; slot += 1) {
    const action = profile.Actions[`${slot - 1},0`];
    assert.equal(action.UUID, "com.st0012.cctop.session");
    assert.equal(action.Settings.slot, slot);
  }
  assert.equal(profile.Actions["0,1"].UUID, "com.st0012.cctop.toggle-panel");
});
