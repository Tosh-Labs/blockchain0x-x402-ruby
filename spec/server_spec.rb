# Sub-plan 21.3 row C-7 follow-up (Ruby Rack middleware) tests.
# Pure rspec; no rack-test dependency - we drive the middleware
# against the Rack call shape (env hash -> [status, headers, body])
# directly. Same 9 behavioural axes as the Python ASGI + Go net/http
# adapters plus 3 Ruby-specific cases.

# frozen_string_literal: true

require 'spec_helper'
require 'base64'
require 'json'

require 'blockchain0x_x402/server'

RSpec.describe Blockchain0xX402::Server do
  let(:stub_sdk_class) do
    Class.new do
      attr_reader :calls

      def initialize(settle_error: nil)
        @calls = []
        @settle_error = settle_error
      end

      def payment_requests_settle(payment_request_id:, body:)
        @calls << { payment_request_id: payment_request_id, body: body }
        raise @settle_error if @settle_error

        { 'id' => payment_request_id, 'status' => 'settled' }
      end
    end
  end

  let(:sdk) { stub_sdk_class.new }
  let(:pricing) do
    {
      'POST /llm-query' => described_class::PricingEntry.new(
        amount_usdc: '0.10',
        pay_to_address: '0x1234567890abcdef1234567890abcdef12345678',
        payment_request_id: 'pr_smoke',
      ),
    }
  end

  let(:inner_app) do
    lambda do |env|
      payment = env[described_class::PAYMENT_ENV_KEY]
      body = {
        'served' => true,
        'paymentId' => payment&.payment_request_id,
      }
      [200, { 'Content-Type' => 'application/json' }, [JSON.generate(body)]]
    end
  end

  let(:middleware) do
    described_class::RackMiddleware.new(inner_app, sdk: sdk, pricing: pricing)
  end

  def valid_header(payment_request_id = 'pr_smoke')
    Blockchain0xX402::Wire.build_payment_header(
      Blockchain0xX402::Wire::ExactUsdcPayment.new(
        scheme: 'exact-usdc',
        version: 1,
        payment_request_id: payment_request_id,
        tx_hash: "0x#{'ab' * 32}",
        payer_address: "0x#{'cd' * 20}",
        amount_usdc: '0.10',
        network: 'testnet',
      ),
    )
  end

  describe 'no pricing match' do
    it 'passes through to the inner app and never calls settle' do
      env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/free-endpoint' }
      status, _headers, body = middleware.call(env)
      expect(status).to eq(200)
      expect(JSON.parse(body.first)['served']).to be(true)
      expect(sdk.calls).to be_empty
    end
  end

  describe 'pricing match without header' do
    it 'returns 402 with the canonical accepts body + header_missing reason' do
      env = { 'REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/llm-query' }
      status, headers, body = middleware.call(env)
      expect(status).to eq(402)
      expect(headers['Content-Type']).to eq('application/json')
      payload = JSON.parse(body.first)
      expect(payload['version']).to eq(1)
      expect(payload['resource']).to eq('POST /llm-query')
      expect(payload['accepts'].length).to eq(1)
      first = payload['accepts'].first
      expect(first['amountWeiUsdc']).to eq('100000')
      expect(first['payToAddress']).to eq('0x1234567890abcdef1234567890abcdef12345678')
      expect(first['maxAgeSeconds']).to eq(60)
      expect(payload['error']['reason']).to eq('header_missing')
      expect(sdk.calls).to be_empty
    end
  end

  describe 'pricing match with valid header' do
    it 'calls settle once with canonical body and forwards to inner app' do
      env = {
        'REQUEST_METHOD' => 'POST',
        'PATH_INFO' => '/llm-query',
        'HTTP_X_PAYMENT' => valid_header('pr_smoke'),
      }
      status, _headers, body = middleware.call(env)
      expect(status).to eq(200)
      payload = JSON.parse(body.first)
      expect(payload['served']).to be(true)
      expect(payload['paymentId']).to eq('pr_smoke')
      expect(sdk.calls.length).to eq(1)
      call = sdk.calls.first
      expect(call[:payment_request_id]).to eq('pr_smoke')
      expect(call[:body]['txHash']).to eq("0x#{'ab' * 32}")
      expect(call[:body]['payerAddress']).to eq("0x#{'cd' * 20}")
      expect(call[:body]['amountUsdcVerified']).to eq('0.10')
    end
  end

  describe 'pricing match with malformed header' do
    it 'returns 402 header_malformed and never calls settle' do
      env = {
        'REQUEST_METHOD' => 'POST',
        'PATH_INFO' => '/llm-query',
        'HTTP_X_PAYMENT' => 'exact-usdc:!!!not-base64!!!',
      }
      status, _headers, body = middleware.call(env)
      expect(status).to eq(402)
      payload = JSON.parse(body.first)
      expect(payload['error']['reason']).to eq('header_malformed')
      expect(sdk.calls).to be_empty
    end
  end

  describe 'pricing match with mismatched paymentRequestId' do
    it 'returns 402 requirement_mismatch naming both IDs' do
      env = {
        'REQUEST_METHOD' => 'POST',
        'PATH_INFO' => '/llm-query',
        'HTTP_X_PAYMENT' => valid_header('pr_OTHER'),
      }
      status, _headers, body = middleware.call(env)
      expect(status).to eq(402)
      payload = JSON.parse(body.first)
      expect(payload['error']['reason']).to eq('requirement_mismatch')
      expect(payload['error']['message']).to include('pr_OTHER')
      expect(payload['error']['message']).to include('pr_smoke')
      expect(sdk.calls).to be_empty
    end
  end

  describe 'settle rejection' do
    let(:sdk) { stub_sdk_class.new(settle_error: RuntimeError.new('payment proof already consumed')) }

    it 'returns 402 settle_rejected with the SDK error message' do
      env = {
        'REQUEST_METHOD' => 'POST',
        'PATH_INFO' => '/llm-query',
        'HTTP_X_PAYMENT' => valid_header('pr_smoke'),
      }
      status, _headers, body = middleware.call(env)
      expect(status).to eq(402)
      payload = JSON.parse(body.first)
      expect(payload['error']['reason']).to eq('settle_rejected')
      expect(payload['error']['message']).to include('already consumed')
    end
  end

  describe 'method-specific routing' do
    it 'does not gate a GET against a POST-quoted path' do
      env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/llm-query' }
      status, _headers, _body = middleware.call(env)
      expect(status).to eq(200)
    end
  end

  describe 'custom default network' do
    let(:middleware) do
      described_class::RackMiddleware.new(
        inner_app,
        sdk: sdk,
        pricing: pricing,
        default_network: 'testnet',
      )
    end

    it 'falls back to the configured network when PricingEntry omits one' do
      env = { 'REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/llm-query' }
      _status, _headers, body = middleware.call(env)
      first = JSON.parse(body.first)['accepts'].first
      expect(first['network']).to eq('testnet')
      expect(first['chainId']).to eq('eip155:84532')
    end
  end

  describe 'usdc_decimal_to_wei coverage' do
    it 'converts every representative input correctly' do
      cases = {
        '0' => '0',
        '0.000001' => '1',
        '0.1' => '100000',
        '0.5' => '500000',
        '1' => '1000000',
        '1.5' => '1500000',
        '123.456789' => '123456789',
      }
      cases.each do |input, expected|
        expect(described_class.usdc_decimal_to_wei(input)).to eq(expected),
          "usdc_decimal_to_wei(#{input.inspect}) => want #{expected.inspect}"
      end
    end
  end

  describe 'wire-format cross-compatibility' do
    it 'accepts a header built against the canonical scheme + decodes payment back byte-equivalent' do
      header = valid_header('pr_smoke')
      expect(header).to start_with('exact-usdc:')
      base64 = header.split(':', 2).last
      raw = Base64.strict_decode64(base64)
      decoded = JSON.parse(raw)
      expect(decoded['paymentRequestId']).to eq('pr_smoke')
      expect(decoded['amountUsdc']).to eq('0.10')
      expect(decoded.keys).to eq(%w[scheme version paymentRequestId txHash payerAddress amountUsdc network])
    end
  end

  describe 'PricingEntry constructor validation' do
    it 'requires amount_usdc, pay_to_address, and payment_request_id' do
      expect do
        described_class::PricingEntry.new(amount_usdc: '0.10', pay_to_address: '0xabc')
      end.to raise_error(ArgumentError)
    end
  end
end
