export const OneTimeSignerAccountAbi = [
  {
    type: "function",
    name: "initialize",
    inputs: [
      { name: "firstAuthorizedSigner", type: "address" },
      { name: "initialRecoverySigners", type: "address[]" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "isInitialized",
    inputs: [],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isPaused",
    inputs: [],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "currentAuthorizedSigner",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isConsumedOrReservedSigner",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isActiveRecoverySigner",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "hashOperation",
    inputs: [
      {
        name: "operation",
        type: "tuple",
        components: [
          { name: "target", type: "address" },
          { name: "value", type: "uint256" },
          { name: "data", type: "bytes" },
          { name: "nextAuthorizedSigner", type: "address" },
          { name: "deadline", type: "uint256" },
        ],
      },
    ],
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "hashRecoveryOperation",
    inputs: [
      {
        name: "recoveryOperation",
        type: "tuple",
        components: [
          { name: "nextAuthorizedSigner", type: "address" },
          { name: "nextRecoverySigner", type: "address" },
          { name: "deadline", type: "uint256" },
        ],
      },
    ],
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "executeSignedAndRotate",
    inputs: [
      {
        name: "operation",
        type: "tuple",
        components: [
          { name: "target", type: "address" },
          { name: "value", type: "uint256" },
          { name: "data", type: "bytes" },
          { name: "nextAuthorizedSigner", type: "address" },
          { name: "deadline", type: "uint256" },
        ],
      },
      { name: "signature", type: "bytes" },
    ],
    outputs: [
      { name: "success", type: "bool" },
      { name: "result", type: "bytes" },
    ],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "signedRecovery",
    inputs: [
      {
        name: "recoveryOperation",
        type: "tuple",
        components: [
          { name: "nextAuthorizedSigner", type: "address" },
          { name: "nextRecoverySigner", type: "address" },
          { name: "deadline", type: "uint256" },
        ],
      },
      { name: "signature", type: "bytes" },
    ],
    outputs: [
      { name: "success", type: "bool" },
      { name: "result", type: "bytes" },
    ],
    stateMutability: "nonpayable",
  },
] as const;