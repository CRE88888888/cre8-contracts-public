# Vendored eth-infinitism account-abstraction (v0.7.0)

TESTNET ONLY (chain 97, cre8-contracts#30). `VerifyingPaymaster` and the files it imports, copied unmodified
from https://github.com/eth-infinitism/account-abstraction at tag `v0.7.0`, commit
`7af70c8993a6f42973f520ae0752386a5032abe7` (the EntryPoint v0.7 release, `0x0000000071727De22E5E9d8BAf0edAc6f37da032`).
The directory layout (`core/`, `interfaces/`, `samples/`) is kept so the relative imports resolve as upstream.
OpenZeppelin imports resolve to this repo's vendored 5.4.0.

License: GPL-3.0 (upstream, kept in each file's SPDX header). These files are only used by the chain 97
testnet deployment; nothing under `src/atp/` imports them.
