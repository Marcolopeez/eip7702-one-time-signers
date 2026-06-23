import { defineConfig } from "wxt";

export default defineConfig({
  modules: ["@wxt-dev/module-react"],
  manifest: {
    name: "Ephemeral Key Wallet",
    description:
      "Experimental EIP-7702 one-time-key wallet for local development.",
    version: "0.1.0",
    permissions: ["storage"],
    host_permissions: ["http://127.0.0.1/*", "http://localhost/*"],
  },
});
