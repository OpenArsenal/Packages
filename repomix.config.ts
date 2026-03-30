import { defineConfig } from "repomix";
import path from "node:path";
import { execSync } from "node:child_process";

const repo = process.env.REPO_NAME;

const style = "xml";

const now = new Date();
const timestamp =
  now.getFullYear().toString() +
  String(now.getMonth() + 1).padStart(2, "0") +
  String(now.getDate()).padStart(2, "0") +
  "-" +
  String(now.getHours()).padStart(2, "0") +
  String(now.getMinutes()).padStart(2, "0");

function getBranch() {
  try {
    return execSync("git rev-parse --abbrev-ref HEAD")
      .toString()
      .trim()
      .replace(/[\/\\]/g, "-");
  } catch {
    return "no-branch";
  }
}

const branch = getBranch();

export default defineConfig({
  input: {
    maxFileSize: 52428800,
  },
  output: {
    filePath: `${repo}-arch-packages-${branch}-${timestamp}-repomix-output.${style}`,
    style: `${style}`,
    parsableStyle: true,
    fileSummary: true,
    directoryStructure: true,
    files: true,
    removeComments: true,
    removeEmptyLines: true,
    compress: true,
    topFilesLength: 5,
    showLineNumbers: false,
    truncateBase64: true,
    copyToClipboard: false,
    includeFullDirectoryStructure: true,
    tokenCountTree: false,
    git: {
      sortByChanges: true,
      sortByChangesMaxCommits: 100,
      includeDiffs: false,
      includeLogs: false,
      includeLogsCount: 50,
    },
  },
  include: [],
  ignore: {
    useGitignore: true,
    useDotIgnore: true,
    useDefaultPatterns: true,
    customPatterns: [
      "pkgs/*/*.md",
      "pkgs/*/*.html",
      "pkgs/*/*.json",
      "pkgs/*/*.changelog",
      "pkgs/*/LICENSE*",
      "pkgs/*/.gitignore",
      "pkgs/*/.SRCINFO",
    ],
  },
  security: {
    enableSecurityCheck: true,
  },
  tokenCount: {
    encoding: "o200k_base",
  },
});
