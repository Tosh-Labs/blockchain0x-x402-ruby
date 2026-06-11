# Sub-plan 21.3 row C-7 (Ruby x402): gem manifest.
#
# Distribution: rubygems as `blockchain0x-x402` via Trusted Publisher
# OIDC. Sibling gem to `blockchain0x`; mirror layout matches:
# source-of-truth at packages/sdk-ruby-x402/ in the monorepo;
# tosh-labs/blockchain0x-x402-ruby is the public mirror.

# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'blockchain0x_x402/version'

Gem::Specification.new do |spec|
  spec.name          = 'blockchain0x-x402'
  spec.version       = Blockchain0xX402::VERSION
  spec.authors       = ['Blockchain0x']
  spec.email         = ['support@blockchain0x.com']

  spec.summary       = 'Official Ruby port of @blockchain0x/x402 - HTTP 402 wire primitives + client'
  spec.description   = 'Sibling gem to `blockchain0x`. Verify inbound x402 payments + ' \
                       'issue x402-aware HTTP calls. Wire-format byte-equivalent with the ' \
                       'Node, Python, and Go ports.'
  spec.homepage      = 'https://blockchain0x.com'
  spec.license       = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.0'

  spec.metadata = {
    'homepage_uri'    => 'https://blockchain0x.com',
    'source_code_uri' => 'https://github.com/tosh-labs/blockchain0x-app/tree/dev/packages/sdk-ruby-x402',
    'bug_tracker_uri' => 'https://github.com/tosh-labs/blockchain0x-app/issues',
    'documentation_uri' => 'https://docs.blockchain0x.com',
    'changelog_uri'   => 'https://github.com/tosh-labs/blockchain0x-x402-ruby/blob/main/CHANGELOG.md',
    'rubygems_mfa_required' => 'true',
  }

  spec.files = Dir.glob('lib/**/*.rb') + %w[README.md LICENSE].select { |f| File.exist?(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'faraday', '>= 2.0', '< 3.0'
  # base64 left the default-gem set after Ruby 3.4; wire.rb requires it
  # at runtime, so it must be an explicit dependency.
  spec.add_dependency 'base64', '>= 0.2'

  spec.add_development_dependency 'rspec', '~> 3.13'
end
