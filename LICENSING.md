# Which licence covers what

Antgrid is not licensed under a single licence. This file is the map. It is
informative — the authority for any given file is the `LICENSE` in the nearest
enclosing directory, and [LICENSE.md](LICENSE.md) at the root where there is none.

| Path | Licence |
|---|---|
| `packages/antgrid-wire` | [Apache-2.0](packages/antgrid-wire/LICENSE) · [NOTICE](packages/antgrid-wire/NOTICE) |
| `packages/antgrid_relay_client` | [Apache-2.0](packages/antgrid_relay_client/LICENSE) · [NOTICE](packages/antgrid_relay_client/NOTICE) |
| `app/assets/fonts/` | SIL Open Font License 1.1 ([OFL.txt](app/assets/fonts/OFL.txt)) |
| Everything else — `bridge/`, `relay/`, `web/`, `app/`, `site/`, `evals/`, `packages/antgrid_eval_client` | [Elastic License 2.0](LICENSE.md) |

Bundled binaries, native code and the full dependency inventory are in
[THIRD-PARTY.md](THIRD-PARTY.md). Trademarks are granted by none of these
licences — see [TRADEMARK.md](TRADEMARK.md).

## Why two of our own packages are permissive

`antgrid-wire` is the wire protocol; `antgrid_relay_client` is the client-side
end-to-end encryption. They are Apache-2.0 so that anyone can build an Antgrid
client, and so the cryptography can be independently audited, reimplemented and
published against without asking us. Neither contains the licence-key
functionality — that is enforced server-side in `relay/` and `web/`.

`bridge/` is **not** among them and stays under the Elastic License 2.0.

## The one-way rule

Apache-2.0 code may be used inside an ELv2 component. **Nothing may move the
other way.** Relocating a file from `bridge/`, `relay/`, `web/` or `app/` into
either Apache package relicenses it permissively, and once published that cannot
be undone. It compiles, it passes CI, and nothing warns you.
