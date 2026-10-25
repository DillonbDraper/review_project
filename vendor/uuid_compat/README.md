# UUID application compatibility

Hologram 0.12.1 depends on the old `uuid` package, while the Membrane stack
depends on its renamed successor, `elixir_uuid`. Both packages define `UUID`
and `UUID.Mixfile`; compiling them together can skip the old application or
overwrite modules. Cached build artifacts can conceal the conflict.

This local application preserves the `:uuid` application name required by
Hologram and depends on `:elixir_uuid` for the implementation. It defines no
UUID modules of its own. Mix includes `:elixir_uuid` in its runtime applications,
so Hologram and Membrane both use the same `UUID.uuid4/0` implementation.

When upgrading a checkout that has already compiled the old package, run
`mix deps.clean uuid --build` once to remove its stale modules across build
environments before recompiling. This keeps all dependency source files.

Remove this shim and the root dependency override when Hologram switches to
`elixir_uuid` or another UUID provider without colliding modules.
