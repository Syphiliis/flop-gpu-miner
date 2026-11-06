# Changelog

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
