# Sub-plan 21.3 row C-7 (Ruby x402). Ports the Node + Python + Go
# wire primitives byte-for-byte.
#
# Three exports:
#
#   parse_402_response(http_response) -> X402Response
#   build_payment_header(payment_hash_or_struct) -> "exact-usdc:<base64>"
#   parse_payment_header(string) -> ExactUsdcPayment
#
# Plus the typed error class Blockchain0xX402::WireError with one of
# 7 stable codes (response.not_402, response.body_missing,
# response.body_malformed, header.missing, header.malformed,
# header.unknown_scheme, header.payload_malformed).
#
# The wire form follows Coinbase's x402 reference:
#
#   X-Payment: <scheme>:<base64(payload)>
#
# Wire compatibility: the JSON output of build_payment_header is
# byte-equivalent with the Node, Python, and Go implementations.
# The canonical key order (scheme, version, paymentRequestId,
# txHash, payerAddress, amountUsdc, network) is emitted manually
# via String#<< so the wire shape does not depend on Ruby Hash
# insertion-order semantics.

# frozen_string_literal: true

require 'base64'
require 'json'
require_relative 'errors'

module Blockchain0xX402
  module Wire
    # Failure-code constants mirror the Node + Python + Go ports.
    RESPONSE_NOT_402         = 'response.not_402'
    RESPONSE_BODY_MISSING    = 'response.body_missing'
    RESPONSE_BODY_MALFORMED  = 'response.body_malformed'
    HEADER_MISSING           = 'header.missing'
    HEADER_MALFORMED         = 'header.malformed'
    HEADER_UNKNOWN_SCHEME    = 'header.unknown_scheme'
    HEADER_PAYLOAD_MALFORMED = 'header.payload_malformed'

    VALID_NETWORKS = %w[mainnet testnet].freeze
    RE_TX_HASH = /\A0x[0-9a-fA-F]{64}\z/
    RE_PAYER   = /\A0x[0-9a-fA-F]{40}\z/
    RE_AMOUNT  = /\A[0-9]+(?:\.[0-9]+)?\z/
    RE_WEI     = /\A[0-9]+\z/

    # @!attribute [r] scheme @return [String] 'exact-usdc'
    # @!attribute [r] network @return [String] 'mainnet' | 'testnet'
    # @!attribute [r] chain_id @return [String] CAIP-2 chain id
    # @!attribute [r] pay_to_address @return [String]
    # @!attribute [r] amount_wei_usdc @return [String] integer text
    # @!attribute [r] payment_request_id @return [String]
    # @!attribute [r] max_age_seconds @return [Integer, nil]
    PaymentRequirement = Struct.new(
      :scheme,
      :network,
      :chain_id,
      :pay_to_address,
      :amount_wei_usdc,
      :payment_request_id,
      :max_age_seconds,
      keyword_init: true,
    )

    X402Response = Struct.new(:version, :resource, :accepts, keyword_init: true)

    # Decoded X-Payment header payload (scheme=exact-usdc).
    ExactUsdcPayment = Struct.new(
      :scheme,
      :version,
      :payment_request_id,
      :tx_hash,
      :payer_address,
      :amount_usdc,
      :network,
      keyword_init: true,
    )

    class << self
      # @param response [#status, #body, ...] any HTTP response that
      #   exposes a numeric status and a JSON-parseable body. Faraday
      #   responses, Net::HTTPResponse via Net::HTTP, and Webmock
      #   stubs all work; for raw hashes use {parse_402_body} instead.
      # @return [X402Response]
      # @raise [WireError] on any shape problem
      def parse_402_response(response)
        status = response.respond_to?(:status) ? response.status : response.code.to_i
        if status != 402
          raise WireError.new(RESPONSE_NOT_402, "Expected status 402, got #{status}.")
        end

        body = response.body
        body = JSON.parse(body) if body.is_a?(String)
        parse_402_body(body)
      rescue JSON::ParserError
        raise WireError.new(RESPONSE_BODY_MALFORMED, '402 response body is not JSON.')
      end

      def parse_402_body(body)
        unless body.is_a?(Hash)
          raise WireError.new(RESPONSE_BODY_MISSING, '402 response body is missing or non-object.')
        end
        unless body['version'] == 1
          raise WireError.new(RESPONSE_BODY_MALFORMED, "Unsupported x402 version: #{body['version'].inspect}.")
        end
        unless body['resource'].is_a?(String) && !body['resource'].empty?
          raise WireError.new(RESPONSE_BODY_MALFORMED, '402 body missing `resource` string.')
        end
        accepts_raw = body['accepts']
        unless accepts_raw.is_a?(Array) && !accepts_raw.empty?
          raise WireError.new(RESPONSE_BODY_MALFORMED, '402 body missing `accepts` array or empty.')
        end
        accepts = accepts_raw.map do |entry|
          unless valid_requirement?(entry)
            raise WireError.new(RESPONSE_BODY_MALFORMED, '402 `accepts` entry is not a recognised payment requirement.')
          end
          PaymentRequirement.new(
            scheme: 'exact-usdc',
            network: entry['network'],
            chain_id: entry['chainId'],
            pay_to_address: entry['payToAddress'],
            amount_wei_usdc: entry['amountWeiUsdc'],
            payment_request_id: entry['paymentRequestId'],
            max_age_seconds: entry['maxAgeSeconds'].is_a?(Numeric) ? entry['maxAgeSeconds'].to_i : nil,
          )
        end
        X402Response.new(version: 1, resource: body['resource'], accepts: accepts.freeze)
      end

      # Encode a payment payload as an X-Payment header value.
      # Accepts either an ExactUsdcPayment struct OR a Hash with
      # the same keys (snake_case OR camelCase) for caller
      # convenience.
      #
      # @raise [WireError] on unknown scheme
      def build_payment_header(payment)
        scheme, version, payment_request_id, tx_hash, payer_address, amount_usdc, network =
          coerce_payment(payment)

        if scheme != 'exact-usdc'
          raise WireError.new(HEADER_UNKNOWN_SCHEME, "build_payment_header: unsupported scheme #{scheme.inspect}.")
        end

        # Pin the JSON key order explicitly. Ruby >= 1.9 Hashes are
        # insertion-ordered but writing the JSON manually makes the
        # wire contract obvious from this file alone.
        json = String.new
        json << '{"scheme":"exact-usdc","version":' << version.to_s
        json << ',"paymentRequestId":' << JSON.generate(payment_request_id)
        json << ',"txHash":' << JSON.generate(tx_hash.downcase)
        json << ',"payerAddress":' << JSON.generate(payer_address.downcase)
        json << ',"amountUsdc":' << JSON.generate(amount_usdc)
        json << ',"network":' << JSON.generate(network)
        json << '}'

        "exact-usdc:#{Base64.strict_encode64(json)}"
      end

      def parse_payment_header(value)
        if !value.is_a?(String) || value.empty?
          raise WireError.new(HEADER_MISSING, 'X-Payment header is missing or empty.')
        end
        sep = value.index(':')
        if sep.nil? || sep < 1 || sep == value.length - 1
          raise WireError.new(HEADER_MALFORMED, 'X-Payment header must be `<scheme>:<base64-payload>`.')
        end
        scheme = value[0...sep]
        if scheme != 'exact-usdc'
          raise WireError.new(HEADER_UNKNOWN_SCHEME, "Unsupported X-Payment scheme: #{scheme}.")
        end
        b64 = value[(sep + 1)..]
        text = begin
          Base64.strict_decode64(b64)
        rescue ArgumentError
          raise WireError.new(HEADER_PAYLOAD_MALFORMED, 'X-Payment payload is not valid base64.')
        end
        parsed = begin
          JSON.parse(text)
        rescue JSON::ParserError
          raise WireError.new(HEADER_PAYLOAD_MALFORMED, 'X-Payment payload is not valid JSON.')
        end
        unless parsed.is_a?(Hash)
          raise WireError.new(HEADER_PAYLOAD_MALFORMED, 'X-Payment payload is not an object.')
        end
        unless valid_payload?(parsed)
          raise WireError.new(HEADER_PAYLOAD_MALFORMED, 'X-Payment payload failed shape validation.')
        end

        ExactUsdcPayment.new(
          scheme: 'exact-usdc',
          version: 1,
          payment_request_id: parsed['paymentRequestId'],
          tx_hash: parsed['txHash'].downcase,
          payer_address: parsed['payerAddress'].downcase,
          amount_usdc: parsed['amountUsdc'],
          network: parsed['network'],
        )
      end

      private

      def valid_requirement?(entry)
        entry.is_a?(Hash) &&
          entry['scheme'] == 'exact-usdc' &&
          entry['network'].is_a?(String) &&
          VALID_NETWORKS.include?(entry['network']) &&
          entry['chainId'].is_a?(String) &&
          entry['payToAddress'].is_a?(String) &&
          entry['amountWeiUsdc'].is_a?(String) &&
          RE_WEI.match?(entry['amountWeiUsdc']) &&
          entry['paymentRequestId'].is_a?(String)
      end

      def valid_payload?(p)
        p['scheme'] == 'exact-usdc' &&
          p['version'] == 1 &&
          p['paymentRequestId'].is_a?(String) &&
          p['txHash'].is_a?(String) && RE_TX_HASH.match?(p['txHash']) &&
          p['payerAddress'].is_a?(String) && RE_PAYER.match?(p['payerAddress']) &&
          p['amountUsdc'].is_a?(String) && RE_AMOUNT.match?(p['amountUsdc']) &&
          p['network'].is_a?(String) && VALID_NETWORKS.include?(p['network'])
      end

      def coerce_payment(payment)
        if payment.is_a?(ExactUsdcPayment)
          [
            payment.scheme,
            payment.version,
            payment.payment_request_id,
            payment.tx_hash,
            payment.payer_address,
            payment.amount_usdc,
            payment.network,
          ]
        elsif payment.is_a?(Hash)
          # Accept either snake_case or camelCase keys.
          get = ->(snake, camel = nil) { payment[snake] || payment[snake.to_s] || (camel && (payment[camel] || payment[camel.to_s])) }
          [
            get.call(:scheme),
            get.call(:version) || 1,
            get.call(:payment_request_id, :paymentRequestId),
            (get.call(:tx_hash, :txHash) || '').to_s,
            (get.call(:payer_address, :payerAddress) || '').to_s,
            get.call(:amount_usdc, :amountUsdc),
            get.call(:network),
          ]
        else
          raise WireError.new(HEADER_PAYLOAD_MALFORMED, 'build_payment_header expects ExactUsdcPayment or Hash.')
        end
      end
    end
  end
end
