# Antgrid licensing map

This map applies to the repository revision that contains it. The first commit
that changes the root `LICENSE.md` to MPL-2.0 is the relicensing boundary;
earlier tags and releases keep the licences under which they were published.

| Path | Licence |
| --- | --- |
| First-party source and documentation, except the rows below | [Mozilla Public License 2.0](LICENSE.md) |
| `relay/` | [Elastic License 2.0](relay/LICENSE.md) |
| `web/` | [Elastic License 2.0](web/LICENSE.md) |
| Product-identifying names and artwork listed in `BRAND-ASSETS-LICENSE.md` | [Antgrid Brand Assets Licence](BRAND-ASSETS-LICENSE.md) |
| `app/assets/fonts/` | SIL Open Font License 1.1 (`app/assets/fonts/OFL.txt`) |
| Third-party dependencies, fonts, artwork, native binaries, and vendored code | Their existing upstream terms; see [THIRD-PARTY.md](THIRD-PARTY.md) |

The repository uses standard `MPL-2.0`; Exhibit B is not attached. MPL obligations attach at file
level to covered files and modifications to those files. Merely using Antgrid
does not license or impose terms on user projects, prompts, company source,
separately written plugins, or independent larger works.

`packages/antgrid-wire` stays MPL-2.0 when linked into the ELv2 relay and web
services. Those services may be distributed as Larger Works, while modified
MPL files must remain available under MPL-2.0. Do not move relay or web
business logic into an MPL file merely to share it: that changes the source
availability obligations for that file.

The bridge contains separately licensed third-party components, including the
Anthropic Agent SDK. Describing the complete bridge executable as exclusively
MPL-2.0 is therefore inaccurate; its bundled notices distinguish Antgrid's MPL
files from embedded dependencies.

`REUSE.toml`, SPDX headers, and `npm run check:licenses` are the machine-readable
counterpart to this map. The nearest scoped licence controls where one exists.

MPL-2.0 does not require a per-file notice — §3.1 is satisfied by `LICENSE.md`
and this map — so `REUSE.toml` is the declaration for the tree. In-file SPDX
headers are carried only by `relay/` and `web/`, the ELv2 side of the licence
boundary, because a header is the only declaration that survives a file being
copied out of those directories into MPL territory. `packages/` carries none:
every package is unpublished (`private: true` / `publish_to: none`) and already
has its own root `LICENSE`. `check:licenses` requires a header in those two, and
rejects a header anywhere that disagrees with this map — elsewhere one is
optional.
