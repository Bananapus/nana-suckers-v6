# Audit Instructions

Audit this repo as cross-chain claim and recovery logic, not as a generic ERC-20 bridge.

## Audit Objective

Find issues that:

- break Merkle-root or nonce progression
- allow bad token mapping or peer assumptions
- permit double-claim or bad emergency exit behavior
- make non-atomic bridge semantics unsafe

## Scope

In scope:

- `src/JBSucker.sol`
- `src/JBSuckerRegistry.sol`
- bridge-specific implementations and deployers
- `src/utils/MerkleLib.sol`

## Start Here

1. `src/JBSucker.sol`
2. `src/JBSuckerRegistry.sol`
3. the relevant bridge-specific implementation

## Verification

- `npm install`
- `forge build`
- `forge test`
