require 'spec_helper'
require_relative '../../lib/straight-server/orders_controller'

RSpec.describe StraightServer::OrdersController do

  before(:each) do
    StraightServer.db_connection.run("DELETE FROM orders")
    @gateway = gateway = StraightServer::Gateway.find_by_id(2)
    allow(gateway).to receive_message_chain("address_provider.takes_fees?").and_return(false)
    allow(gateway).to receive_message_chain("address_provider.new_address").and_return("address#{gateway.last_keychain_id+1}")
    allow(gateway).to receive(:fetch_transactions_for).with(anything).and_return([])
    allow(gateway).to receive(:send_callback_http_request)
  end

  describe "create action" do

    it "creates an order and renders its attrs in json" do
      allow(StraightServer::Thread).to receive(:new) # ignore periodic status checks, we're not testing it here
      send_request "POST", '/gateways/2/orders', amount: 10
      expect(response).to render_json_with(status: 0, amount: 10, address: "address1", tid: nil, id: :anything, keychain_id: @gateway.last_keychain_id, last_keychain_id: @gateway.last_keychain_id)
    end

    it "renders 409 error when an order cannot be created due to invalid amount" do
      send_request "POST", '/gateways/2/orders', amount: 0
      expect(response[0]).to eq(409)
      expect(response[2]).to eq("Invalid order: amount cannot be nil and should be more than 0")
    end

    it "renders 409 error when an order cannot be created due to other validation errors" do
      send_request "POST", '/gateways/2/orders', amount: 1, description: 'A'*256
      expect(response[0]).to eq(409)
      expect(response[2]).to eq("Invalid order: description should be shorter than 256 characters")
    end

    it "starts tracking the order status in a separate thread" do
      order_mock = double("order mock")
      expect(order_mock).to receive(:start_periodic_status_check)
      expect(order_mock).to receive(:payment_id).and_return('blabla')
      allow(order_mock).to  receive(:to_h).and_return({})
      expect(@gateway).to   receive(:create_order).and_return(order_mock)
      send_request "POST", '/gateways/2/orders', amount: 10
    end

    it "passes data and callback_data param to Order which then saves it serialized" do
      allow(StraightServer::Thread).to receive(:new) # ignore periodic status checks, we're not testing it here
      send_request "POST", '/gateways/2/orders', amount: 10, data: { hello: 'world' }, callback_data: 'some random data'
      expect(StraightServer::Order.last.data.hello).to eq('world')
      expect(StraightServer::Order.last.callback_data).to eq('some random data')
    end

    it "renders 503 page when the gateway is inactive" do
      @gateway.active = false
      send_request "POST", '/gateways/2/orders', amount: 1
      expect(response[0]).to eq(503)
      expect(response[2]).to eq("The gateway is inactive, you cannot create order with it")
      @gateway.active = true
    end

    it "finds gateway using hashed_id" do
      allow(StraightServer::Thread).to receive(:new)
      send_request "POST", "/gateways/#{@gateway.id}/orders", amount: 10
    end

    it "warns about a deprecated order_id param" do
      send_request "POST", "/gateways/#{@gateway.id}/orders", amount: 10, order_id: 1
      expect(response[2]).to eq("Error: order_id is no longer a valid param. Use keychain_id instead and consult the documentation.")
    end

    it 'limits creation of orders without signature' do
      new_config          = StraightServer::Config.clone
      new_config.throttle = {requests_limit: 1, period: 1}
      stub_const 'StraightServer::Config', new_config
      allow(StraightServer::Thread).to receive(:new)

      send_request "POST", '/gateways/2/orders', amount: 10
      expect(response).to render_json_with(status: 0, amount: 10, address: "address1", tid: nil, id: :anything, keychain_id: @gateway.last_keychain_id, last_keychain_id: @gateway.last_keychain_id)
      send_request "POST", '/gateways/2/orders', amount: 10
      expect(response).to eq [429, {}, "Too many requests, please try again later"]

      @gateway1 = StraightServer::Gateway.find_by_id(1)
      @gateway1.check_signature = true
      5.times do |i|
        i += 1
        send_signed_request @gateway1, "POST", '/gateways/1/orders', amount: 10, keychain_id: i
        expect(response[0]).to eq 200
        expect(response).to render_json_with(status: 0, amount: 10, tid: nil, id: :anything, keychain_id: i, last_keychain_id: i)
      end
    end

    it "warns you about the use of callback_data instead of data" do
      allow(StraightServer::Thread).to receive(:new)
      send_request "POST", '/gateways/2/orders', amount: 10, data: "I meant this to be callback_data"
      expect(response).to render_json_with(WARNING: "Maybe you meant to use callback_data? The API has changed now. Consult the documentation.")
    end
  end

  describe "show action" do

    before(:each) do
      @order_mock = double('order mock')
      allow(@order_mock).to receive(:status).and_return(2)
      allow(@order_mock).to receive(:to_json).and_return("order json mock")
    end

    it "renders json info about an order if it is found" do
      allow(@order_mock).to receive(:status_changed?).and_return(false)
      expect(StraightServer::Order).to receive(:[]).with(1).and_return(@order_mock)
      send_request "GET", '/gateways/2/orders/1'
      expect(response).to eq([200, {}, "order json mock"])
    end

    it "saves an order if status is updated" do
      allow(@order_mock).to receive(:status_changed?).and_return(true)
      expect(@order_mock).to receive(:save)
      expect(StraightServer::Order).to receive(:[]).with(1).and_return(@order_mock)
      send_request "GET", '/gateways/2/orders/1'
      expect(response).to eq([200, {}, "order json mock"])
    end

    it "renders 404 if order is not found" do
      expect(StraightServer::Order).to receive(:[]).with(1).and_return(nil)
      send_request "GET", '/gateways/2/orders/1'
      expect(response).to eq([404, {}, "GET /gateways/2/orders/1 Not found"])
    end

    it "finds order by payment_id" do
      allow(@order_mock).to receive(:status_changed?).and_return(false)
      expect(StraightServer::Order).to receive(:[]).with(:payment_id => 'payment_id').and_return(@order_mock)
      send_request "GET", '/gateways/2/orders/payment_id'
      expect(response).to eq([200, {}, "order json mock"])
    end

  end

  describe "websocket action" do

    before(:each) do
      StraightServer::GatewayModule.class_variable_set(:@@websockets, { @gateway.id => {} })
      @ws_mock    = double("websocket mock")
      @order_mock = double("order mock")
      allow(@ws_mock).to receive(:rack_response).and_return("ws rack response")
      [:id, :gateway=, :save, :to_h, :id=].each { |m| allow(@order_mock).to receive(m) }
      allow(@ws_mock).to receive(:on)
      allow(Faye::WebSocket).to receive(:new).and_return(@ws_mock)
    end

    it "returns a websocket connection" do
      allow(@order_mock).to receive(:status).and_return(0)
      allow(StraightServer::Order).to receive(:[]).with(1).and_return(@order_mock)
      send_request "GET", '/gateways/2/orders/1/websocket'
      expect(response).to eq("ws rack response")
    end

    it "returns 403 when socket already exists" do
      allow(@order_mock).to receive(:status).and_return(0)
      allow(StraightServer::Order).to receive(:[]).with(1).twice.and_return(@order_mock)
      send_request "GET", '/gateways/2/orders/1/websocket'
      send_request "GET", '/gateways/2/orders/1/websocket'
      expect(response).to eq([403, {}, "Someone is already listening to that order"])
    end

    it "returns 403 when order has is completed (status > 1 )" do
      allow(@order_mock).to receive(:status).and_return(2)
      allow(StraightServer::Order).to receive(:[]).with(1).and_return(@order_mock)
      send_request "GET", '/gateways/2/orders/1/websocket'
      expect(response).to eq([403, {}, "You cannot listen to this order because it is completed (status > 1)"])
    end

    it "finds order by payment_id" do
      allow(@order_mock).to receive(:status).and_return(0)
      expect(StraightServer::Order).to receive(:[]).with(:payment_id => 'payment_id').and_return(@order_mock)
      send_request "GET", '/gateways/2/orders/payment_id/websocket'
      expect(response).to eq("ws rack response")
    end
  end

  describe "cancel action" do
    it "cancels new order" do
      allow(StraightServer::Thread).to receive(:new)
      send_request "POST", '/gateways/2/orders', amount: 1
      payment_id = JSON.parse(response[2])['payment_id']
      send_request "POST", "/gateways/2/orders/#{payment_id}/cancel"
      expect(response[0]).to eq 200
    end

    it "requires signature to cancel signed order" do
      allow(StraightServer::Thread).to receive(:new)
      @gateway1                 = StraightServer::Gateway.find_by_id(1)
      @gateway1.check_signature = true
      @order_mock = double('order mock')
      allow(@order_mock).to receive(:status).with(reload: true)
      allow(@order_mock).to receive(:status_changed?).and_return(false)
      allow(@order_mock).to receive(:cancelable?).and_return(true)
      expect(@order_mock).to receive(:cancel)
      allow(StraightServer::Order).to receive(:[]).and_return(@order_mock)
      send_request "POST", "/gateways/1/orders/payment_id/cancel"
      expect(response).to eq [409, {}, 'X-Nonce is invalid: nil']
      send_signed_request @gateway1, "POST", "/gateways/1/orders/payment_id/cancel"
      expect(response[0]).to eq 200
    end

    it "do not cancel orders with status != new" do
      @order_mock = double('order mock')
      allow(@order_mock).to receive(:status).with(reload: true)
      allow(@order_mock).to receive(:status_changed?).and_return(true)
      expect(@order_mock).to receive(:save)
      allow(@order_mock).to receive(:cancelable?).and_return(false)
      allow(StraightServer::Order).to receive(:[]).and_return(@order_mock)
      send_request "POST", "/gateways/2/orders/payment_id/cancel"
      expect(response).to eq [409, {}, "Order is not cancelable"]
    end
  end

  it 'return last_keychain_id' do
    lk_id = 123
    @gateway = StraightServer::Gateway.find_by_id(1)
    @gateway.last_keychain_id = lk_id
    @gateway.save
    send_request "GET", '/gateway/1/last_keychain_id'
    expect(response).to render_json_with(gateway_id: @gateway.id, last_keychain_id: lk_id)
  end

  def send_request(method, path, params={})
    env = Hashie::Mash.new('REQUEST_METHOD' => method, 'REQUEST_PATH' => path, 'params' => params)
    @controller = StraightServer::OrdersController.new(env)
  end

  def send_signed_request(gateway, method, path, params={})
    env = Hashie::Mash.new('REQUEST_METHOD' => method, 'REQUEST_PATH' => path, 'params' => params, 'HTTP_X_NONCE' => (Time.now.to_f * 1e6).to_i)
    env['HTTP_X_SIGNATURE'] = StraightServer::SignatureValidator.new(gateway, env).signature
    @controller = StraightServer::OrdersController.new(env)
  end

  def response
    @controller.response
  end

end
