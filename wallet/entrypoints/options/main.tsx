import React from "react";
import { createRoot } from "react-dom/client";
import WalletApp from "../../src/apps/extension/ui/WalletApp.js";
import "../../src/apps/extension/ui/style.css";

const root = document.getElementById("root");

if (!root) {
  throw new Error("Dashboard root element not found");
}

createRoot(root).render(
  <React.StrictMode>
    <WalletApp mode="dashboard" />
  </React.StrictMode>,
);
