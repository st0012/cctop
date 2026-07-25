import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const plugin = join(root, "com.st0012.cctop.sdPlugin");
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
