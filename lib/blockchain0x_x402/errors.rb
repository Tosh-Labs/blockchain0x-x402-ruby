# Sub-plan 21.3 C-7 (Ruby x402): error hierarchy.
#
#   Blockchain0xX402::Error              (base)
#     Blockchain0xX402::WireError        (wire-format parse / build failures)
#     Blockchain0xX402::ClientError      (402-flow runtime failures)
#
# Each carries a stable `code` string matching the Node + Python +
# Go ports so cross-language consumers branch identically.

# frozen_string_literal: true

module Blockchain0xX402
  class Error < StandardError
    attr_reader :code

    def initialize(code, message)
      super("#{code}: #{message}")
      @code = code
    end
  end

  # Raised on any malformed x402 wire input. Codes:
  #
  #   response.not_402
  #   response.body_missing
  #   response.body_malformed
  #   header.missing
  #   header.malformed
  #   header.unknown_scheme
  #   header.payload_malformed
  class WireError < Error
  end

  # Raised when the 402-aware client wrapper cannot resolve a
  # challenge. Codes:
  #
  #   no_matching_requirement  - no accepts entry matched the SDK network
  #   settlement_timeout       - on-chain payment did not confirm in budget
  #   chain_failed             - payment status flipped to failed
  class ClientError < Error
  end
end
