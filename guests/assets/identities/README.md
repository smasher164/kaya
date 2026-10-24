# The apps' own declarations

`music.toml` — the music app's identity, a few hundred bytes of TOML in
`../identity.toml`'s shape (docs/app-identity-plan.md, "One file per app";
docs/media-player-plan.md M22 (6)). Written by this repo for this repo: no
upstream and no licence. Nothing generates it; to regenerate it, write it by
hand. A process takes it when `KAYA_IDENTITY` names `identities/music.toml`;
every other app is `../identity.toml`'s. tools/lib/packaging/identity.py's
`APPS` lists the files and tools/check-app-identity.py's C17 holds their
routes to them.
