const fs = require("node:fs");

const electronDist = process.env.ELECTRON_DIST || process.env.ELECTRON_OVERRIDE_DIST_PATH;

if (!electronDist) {
  throw new Error("ELECTRON_DIST or ELECTRON_OVERRIDE_DIST_PATH must point to the system Electron directory");
}

const electronVersion = fs.readFileSync(`${electronDist}/version`, "utf8").trim().replace(/^v/, "");
const packageJson = JSON.parse(fs.readFileSync("package.json", "utf8"));

module.exports = {
  ...(packageJson.build ?? {}),
  electronDist,
  electronVersion,
};
