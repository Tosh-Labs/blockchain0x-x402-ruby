# Sub-plan 21.3 row C-7 (Ruby x402) wire tests. Mirror the Python
# + Go failure-mode coverage so the four x402 ports agree byte-
# for-byte.

# frozen_string_literal: true

require 'spec_helper'
require 'base64'
require 'json'

RSpec.describe Blockchain0xX402::Wire do
  TX_HASH = '0x4e2b1f8a9d4c5e7f6a8b9c0d1e2f3a4b4e2b1f8a9d4c5e7f6a8b9c0d1e2f3a4b'
  PAYER   = '0xABCDEF0123456789ABCDEF0123456789ABCDEF01'

  let(:sample) do
    described_class::ExactUsdcPayment.new(
      scheme: 'exact-usdc',
      version: 1,
      payment_request_id: 'pr_test_1',
      tx_hash: TX_HASH,
      payer_address: PAYER,
      amount_usdc: '0.10',
      network: 'mainnet',
    )
  end

  describe 'build + parse round-trip' do
    it 'lowercases hex fields on encode + decode' do
      header = described_class.build_payment_header(sample)
      expect(header).to start_with('exact-usdc:')
      back = described_class.parse_payment_header(header)
      expect(back.payment_request_id).to eq sample.payment_request_id
      expect(back.tx_hash).to eq sample.tx_hash.downcase
      expect(back.payer_address).to eq sample.payer_address.downcase
      expect(back.amount_usdc).to eq '0.10'
      expect(back.network).to eq 'mainnet'
    end

    it 'accepts a Hash in payment position with snake_case keys' do
      header = described_class.build_payment_header(
        scheme: 'exact-usdc',
        version: 1,
        payment_request_id: 'pr_hash_1',
        tx_hash: TX_HASH,
        payer_address: PAYER,
        amount_usdc: '1.5',
        network: 'testnet',
      )
      decoded = described_class.parse_payment_header(header)
      expect(decoded.payment_request_id).to eq 'pr_hash_1'
      expect(decoded.network).to eq 'testnet'
    end
  end

  describe 'byte-for-byte cross-language equivalence' do
    it 'produces the canonical payload string matching Node + Python + Go' do
      header = described_class.build_payment_header(sample)
      b64 = header.split(':', 2).last
      payload = Base64.strict_decode64(b64)
      expected = '{"scheme":"exact-usdc","version":1,' \
                 '"paymentRequestId":"pr_test_1",' \
                 "\"txHash\":\"#{TX_HASH.downcase}\"," \
                 "\"payerAddress\":\"#{PAYER.downcase}\"," \
                 '"amountUsdc":"0.10","network":"mainnet"}'
      expect(payload).to eq expected
    end
  end

  describe 'failure modes on parse_payment_header' do
    it 'rejects empty header with header.missing' do
      expect { described_class.parse_payment_header('') }
        .to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'header.missing' }
    end

    it 'rejects no-separator with header.malformed' do
      expect { described_class.parse_payment_header('no-colon-here') }
        .to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'header.malformed' }
    end

    it 'rejects trailing-colon with header.malformed' do
      expect { described_class.parse_payment_header('exact-usdc:') }
        .to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'header.malformed' }
    end

    it 'rejects unknown scheme' do
      payload = Base64.strict_encode64('{}')
      expect { described_class.parse_payment_header("weird:#{payload}") }
        .to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'header.unknown_scheme' }
    end

    it 'rejects non-base64 payload' do
      expect { described_class.parse_payment_header('exact-usdc:not-base64!!!!') }
        .to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'header.payload_malformed' }
    end

    it 'rejects non-JSON payload' do
      enc = Base64.strict_encode64('not-json')
      expect { described_class.parse_payment_header("exact-usdc:#{enc}") }
        .to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'header.payload_malformed' }
    end

    it 'rejects shape-invalid payload (bad tx hash)' do
      bad = JSON.generate(
        'scheme' => 'exact-usdc',
        'version' => 1,
        'paymentRequestId' => 'pr_x',
        'txHash' => '0xtooshort',
        'payerAddress' => PAYER.downcase,
        'amountUsdc' => '0.10',
        'network' => 'mainnet',
      )
      enc = Base64.strict_encode64(bad)
      expect { described_class.parse_payment_header("exact-usdc:#{enc}") }
        .to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'header.payload_malformed' }
    end

    it 'rejects shape-invalid payload (unknown network)' do
      bad = JSON.generate(
        'scheme' => 'exact-usdc',
        'version' => 1,
        'paymentRequestId' => 'pr_x',
        'txHash' => TX_HASH.downcase,
        'payerAddress' => PAYER.downcase,
        'amountUsdc' => '0.10',
        'network' => 'polygon',
      )
      enc = Base64.strict_encode64(bad)
      expect { described_class.parse_payment_header("exact-usdc:#{enc}") }
        .to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'header.payload_malformed' }
    end
  end

  describe 'parse_402_body' do
    it 'parses a well-formed body' do
      body = {
        'version' => 1,
        'resource' => 'POST /llm-query',
        'accepts' => [{
          'scheme' => 'exact-usdc',
          'network' => 'mainnet',
          'chainId' => 'eip155:8453',
          'payToAddress' => '0x1234567890abcdef1234567890abcdef12345678',
          'amountWeiUsdc' => '100000',
          'paymentRequestId' => 'pr_smoke_02',
        }],
      }
      parsed = described_class.parse_402_body(body)
      expect(parsed.version).to eq 1
      expect(parsed.accepts.first.payment_request_id).to eq 'pr_smoke_02'
      expect(parsed.accepts.first.amount_wei_usdc).to eq '100000'
    end

    it 'rejects wrong version with response.body_malformed' do
      expect { described_class.parse_402_body('version' => 99, 'resource' => 'x', 'accepts' => []) }
        .to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'response.body_malformed' }
    end

    it 'rejects empty accepts with response.body_malformed' do
      expect { described_class.parse_402_body('version' => 1, 'resource' => 'x', 'accepts' => []) }
        .to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'response.body_malformed' }
    end

    it 'rejects unrecognised requirement entry' do
      expect do
        described_class.parse_402_body(
          'version' => 1, 'resource' => 'x',
          'accepts' => [{ 'scheme' => 'exact-usdc' }],
        )
      end.to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'response.body_malformed' }
    end
  end

  describe 'parse_402_response (object with .status + .body)' do
    let(:resp_class) do
      Struct.new(:status, :body) do
        def code; status; end
      end
    end

    it 'parses an HTTP 402 with a string JSON body' do
      json = JSON.generate(
        'version' => 1,
        'resource' => 'x',
        'accepts' => [{
          'scheme' => 'exact-usdc',
          'network' => 'testnet',
          'chainId' => 'eip155:84532',
          'payToAddress' => "0x#{'ab' * 20}",
          'amountWeiUsdc' => '1',
          'paymentRequestId' => 'pr_z',
        }],
      )
      parsed = described_class.parse_402_response(resp_class.new(402, json))
      expect(parsed.accepts.first.payment_request_id).to eq 'pr_z'
    end

    it 'rejects non-402 with response.not_402' do
      expect { described_class.parse_402_response(resp_class.new(200, '{}')) }
        .to raise_error(Blockchain0xX402::WireError) { |e| expect(e.code).to eq 'response.not_402' }
    end
  end
end
