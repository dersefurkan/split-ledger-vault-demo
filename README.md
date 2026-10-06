# Split-ledger vault lab

[![ci](https://github.com/dersefurkan/split-ledger-vault-demo/actions/workflows/ci.yml/badge.svg)](https://github.com/dersefurkan/split-ledger-vault-demo/actions/workflows/ci.yml)

Local Foundry lab for money-moving identity bugs, in two shapes:

1. **Split ledgers** — two ledgers credit the same deposit, and each withdrawal path burns only one.
2. **Missing cursor** — a withdrawal queue tracks what a request is worth, but not what it already paid.

This is a delivery sample, not a live exploit. The vulnerable vaults are teaching contracts. The patched vaults are proven with the same tests and with stateful invariants.

## Bug class

`ReceiptSplitVault` records a deposit twice:

| Ledger | Storage | Withdrawal path |
| --- | --- | --- |
| A | `shares[user]` | `withdrawShares` burns only A |
| B | `receipts[id] = {owner, amount, spent}` | `redeemReceipt` burns only B |

One deposit, two independent claims on the same asset pile. This is the same shape as production losses in receipt-id withdrawals, queue cursors, fast/slow paths, and trusted-forwarder flows where the protocol forgets which identity actually moves the money.

## Reproduce (local only)

Requires [Foundry](https://getfoundry.sh). No RPC, no keys, no live transactions.

```bash
forge test            # full suite
forge test -vv        # with traces
```

Directed PoC — 100 deposited, 200 extracted:

```bash
forge test --match-contract SplitLedgerPoC -vv
```

```
[PASS] test_double_pay_via_split_ledgers()
    attacker deposited 100, extracted 200
    victim share record still says 100 — backing is 0
```

## The fix, proven the same way

`ReceiptBoundVault` keeps both exits. They spend one balance. `shares` is what is still claimable. Each receipt stores how much of it was already paid. `withdrawShares` spends receipts oldest-first. `redeemReceipt` pays only that receipt's remainder.

```bash
forge test --match-test test_bound_share_exit_then_receipt_pays_only_the_rest -vv
```

```
[PASS] test_bound_share_exit_then_receipt_pays_only_the_rest()
    share exit pays 40
    receipt exit pays 60, not the original 100
    the other depositor still withdraws 100
```

Deleting `withdrawShares` would also stop the double pay. That is not the fix. Production keeps both doors. The bound vault does too.

```bash
forge test --match-contract BoundLedgerInvariant -vv
```

Stateful fuzzing (`runs = 64`, `depth = 12`) drives two actors through both exits. After every call:

1. Neither actor has withdrawn more than they deposited.
2. Vault balance equals both actors' deposits minus withdrawals.
3. The receipt sum (`openClaims`) equals the counter (`totalOpen`). A share exit that forgot to mark receipts paid breaks this even when the token balance still looks fine.

The directed PoC shows the split vault violating conservation. The same sequences hold on the bound vault.

## Shape 2 — the missing claimed cursor

`EpochQueueVaultVulnerable` is a maturity-gated withdrawal queue: `request` locks funds, `advanceEpoch` matures them, `claim(id, amount)` pays. The bug is what is *not* there — no per-request `claimed` cursor:

```
claim(id, amount):  require(amount <= r.amount)   // pays up to the FULL amount, every call
```

One matured request is claimable at full value until the vault is empty; the last claimants meet a zero balance.

```bash
forge test --match-contract EpochQueuePoC -vv
```

```
[PASS] test_full_reclaim_drains_vulnerable_queue()
  alice requested: 100.000000000000000000
  alice claimed  : 200.000000000000000000
  vault balance  : 0.000000000000000000   (bob's matured claim now reverts)
```

`EpochQueueVaultBound` writes the cursor: `claimed += amount`, claims capped at the remainder. Same PoC holds: alice's second claim reverts, bob is paid in full.

## Watching the cursor suite fail (opt-in)

The epoch handler runs both vaults under the same invariants (64 runs × 12 calls). Gated so default CI stays green:

```bash
DEMO_RUN_KILLED=1 forge test --match-contract VulnerableEpochQueueInvariant -vv
```

| Invariant | Cursor-bound queue | Cursor-less queue |
| --- | --- | --- |
| `withdrawals_cannot_exceed_deposits` | HOLDS | holds* |
| `vault_balance_matches_ledger` | HOLDS | holds* |
| `no_request_overpays` | HOLDS | **FAILS** |

\*Token-level conservation **cannot** catch this bug with one solvent vault: the balance floors at zero and the final over-claim simply reverts. The leak lives one level down, in per-request accounting — which is why the suite tracks it with per-request ghost variables. Reviews that only check "withdrawn ≤ deposited" sign off on this bug.

## Layout

```
src/ReceiptSplitVault.sol   # MockAsset + split vault + bound vault
src/EpochQueueVault.sol     # cursor-less queue + cursor-bound queue + shared interface
test/SplitLedgerPoC.t.sol   # directed PoC and edge cases
test/EpochQueuePoC.t.sol    # directed cursor-drain PoC (both variants)
test/EpochQueueUnit.t.sol   # maturity / ownership / partial-claim / keeper checks + fuzz
test/Invariant.t.sol        # handler + bound-vault invariants
test/EpochQueueInvariant.t.sol  # queue handler + invariants (killed variant gated)
```

`forge test` — 20 passed, 1 gated suite skipped.

## What a full engagement adds

- Fork tests against a pinned commit or live deployment (authorized scope only)
- Invariants on the actual money-moving identity: receipt id, epoch index, match id, withdrawal cursor, forwarder sender
- Upgrade-diff pass if production shipped recently
- Every finding delivered as a failing-then-fixed test. `forge test` is the report.

## Scope and use

Authorized research and teaching only. Do not point this suite at systems you do not own or are not contracted to test. See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

---

Hired version of this shape: one contract, five days, $1,500, private Foundry repo. [dersefurkan.github.io](https://dersefurkan.github.io) · Telegram [@FURY_Fn](https://t.me/FURY_Fn) · dersefurkan32@gmail.com
