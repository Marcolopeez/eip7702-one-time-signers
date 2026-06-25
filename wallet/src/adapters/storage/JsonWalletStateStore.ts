/**
 * JSON-backed storage for the local wallet state.
 *
 * This is intentionally simple and suitable for the current CLI/prototype
 * stage. The state is security-sensitive because it records burned one-time
 * keys and pending signatures.
 */
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { LocalWalletState } from "../../protocol/one-time-signer-account/state.js";

export class JsonWalletStateStore {
  readonly path: string;

  constructor(path: string) {
    this.path = path;
  }

  /**
   * Loads the wallet state, or null if the wallet has not been initialized yet.
   */
  async load(): Promise<LocalWalletState | null> {
    try {
      const raw = await readFile(this.path, "utf8");
      return JSON.parse(raw) as LocalWalletState;
    } catch (error) {
      if (
        error instanceof Error &&
        "code" in error &&
        (error as NodeJS.ErrnoException).code === "ENOENT"
      ) {
        return null;
      }

      throw error;
    }
  }

  /**
   * Persists state through a temporary file followed by rename.
   *
   * This avoids many partial-write failures during local development. It is not
   * a substitute for encrypted or platform-secure storage in a production wallet.
   */
  async save(state: LocalWalletState): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });

    const temporaryPath = `${this.path}.tmp`;

    await writeFile(
      temporaryPath,
      `${JSON.stringify(state, null, 2)}\n`,
      "utf8",
    );

    await rename(temporaryPath, this.path);
  }
}
