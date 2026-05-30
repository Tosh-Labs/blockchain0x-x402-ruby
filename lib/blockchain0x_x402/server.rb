# x402 Rack middleware (sub-plan 21.3 row C-7 follow-up).
#
# Drop in front of any Rack app (Sinatra, Rails, plain Rack) to gate
# routes against a configured pricing table. Same shape as the
# Fastify / Express / Starlette / FastAPI / Flask / net-http
# adapters; the wire format is byte-equivalent so a Ruby server
# accepts headers from any cross-language payer.
#
# Usage (Sinatra / plain Rack):
#
#     use Blockchain0xX402::Server::RackMiddleware,
#       sdk: server_sdk,
#       pricing: {
#         'POST /llm-query' => Blockchain0xX402::Server::PricingEntry.new(
#           amount_usdc: '0.10',
#           pay_to_address: '0xabc...',
#           payment_request_id: 'pr_demo',
#         ),
#       }
#
# Usage (Rails):
#
#     # config/application.rb
#     config.middleware.use Blockchain0xX402::Server::RackMiddleware,
#       sdk: server_sdk,
#       pricing: { ... }
#
# A miss in the pricing table is a no-op (the route is free). A hit
# with no/invalid `X-Payment` short-circuits the response with
# HTTP 402 and the canonical accepts[] body. A hit with a valid
# payment calls `sdk.payment_requests_settle(...)` to anchor trust,
# stashes the parsed payment under `env['blockchain0x.x402_payment']`
# for downstream handlers, and forwards to the next middleware.

# frozen_string_literal: true

require 'json'

require_relative 'errors'
require_relative 'wire'

