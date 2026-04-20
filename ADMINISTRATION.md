# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Cross-chain claim movement, token mapping, fees, and deprecation controls |
| Control posture | Mixed registry-owner, project-permission, and bridge-specific trust |
| Highest-risk actions | Wrong token mapping, wrong peer assumptions, and bad emergency or deprecation handling |
| Recovery posture | Often one-way; many recovery paths are intentionally irreversible |

## Purpose

This repo controls the shared lifecycle around bridging project positions, not just the transport call itself.

## Control Model

- registry owner controls shared fee settings and deployer allowlists
- project-level permissions control token mapping and safety paths
- bridge-specific implementations inherit external trust assumptions

## Recovery

- emergency hatch and deprecation are the main recovery tools
- both are intentionally conservative and often one-way

