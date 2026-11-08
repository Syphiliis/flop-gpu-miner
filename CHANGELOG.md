# Changelog

## 0.1.1 (2026-11-08)

Follows FLOP's current miner guide and skill, read on 8 November 2026.

- Sponsorship: FLOP's limits page (`faucet.flop.network/limits`) is read before every request, and the request goes
  out only when `sponsor.miner.status` is `open` (with an operator grant, also when only the automatic cap is full).
  The request also waits when the sponsor's latest registrations on the devnet all failed, as from 5 to 7 November
  2026. FLOP's `retryAfterSeconds` is kept and honoured, by the timer and by `sponsor`. FLOP's `action` comes before
  the HTTP code: `fix_request` and `report_to_operator` stop the automatic retry, and so do a 403, a 422 or any other
  4xx; after such a refusal, neither the timer nor `restart` nor a re-run asks again, only `sponsor` or a new
  `--grant`. A 429, a 503 or any 5xx (a gateway's own error page too) is a "retry later". No more quick retry after
  a 503: the hourly timer looks again, for 7 days. A stopped miner is never asked for (it could not answer FLOP's
  calibration jobs once registered).
- After FLOP accepts, the installer waits up to two minutes for the miner to show on FLOP's explorer, and says so
  when it does not yet. A 409 counts as sponsored only if the miner is on the explorer; otherwise the installer stops
  and says to report it. A 503 is shown as "unavailable", no longer as "full". `status` shows what FLOP's limits page
  said, FLOP's wait if any, a refusal, a hold while stopped, and, for a retired miner, only that it is retired.
- An operator grant goes past `automatic_full` and `daily_limit_reached`, as the pack README says.
- FLOP's pack `flop-miner-pack-devnet-ts-20261106`, the one FLOP's miner guide names (it changes only the
  sponsorship request scripts and the README, with the same request for a miner).
- FLOP's images pinned by version and digest, as FLOP's miner guide asks, instead of the pack's floating `:stable`
  tags: CLI 0.1.220, worker 0.1.286, backend 0.1.239 (what `:stable` named on 8 November 2026). A re-run pins a
  machine installed by 0.1.0.
- Guides: no invitation needed since 2 November 2026; at most 40 sponsored miners still being measured and 100 new
  miners per 24 hours (FLOP's miner guide); FLOP's access request channel for a refusal.
- Test bench: 291 checks, among them a timeout of a pack script and the removal of the container it leaves.

## 0.1.0 (2026-11-06)

First version.

- FLOP's pack `flop-miner-pack-devnet-ts-20261103c`, pinned by its SHA-256 fingerprint as FLOP publishes it.
- Worker and GPU backend on one machine, as in the pack README; account, model, settings and start in one command.
- Public address through the pack's Caddy sidecar (`<ip>.sslip.io` or `--domain`), or a Cloudflare quick tunnel
  (`--tunnel`), offered when the miner works but the machine cannot get its certificate; `--public` goes back.
- Sponsorship asked once the miner answers, again within a minute on a 503, then every hour for 7 days while FLOP's
  sponsor is full; `restart` asks again for a miner that is not sponsored.
- Safe re-runs: the miner account is never replaced (a missing account is reported, not redrawn), state flags belong
  to one account, a retired miner is not restarted, a stopped miner stays stopped in tunnel mode, an operator grant
  must name this miner, and a new FLOP pack brings its settings while the account, tokens and address stay.
- Commands: `status`, `logs`, `restart`, `stop`, `sponsor`, `backup`, `retire`, `uninstall`.
- Checked on a test bench that simulates the outside tools (`tests/run.sh`, 180 checks); no complete run on a real GPU
  machine reported yet.