module Blockchain0xX402
  module Server
    PricingEntry = Struct.new(
      :amount_usdc,
      :pay_to_address,
      :payment_request_id,
      :network,
      keyword_init: true,
    ) do
      # Optional `network` defaults to nil so the middleware can fall
      # back to the global DefaultNetwork. Struct's keyword_init
      # already nils unspecified fields; this initialiser only
      # exists to enforce the three required ones.
      def initialize(amount_usdc:, pay_to_address:, payment_request_id:, network: nil)
        super
      end
    end

    CAIP2_BY_NETWORK = {
      'mainnet' => 'eip155:8453',
      'testnet' => 'eip155:84532',
    }.freeze

    PAYMENT_ENV_KEY = 'blockchain0x.x402_payment'

    # Convert a human decimal USDC amount ("0.10") to a 6-decimal
    # wei integer string ("100000"). Mirrors the equivalent helper
    # in @blockchain0x/x402's shared.ts.
    def self.usdc_decimal_to_wei(decimal)
      whole, frac = decimal.split('.', 2)
      whole = '0' if whole.nil? || whole.empty?
      frac ||= ''
      frac = frac.ljust(6, '0')[0, 6]
      (whole.to_i * 1_000_000 + frac.to_i).to_s
    end

    # Build a PaymentRequirement struct from a pricing entry +
    # network fallback. Exported so alternative adapters (Rails
    # ActionController::API, Grape) can reuse it.
    def self.build_requirement(entry, default_network)
      network = entry.network || default_network || 'mainnet'
      Wire::PaymentRequirement.new(
        scheme: 'exact-usdc',
        network: network,
        chain_id: CAIP2_BY_NETWORK.fetch(network),
        pay_to_address: entry.pay_to_address,
        amount_wei_usdc: usdc_decimal_to_wei(entry.amount_usdc),
        payment_request_id: entry.payment_request_id,
        max_age_seconds: nil,
      )
    end

    # Render the canonical 402 body. Used internally by the
    # middleware; exported for alternative adapters.
    def self.build_402_body(entry:, resource:, default_network:, max_age_seconds:)
      req = build_requirement(entry, default_network)
      req.max_age_seconds = max_age_seconds
      Wire::X402Response.new(version: 1, resource: resource, accepts: [req])
    end

    def self.x402_response_to_hash(resp)
      {
        'version' => resp.version,
        'resource' => resp.resource,
        'accepts' => resp.accepts.map do |r|
          h = {
            'scheme' => r.scheme,
            'network' => r.network,
            'chainId' => r.chain_id,
            'payToAddress' => r.pay_to_address,
            'amountWeiUsdc' => r.amount_wei_usdc,
            'paymentRequestId' => r.payment_request_id,
          }
          h['maxAgeSeconds'] = r.max_age_seconds unless r.max_age_seconds.nil?
          h
        end,
      }
    end

    # Typed verify result. Returns one of:
    #   { ok: true, payment: ExactUsdcPayment }
    #   { ok: false, reason: 'header_missing' | 'header_malformed' |
    #     'requirement_mismatch' | 'settle_rejected', message: String }
    VerifyOk = Struct.new(:payment) do
      def ok?; true; end
    end
    VerifyFailure = Struct.new(:reason, :message) do
      def ok?; false; end
    end

    def self.verify_x_payment(sdk:, header:, entry:)
      if header.nil? || header.empty?
        return VerifyFailure.new('header_missing', 'X-Payment header is required.')
      end

      begin
        payment = Wire.parse_payment_header(header)
      rescue WireError => e
        return VerifyFailure.new('header_malformed', e.message)
      end

      if payment.payment_request_id != entry.payment_request_id
        return VerifyFailure.new(
          'requirement_mismatch',
          "X-Payment references #{payment.payment_request_id}, " \
            "route quoted #{entry.payment_request_id}.",
        )
      end

      begin
        sdk.payment_requests_settle(
          payment_request_id: payment.payment_request_id,
          body: {
            'txHash' => payment.tx_hash,
            'payerAddress' => payment.payer_address,
            'amountUsdcVerified' => payment.amount_usdc,
          },
        )
      rescue StandardError => e
        msg = e.message
        msg = 'settle() rejected the proof.' if msg.nil? || msg.empty?
        return VerifyFailure.new('settle_rejected', msg)
      end

      VerifyOk.new(payment)
    end

    # Rack middleware. Build at process boot, then `use` in front
    # of the application.
    class RackMiddleware
      # @param app [#call] downstream Rack app
      # @param sdk [#payment_requests_settle] backend settle bridge
      # @param pricing [Hash{String=>PricingEntry}] keyed by '<METHOD> <PATH>'
      # @param default_network [String] 'mainnet' (default) or 'testnet'
      # @param max_age_seconds [Integer] how long a chain confirmation
      #   may live before the payer's wrapper re-pays
      def initialize(app, sdk:, pricing:, default_network: 'mainnet', max_age_seconds: 60)
        @app = app
        @sdk = sdk
        @pricing = pricing
        @default_network = default_network
        @max_age_seconds = max_age_seconds
      end

      def call(env)
        method = env['REQUEST_METHOD'] || 'GET'
        path = env['PATH_INFO'] || env['REQUEST_PATH'] || ''
        key = "#{method.upcase} #{path}"
        entry = @pricing[key]
        return @app.call(env) if entry.nil?

        header = env['HTTP_X_PAYMENT']
        outcome = Server.verify_x_payment(sdk: @sdk, header: header, entry: entry)

        if outcome.ok?
          env[PAYMENT_ENV_KEY] = outcome.payment
          return @app.call(env)
        end

        body = Server.build_402_body(
          entry: entry,
          resource: "#{method} #{path}",
          default_network: @default_network,
          max_age_seconds: @max_age_seconds,
        )
        payload = Server.x402_response_to_hash(body)
        payload['error'] = { 'reason' => outcome.reason, 'message' => outcome.message }
        raw = JSON.generate(payload)
        [
          402,
          {
            'Content-Type' => 'application/json',
            'Content-Length' => raw.bytesize.to_s,
          },
          [raw],
        ]
      end
    end
  end
end
