# Buyer-side guardrail specs for the 402-aware client (sub-plan 27.1
# row A6). Mirrors packages/x402/src/client.test.ts: the 402 challenge
# is attacker-controlled input, so the client enforces max_amount_wei,
# allowed_pay_to, the requirement's maxAgeSeconds window, and refuses
# unmatched networks instead of guessing.

# frozen_string_literal: true

require 'spec_helper'
require 'json'

require 'blockchain0x_x402/client'

RSpec.describe Blockchain0xX402::Client do
  # `let`, not constants: constants declared inside an RSpec block are
  # global and collide with wire_spec's fixtures.
  let(:payee) { "0x#{'cd' * 20}" }
  let(:other_payee) { "0x#{'ee' * 20}" }
  let(:payer) { "0x#{'ab' * 20}" }
  let(:tx) { "0x#{'11' * 32}" }

  let(:stub_sdk_class) do
    Class.new do
      attr_reader :network, :payment_calls

      def initialize(network: 'testnet')
        @network = network
        @payment_calls = []
      end

      def payments_create(args)
        @payment_calls << args
        { 'id' => 'pay_1', 'status' => 'submitted' }
      end

      def transactions_get(_id)
        { 'status' => 'confirmed', 'txHash' => "0x#{'11' * 32}", 'fromAddress' => "0x#{'ab' * 20}" }
      end
    end
  end

  def requirement(over = {})
    {
      'scheme' => 'exact-usdc',
      'network' => 'testnet',
      'chainId' => 'eip155:84532',
      'payToAddress' => payee,
      'amountWeiUsdc' => '1000000',
      'paymentRequestId' => 'pr_1',
    }.merge(over)
  end

  def conn_402_then_200(accepts)
    requests = []
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post('/paid') do |env|
        requests << env
        if requests.length == 1
          [402, { 'content-type' => 'application/json' },
           JSON.generate('version' => 1, 'resource' => '/paid', 'accepts' => accepts)]
        else
          [200, {}, 'ok']
        end
      end
    end
    conn = Faraday.new { |f| f.adapter(:test, stubs) }
    [conn, requests]
  end

  def build_client(sdk, conn, **kw)
    described_class.new(
      sdk: sdk,
      agent_id: 'agt_1',
      connection: conn,
      sleep_proc: ->(_s) {},
      **kw,
    )
  end

  it 'rejects an over-cap quote BEFORE any payment is created' do
    sdk = stub_sdk_class.new
    conn, = conn_402_then_200([requirement('amountWeiUsdc' => '2000001')])
    client = build_client(sdk, conn, max_amount_wei: '2000000')

    expect { client.post('/paid') }.to raise_error(Blockchain0xX402::ClientError) { |e|
      expect(e.code).to eq('amount_over_cap')
    }
    expect(sdk.payment_calls).to be_empty
  end

  it 'allows an exactly-at-cap quote' do
    sdk = stub_sdk_class.new
    conn, = conn_402_then_200([requirement('amountWeiUsdc' => '2000000')])
    client = build_client(sdk, conn, max_amount_wei: '2000000')

    expect(client.post('/paid').status).to eq(200)
  end

  it 'rejects a recipient outside allowed_pay_to (case-insensitive) before any payment' do
    sdk = stub_sdk_class.new
    conn, = conn_402_then_200([requirement('payToAddress' => other_payee)])
    client = build_client(
      sdk, conn,
      max_amount_wei: '2000000',
      allowed_pay_to: [payee.upcase.sub('0X', '0x')],
    )

    expect { client.post('/paid') }.to raise_error(Blockchain0xX402::ClientError) { |e|
      expect(e.code).to eq('recipient_not_allowed')
    }
    expect(sdk.payment_calls).to be_empty
  end

  it 'refuses a stale challenge whose confirmation landed after maxAgeSeconds' do
    sdk = stub_sdk_class.new
    conn, = conn_402_then_200([requirement('maxAgeSeconds' => 60)])
    t = [0.0]
    now = lambda do
      v = t[0]
      t[0] += 61.0
      v
    end
    client = build_client(sdk, conn, max_amount_wei: '2000000', now_proc: now)

    expect { client.post('/paid') }.to raise_error(Blockchain0xX402::ClientError) { |e|
      expect(e.code).to eq('stale_challenge')
    }
  end

  it 'refuses when no requirement matches the SDK network (no accepts[0] fallback)' do
    sdk = stub_sdk_class.new(network: nil)
    conn, = conn_402_then_200([requirement])
    client = build_client(sdk, conn, max_amount_wei: '2000000')

    expect { client.post('/paid') }.to raise_error(Blockchain0xX402::ClientError) { |e|
      expect(e.code).to eq('no_matching_requirement')
    }
    expect(sdk.payment_calls).to be_empty
  end

  it 'rejects a non-integer max_amount_wei at construction' do
    expect {
      build_client(stub_sdk_class.new, Faraday.new, max_amount_wei: '1.5')
    }.to raise_error(ArgumentError)
  end

  it 'happy path within policy: pays, attaches X-Payment, returns the 200' do
    sdk = stub_sdk_class.new
    conn, requests = conn_402_then_200([requirement])
    client = build_client(sdk, conn, max_amount_wei: '2000000', allowed_pay_to: [payee])

    res = client.post('/paid')
    expect(res.status).to eq(200)
    expect(sdk.payment_calls).to eq([{ agent_id: 'agt_1', to: payee, amount_wei: '1000000' }])
    header = requests[1].request_headers['X-Payment']
    expect(header).to start_with('exact-usdc:')
    payload = JSON.parse(Base64.strict_decode64(header.split(':', 2)[1]))
    expect(payload['txHash']).to eq(tx)
    expect(payload['payerAddress']).to eq(payer)
  end
end
