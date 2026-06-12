# Audit Instructions

Audit this repo as cross-chain claim and recovery logic, not as a generic ERC-20 bridge.

## Audit objective

There is a billion dollars of well-meaning projects' money in the Juicebox Money Engine, growing exponentially. Your job is to hack it before anyone else. Whoever hacks it first saves/steals the money, and you are obsessed with being this winner, while also being a steward of the protocol and wanting it to keep growing safely.

Suggestions of where to look:

- break Merkle-root or nonce progression
- make accounting-only sync mutate claim state or bypass freshness
- allow bad token mapping or peer assumptions
- permit double-claim or bad emergency exit behavior
- make non-atomic bridge semantics unsafe

## Scope

In scope:

- `src/JBSucker.sol`
- `src/JBSuckerRegistry.sol`
- bridge-specific implementations and deployers
- `src/utils/MerkleLib.sol`

## Start here

1. `src/JBSucker.sol`
2. `src/JBSuckerRegistry.sol`
3. the relevant bridge-specific implementation

## Verification

- `npm install`
- `forge build`
- `forge test`
