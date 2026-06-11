# Sub-plan 21.3 row C-7 (Ruby x402): the 402-aware HTTP client.
#
# Flow on the 402 branch:
#
#   1. Wire.parse_402_response(resp) -> X402Response
#   2. Pick the requirement whose `network` matches the SDK's bound
#      key mode (sk_test_* -> testnet, sk_live_* -> mainnet). No
#      match -> ClientError 'no_matching_requirement'.
#   3. sdk.payments_create(agent_id:, to:, amount_wei:) for the
#      chosen requirement. The SDK auto-attaches an Idempotency-
#      Key so a flaky retry does not double-spend.
#   4. Poll sdk.transactions_get(payment_id) every 1s up to 30s
#      until status == 'confirmed' AND tx_hash present.
#      Timeout -> ClientError 'settlement_timeout'.
#      Failure status -> ClientError 'chain_failed'.
#   5. Build the X-Payment header with Wire.build_payment_header
#      and re-issue the original request. Returns the retry's
#      Faraday::Response.
#
# Single retry only - if the second hop also returns 402 the
# wrapper propagates that response unchanged so the caller can
# decide whether to loop or surface to the user.
#
# Spend policy (sub-plan 27.1 A6): the 402 challenge is
# ATTACKER-CONTROLLED input. Callers MUST set `max_amount_wei`
# (and should set `allowed_pay_to`) so a malicious or compromised
# seller cannot drain the session allowance by quoting an
# arbitrary amount/recipient. The wrapper also enforces the
# requirement's maxAgeSeconds and refuses 402s that match no
# known network instead of guessing.
#
# The `sdk` is duck-typed: any object responding to
# `network`, `payments_create(args)`, and `transactions_get(id)`
# works. Tests mock the surface; production passes a
# Blockchain0x::Client instance with thin adapters.

# frozen_string_literal: true

require 'faraday'
require_relative 'errors'
require_relative 'wire'

