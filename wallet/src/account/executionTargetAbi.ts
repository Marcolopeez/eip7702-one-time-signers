export const executionTargetAbi = [
  {
    type: "function",
    name: "number",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "lastSender",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "lastValue",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "setNumber",
    inputs: [{ name: "newNumber", type: "uint256" }],
    outputs: [{ name: "returnValue", type: "uint256" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "alwaysRevert",
    inputs: [],
    outputs: [],
    stateMutability: "pure",
  },
] as const;