# Architecture

## Purpose

`nana-suckers-v6` bridges Juicebox project positions across chains by turning local burns into claimable remote mints.

## System Overview

`JBSucker` handles prepare, relay, claim, token mapping, deprecation, and emergency exits. `JBSuckerRegistry` tracks deployments, deployer allowlists, and shared fee settings. Bridge-specific implementations handle transport details.

## Core Invariants

- Merkle trees stay append-only
- nonce progression stays monotonic
- token mapping stays coherent across peers
- claims and emergency exits do not double-spend
- outbox balance accounting stays consistent through send and recovery flows

## Trust Boundaries

- shared logic lives in `JBSucker`
- transport security lives in the bridge-specific implementation and external bridge counterparties
- registry decisions can widen or constrain the allowed deployment surface

## Security Model

- the biggest risks are non-atomic cross-chain state, bad token mapping, and broken peer assumptions
- bridge liveness and correct peer identity are real trust assumptions

## Source Map

- `src/JBSucker.sol`
- `src/JBSuckerRegistry.sol`
- `src/utils/MerkleLib.sol`