module Blockchain0xX402
  class Client
    DEFAULT_CONFIRM_TIMEOUT_SECONDS = 30
    DEFAULT_CONFIRM_POLL_SECONDS    = 1.0

    # @param sdk [#network, #payments_create, #transactions_get]
    # @param agent_id [String] wallet that funds the on-chain payment
    # @param max_amount_wei [String, nil] spend ceiling in 6-dp USDC base
    #   units (27.1 A6). SET THIS - a 402 quoting more is refused with
    #   ClientError 'amount_over_cap' before any payment is created.
    # @param allowed_pay_to [Array<String>, nil] optional recipient
    #   allowlist (27.1 A6); compared case-insensitively.
    # @param confirm_timeout_seconds [Integer]
    # @param confirm_poll_seconds    [Float]
    # @param connection [Faraday::Connection, nil] test seam
    # @param sleep_proc [#call, nil] test seam for the poll loop
    # @param now_proc [#call, nil] test seam for the maxAgeSeconds clock
    def initialize(
      sdk:,
      agent_id:,
      max_amount_wei: nil,
      allowed_pay_to: nil,
      confirm_timeout_seconds: DEFAULT_CONFIRM_TIMEOUT_SECONDS,
      confirm_poll_seconds: DEFAULT_CONFIRM_POLL_SECONDS,
      connection: nil,
      sleep_proc: nil,
      now_proc: nil
    )
      if !max_amount_wei.nil? && !max_amount_wei.to_s.match?(/\A[0-9]+\z/)
        raise ArgumentError, 'max_amount_wei must be an integer string of 6-dp USDC base units'
      end

      @sdk = sdk
      @agent_id = agent_id
      @max_amount_wei = max_amount_wei&.to_s
      @allowed_pay_to = allowed_pay_to&.map(&:downcase)
      @confirm_timeout = confirm_timeout_seconds
      @confirm_poll = confirm_poll_seconds
      @conn = connection || Faraday.new
      @sleep = sleep_proc || Kernel.method(:sleep)
      @now = now_proc || method(:monotonic_now)
    end

    # Perform an HTTP request that handles 402 automatically.
    # @param method [Symbol] :get, :post, :patch, :delete
    # @param url    [String]
    # @param body   [Object, nil] body the request adapter will encode
    # @param headers [Hash<String, String>]
    # @return [Faraday::Response] the final response (after the retry on the 402 branch)
    def request(method, url, body: nil, headers: {})
      first = perform(method, url, body, headers)
      return first unless first.status == 402

      spec = Wire.parse_402_response(first)
      challenge_at = @now.call
      requirement = pick_requirement(spec.accepts)
      # 27.1 A6: the 402 is attacker-controlled input - enforce the
      # caller's spend policy BEFORE any payment is created.
      enforce_spend_policy(requirement)
      payment = @sdk.payments_create(
        agent_id: @agent_id,
        to: requirement.pay_to_address,
        amount_wei: requirement.amount_wei_usdc,
      )
      payment_id = payment.is_a?(Hash) ? (payment['id'] || payment[:id]) : payment.id
      raise ClientError.new('chain_failed', 'payments_create did not return an id.') if payment_id.nil?

      confirmed = wait_for_confirmation(payment_id)
      # 27.1 A6: a proof that confirmed after the requirement's
      # maxAgeSeconds window is refused client-side, not presented.
      if requirement.max_age_seconds
        elapsed = @now.call - challenge_at
        if elapsed > requirement.max_age_seconds
          raise ClientError.new(
            'stale_challenge',
            "challenge expired: confirmation took #{elapsed.round}s, " \
              "maxAgeSeconds is #{requirement.max_age_seconds}.",
          )
        end
      end

      header = Wire.build_payment_header(
        Wire::ExactUsdcPayment.new(
          scheme: 'exact-usdc',
          version: 1,
          payment_request_id: requirement.payment_request_id,
          tx_hash: tx_field(confirmed, :tx_hash, 'txHash').to_s,
          payer_address: tx_field(confirmed, :from_address, 'fromAddress').to_s,
          amount_usdc: wei_to_usdc(requirement.amount_wei_usdc),
          network: requirement.network,
        ),
      )
      perform(method, url, body, headers.merge('X-Payment' => header))
    end

    # Sugar: client.get / .post / .patch / .delete delegate to #request.
    %i[get post patch delete].each do |verb|
      define_method(verb) do |url, body: nil, headers: {}|
        request(verb, url, body: body, headers: headers)
      end
    end

    private

    def perform(method, url, body, headers)
      @conn.run_request(method, url, body, headers) do |req|
        # Faraday adapters serialize the body; leave the existing
        # block free for caller customisation in a future row.
      end
    end

    def pick_requirement(accepts)
      target = @sdk.network.to_s
      match = accepts.find { |r| r.network == target }
      return match if match

      raise ClientError.new(
        'no_matching_requirement',
        "402 accepts list has no entry for network=#{target.inspect}.",
      )
    end

    # 27.1 A6: spend-policy gate, evaluated before any payment exists.
    def enforce_spend_policy(requirement)
      if @max_amount_wei && Integer(requirement.amount_wei_usdc, 10) > Integer(@max_amount_wei, 10)
        raise ClientError.new(
          'amount_over_cap',
          "402 quotes #{requirement.amount_wei_usdc} wei USDC, above the " \
            "configured max_amount_wei #{@max_amount_wei}.",
        )
      end
      return unless @allowed_pay_to && !@allowed_pay_to.include?(requirement.pay_to_address.downcase)

      raise ClientError.new(
        'recipient_not_allowed',
        "402 pay-to address #{requirement.pay_to_address} is not in the " \
          'configured allowed_pay_to list.',
      )
    end

    def wait_for_confirmation(payment_id)
      deadline = monotonic_now + @confirm_timeout
      last = nil
      while monotonic_now < deadline
        tx = @sdk.transactions_get(payment_id)
        last = tx
        status = tx_field(tx, :status, 'status').to_s
        tx_hash = tx_field(tx, :tx_hash, 'txHash')
        return tx if status == 'confirmed' && !tx_hash.to_s.empty?
        raise ClientError.new('chain_failed', 'payment status flipped to `failed`.') if status == 'failed'

        @sleep.call(@confirm_poll)
      end
      raise ClientError.new(
        'settlement_timeout',
        "payment #{payment_id} did not confirm within #{@confirm_timeout}s " \
          "(last status: #{tx_field(last, :status, 'status').inspect}).",
      )
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def tx_field(tx, snake, camel)
      return nil if tx.nil?

      if tx.is_a?(Hash)
        tx[snake] || tx[snake.to_s] || tx[camel]
      elsif tx.respond_to?(snake)
        tx.public_send(snake)
      end
    end

    # USDC has 6 decimals on Base. Convert the wire's amount-wei
    # integer string to the human-readable decimal form (e.g.
    # "100000" -> "0.1"). Uses pure string arithmetic so no
    # digits are lost via float conversion.
    def wei_to_usdc(amount_wei)
      raise ClientError.new('chain_failed', "amount_wei is not numeric: #{amount_wei.inspect}") unless amount_wei.match?(/\A[0-9]+\z/)

      if amount_wei.length <= 6
        padded = amount_wei.rjust(6, '0')
        frac = padded.sub(/0+\z/, '')
        return '0' if frac.empty?

        "0.#{frac}"
      else
        whole = amount_wei[0...(amount_wei.length - 6)]
        frac = amount_wei[(amount_wei.length - 6)..].sub(/0+\z/, '')
        frac.empty? ? whole : "#{whole}.#{frac}"
      end
    end
  end
end
