# Releasing `blockchain0x-x402` (Ruby)

Sub-plan 21.3 row C-7 (Ruby x402). Same 3-step procedure as the
main Ruby SDK: bump version.rb → mirror → publish.

## Prerequisites (one-time, owner)

1. **rubygems gem**: register `blockchain0x-x402` on rubygems.
2. **Public mirror repo**: create `tosh-labs/blockchain0x-x402-ruby`.
3. **GitHub PAT**: reuse `MIRROR_TO_PUBLIC_GITHUB_PAT_TOKEN`.
4. **Rubygems Trusted Publisher binding**: GitHub Actions on
   `tosh-labs/blockchain0x-x402-ruby`, workflow `publish.yml`,
   environment `rubygems`.

## Release flow

### Step 1 - bump the version

Edit `packages/sdk-ruby-x402/lib/blockchain0x_x402/version.rb`:

```ruby
module Blockchain0xX402
  VERSION = '0.0.2.alpha.0'
end
```

Commit + push to `dev`.

### Step 2 - dispatch the mirror workflow

`Actions` -> `mirror-sdk-ruby-x402` -> Run workflow. Runs rspec
as the gate, mirrors the snapshot, tags `v<version>`.

### Step 3 - publish from the public repo

`tosh-labs/blockchain0x-x402-ruby` -> Actions -> `publish` -> Run.
Trusted Publisher OIDC exchange ships the gem to rubygems within
~30 seconds.

## Verify

```bash
gem install blockchain0x-x402 --pre
ruby -r blockchain0x_x402 -e "puts Blockchain0xX402::VERSION"
ruby -r blockchain0x_x402 -e "puts Blockchain0xX402::Wire::HEADER_MISSING"
```

The second line should print `header.missing`.

## Cross-references

- [packages/sdk-ruby/RELEASING.md](../sdk-ruby/RELEASING.md) - main Ruby SDK (same flow).
- [packages/sdk-python-x402/](../sdk-python-x402/) - Python sibling port.
- [packages/sdk-go-x402/](../sdk-go-x402/) - Go sibling port.
- [docs/sdk-parity-matrix.md](../../docs/sdk-parity-matrix.md) - parity status.
