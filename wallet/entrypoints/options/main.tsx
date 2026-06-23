import React from "react";
import { createRoot } from "react-dom/client";
import WalletApp from "../../src/extension/ui/WalletApp.js";
import "../../src/extension/ui/style.css";

const root = document.getElementById("root");

if (!root) {
  throw new Error("Dashboard root element not found");
}

createRoot(root).render(
  <React.StrictMode>
    <WalletApp mode="dashboard" />
  </React.StrictMode>,
);
