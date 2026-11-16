# Held fallbacks: no try/catch branch may redirect value

- [x] JBSucker.toRemote: a `toRemoteFee` the fee project could not take is still retained per caller, but the
      retained amount is now paid to the fee project by `payRetainedToRemoteFeeOf(account)` (anyone can call, the
      caller stays the fee beneficiary) instead of being refunded to the caller.
- [ ] Tests: out of scope for this PR (`claimRetainedToRemoteFee` tests need rewriting).
