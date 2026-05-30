# blockchain0x-x402 (Ruby)

[![Gem Version](https://badge.fury.io/rb/blockchain0x-x402.svg)](https://rubygems.org/gems/blockchain0x-x402)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Ruby ≥ 3.0](https://img.shields.io/badge/ruby-%E2%89%A53.0-brightgreen.svg)](#install)

\*\*Official Ruby port of [`@blockchain0x/x402`](https://www.npmjs.com/package/@blockchain0x/x402)

- `blockchain0x-x402` (Python) + `blockchain0x-x402-go`.\*\* Ships the
  wire primitives + a 402-aware HTTP client. Sibling gem to
  `blockchain0x`; install only when your service either issues
  x402-aware HTTP calls (a payer) or verifies inbound x402 payments
  (a recipient).

> Pre-release: `0.0.1.alpha.0` ships the wire primitives + the
> 402-aware `Client`. Rack middleware + Sinatra / Rails server
> adapters land in a follow-up row.

## Install

```bash
gem install blockchain0x-x402 --pre
```

Or in a `Gemfile`:

```ruby
gem 'blockchain0x-x402', '~> 0.0.1.alpha'
```

For the payer path you also need the main SDK:

```ruby
gem 'blockchain0x', '~> 0.0.1.alpha'
gem 'blockchain0x-x402', '~> 0.0.1.alpha'
```

For the recipient/verifier path you only need `blockchain0x-x402`.

## Verify an inbound x402 payment (recipient)

```ruby
class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token, only: :receive

  def receive
    payment = Blockchain0xX402::Wire.parse_payment_header(
      request.headers['X-Payment'],
    )
    # payment.payment_request_id, payment.tx_hash, payment.network ...
  rescue Blockchain0xX402::WireError => e
    render json: { code: e.code }, status: :bad_request
  end
end
```

The verifier:

- Accepts only `exact-usdc:<base64>` scheme; anything else rejects
  with `header.unknown_scheme`.
- Validates `txHash`, `payerAddress`, `amountUsdc`, and `network`
  shape; any drift rejects with `header.payload_malformed`.
- Lowercases hex fields so downstream comparisons against on-chain
  transaction logs are deterministic.

## Issue x402-aware HTTP calls (payer)

```ruby
require 'blockchain0x'
require 'blockchain0x_x402'

# Adapter glue: the x402 Client takes any object with .network,
# .payments_create(args), and .transactions_get(id). Wire the
# main SDK at your boundary.
sdk_adapter = Struct.new(:sdk) do
  def network = sdk.network
  def payments_create(agent_id:, to:, amount_wei:)
    sdk.payments.create(agent_id:, to:, amount_wei:)
  end
  def transactions_get(id) = sdk.transactions.get(id)
end

main = Blockchain0x::Client.new(api_key: ENV.fetch('BLOCKCHAIN0X_API_KEY'))
x402 = Blockchain0xX402::Client.new(sdk: sdk_adapter.new(main), agent_id: 'agt_...')
response = x402.post('https://service-b.com/llm-query', body: { ... })
raise unless response.success?
```

The wrapper handles a 402 response transparently:

1. Parses the 402 body and picks the requirement matching the SDK's network.
2. Calls `sdk.payments_create(...)` to settle on-chain. The main SDK
   auto-attaches an `Idempotency-Key` so a flaky retry does not
   double-spend.
3. Polls `sdk.transactions_get(payment_id)` every 1s for up to 30s
   until the transaction confirms.
4. Rebuilds the request with the `X-Payment` header and re-issues
   it once. The 200 response is returned to the caller.

Failures surface as `Blockchain0xX402::ClientError` with stable codes:

- `no_matching_requirement`
- `settlement_timeout`
- `chain_failed`

## Expose a paid HTTP route (recipient, server-side)

The `RackMiddleware` adapter gates routes against a static pricing
table. It mounts in front of any Rack app (Sinatra, Rails, plain
Rack) with the standard `use` directive.

```ruby
require 'sinatra'
require 'blockchain0x_x402/server'

server_sdk = ... # an object that responds to payment_requests_settle(...)

use Blockchain0xX402::Server::RackMiddleware,
  sdk: server_sdk,
  pricing: {
    'POST /llm-query' => Blockchain0xX402::Server::PricingEntry.new(
      amount_usdc: '0.10',
      pay_to_address: '0xabc...',
      payment_request_id: 'pr_demo',
    ),
  }

post '/llm-query' do
  payment = request.env['blockchain0x.x402_payment']
  # payment.payment_request_id, payment.tx_hash, ...
  json served: true
end
```

A miss in the pricing table is a no-op (the route is free). A hit
with no/invalid `X-Payment` short-circuits the response with HTTP
402 and the canonical `accepts[]` body. A hit with a valid payment
calls `sdk.payment_requests_settle(...)` to anchor trust, attaches
the parsed payment to `env['blockchain0x.x402_payment']`, and
forwards to the next middleware in the chain.

For Rails, add the same directive to `config/application.rb`:

```ruby
config.middleware.use Blockchain0xX402::Server::RackMiddleware,
  sdk: ..., pricing: { ... }
```

## Wire-format cross-compatibility

`Blockchain0xX402::Wire.build_payment_header` produces the same
base64 string as the Node, Python, and Go implementations for the
same input. The canonical JSON shape is:

```json
{
  "scheme": "exact-usdc",
  "version": 1,
  "paymentRequestId": "...",
  "txHash": "...",
  "payerAddress": "...",
  "amountUsdc": "...",
  "network": "..."
}
```

Keys are emitted in this exact order. Hex fields (`txHash`,
`payerAddress`) are lowercased before encoding.

## Failure-mode codes

| Code                       | When                                                       |
| -------------------------- | ---------------------------------------------------------- |
| `response.not_402`         | A non-402 response was passed to `parse_402_response`.     |
| `response.body_missing`    | 402 response body was empty.                               |
| `response.body_malformed`  | 402 body failed JSON parse or shape validation.            |
| `header.missing`           | X-Payment header was absent.                               |
| `header.malformed`         | X-Payment header was not `<scheme>:<base64-payload>`.      |
| `header.unknown_scheme`    | The scheme prefix was not `exact-usdc`.                    |
| `header.payload_malformed` | The decoded payload failed JSON parse or shape validation. |

Branch on `e.code` (a Blockchain0xX402::WireError instance).

## License

Apache-2.0.
