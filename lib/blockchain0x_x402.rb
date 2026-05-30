# Sub-plan 21.3 row C-7 (Ruby x402): top-level module.
#
# Public surface:
#   Blockchain0xX402::Wire.parse_402_response / parse_402_body /
#                          build_payment_header / parse_payment_header
#   Blockchain0xX402::WireError
#   Blockchain0xX402::Client (402-aware Faraday wrapper)
#   Blockchain0xX402::ClientError
#   Blockchain0xX402::Server::RackMiddleware (Rack / Sinatra / Rails gate)
#   Blockchain0xX402::Server::PricingEntry
#   Blockchain0xX402::VERSION

# frozen_string_literal: true

require_relative 'blockchain0x_x402/version'
require_relative 'blockchain0x_x402/errors'
require_relative 'blockchain0x_x402/wire'
# Client + Server are required lazily so verify-only consumers
# do not pay the Faraday / Rack load cost. Server has no runtime
# Rack dependency (the middleware obeys the Rack 1.x calling
# convention purely on the env-hash + tuple shape), so it can be
# required even in installs that do not have Rack installed.

module Blockchain0xX402
  # @return [Class] Blockchain0xX402::Client (lazy-loaded)
  def self.const_missing(name)
    case name
    when :Client
      require_relative 'blockchain0x_x402/client'
      const_get(:Client)
    when :Server
      require_relative 'blockchain0x_x402/server'
      const_get(:Server)
    else
      super
    end
  end
end
