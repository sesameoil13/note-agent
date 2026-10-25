// Local only. Generate a one-use App enrollment capability, never an account token.
import { randomBytes, createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
await mkdir(".local", { recursive: true, mode: 0o700 });
const code = randomBytes(32).toString("base64url");
await writeFile(".local/activation-code.txt", code + "\n", {
  mode: 0o600,
  flag: "wx",
});
await writeFile(
  ".local/activation-hash.txt",
  createHash("sha256").update(code).digest("hex") + "\n",
  { mode: 0o600, flag: "wx" },
);
console.log(
  "Created private .local/activation-code.txt and activation-hash.txt. No network request was made.",
);
