# Security Policy

## Status

This repository is an experimental research prototype for a one-time signer account/wallet design based on EIP-7702, EIP-712, and one-time ECDSA signer keys.

It is:

* not audited;
* not production-ready;
* not production wallet software;
* not safe for custody of real assets;
* intended for research, testing, and technical/security review only.

The project explores a narrow security objective:

> An ECDSA key that has produced a valid signature must not remain able to control the account.

This does not provide full post-quantum security. The **system still uses ECDSA** and assumes a post-quantum threat model where a CRQC-capable adversary may compromise an ECDSA key after observing a valid signature.

Do not use this project with mainnet assets, production accounts, production mnemonics, or any account that cannot be safely lost.

The current implementation is designed for experimentation. It does not include production-grade key custody, encrypted storage, hardened browser-extension boundaries, formal verification, audited recovery UX, or operational safeguards for real deployments. Also, **EIP-7702 delegation remains ultimately controlled by the original EOA authority key; the prototype assumes a future mechanism such as [EIP-7851](https://eips.ethereum.org/EIPS/eip-7851) to disable that authority**.

## In-scope security areas

Reports are in scope when they affect the security properties claimed by this prototype.

Security-sensitive areas include:

* `src/OneTimeSignerAccount.sol`;
* EIP-7702 delegated execution assumptions;
* protection against direct use of the implementation contract;
* initialization of delegated EOA storage;
* signer rotation before external calls;
* prevention of signer reuse through consumed/reserved key tracking;
* pause behavior when the account cannot rotate safely;
* blocking normal execution while paused;
* recovery through one-time recovery signers;
* consumption and deactivation of recovery signers;
* partial or failed recovery behavior;
* EIP-712 hashing and domain separation;
* signature replay across accounts, chains, domains, or delegated EOAs;
* wallet local state transitions after signing;
* immediate local key burning before broadcast;
* pending operation and pending recovery state;
* sync and reconciliation against on-chain storage;
* refusal to sign after unsafe local/on-chain desynchronization;
* browser extension message handling;
* browser storage assumptions and accidental signing from stale or corrupted state.

Examples of useful vulnerability reports:

* a consumed signer can authorize the account again;
* a valid observed signature can be replayed after rotation;
* a target revert rolls back signer consumption;
* the account fails to pause after an invalid next signer;
* normal execution remains possible while paused;
* a recovery signer can be reused;
* recovery can silently leave the wallet in an unsafe state;
* EIP-712 signatures are bound to the implementation contract instead of the delegated EOA;
* the wallet signs with a locally burned or on-chain consumed key;
* `sync()` accepts an unsafe reconciliation;
* browser state corruption causes unsafe signing instead of refusal;

## Out-of-scope or known limitations

The following are known limitations of the prototype and are not considered vulnerabilities by themselves:

* the project is not production-ready;
* the system does not provide full post-quantum security;
* the account still relies on ECDSA;
* compromise of the EIP-7702 authority key is out of scope;
* compromise of the mnemonic;
* the current wallet does not provide production-grade secret storage yet;
* browser storage is not treated as secure storage;
* the browser extension prototype may store development secrets in local extension storage;
* phishing, malicious UI prompts, or intentionally signing malicious calldata are out of scope;
* chain reorgs, censorship, transaction non-inclusion, dropped transactions, or general denial of service are out of scope;
* multi-device coordination is not implemented yet;
* production recovery UX is not implemented yet;
* formal verification is not implemented.

Reports about these areas are still welcome if they show that the implementation violates one of the project’s stated invariants, not merely that the prototype lacks production hardening.

## Reporting a vulnerability

Please report vulnerabilities privately first.

Private disclosure contact:

```text
marcolopezg26@gmail.com
```


## Related documentation

See [`docs/02-threat-model.md`](docs/02-threat-model.md) for the full threat model, core assumptions, security invariants, and known limitations.