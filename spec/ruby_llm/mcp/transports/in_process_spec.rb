# frozen_string_literal: true

RSpec.describe RubyLLM::MCP::Transports::InProcess do
  let(:coordinator) { instance_double(RubyLLM::MCP::Coordinator) }
  let(:request_timeout) { 5000 }
  let(:mock_server) { instance_double("MCP::Server") }
  let(:mock_server_transport) { instance_double("MCP::Server::Transports::InProcessTransport") }

  let(:transport) do
    # Mock the server transport setup to avoid requiring the actual MCP SDK
    allow_any_instance_of(described_class).to receive(:setup_server_transport) do |instance|
      instance.instance_variable_set(:@server_transport, mock_server_transport)
      allow(mock_server).to receive(:transport=).with(mock_server_transport)
    end

    described_class.new(
      server: mock_server,
      coordinator: coordinator,
      request_timeout: request_timeout
    )
  end

  before do
    allow(mock_server_transport).to receive(:close)
    allow(coordinator).to receive(:process_result)
  end

  describe "#initialize" do
    it "sets up the transport with basic properties" do
      expect(transport.server).to eq(mock_server)
      expect(transport.coordinator).to eq(coordinator)
      expect(transport.request_timeout).to eq(request_timeout)
    end

    it "generates a unique client ID" do
      expect(transport.instance_variable_get(:@client_id)).to be_a(String)
      expect(transport.instance_variable_get(:@client_id)).not_to be_empty
    end

    it "initializes as not running" do
      expect(transport.alive?).to be false
    end
  end

  describe "#start" do
    it "sets running to true" do
      expect { transport.start }.to change { transport.alive? }.from(false).to(true)
    end

    it "does not start multiple times" do
      transport.start
      expect(transport.alive?).to be true
      
      # Starting again should not change state
      transport.start
      expect(transport.alive?).to be true
    end
  end

  describe "#close" do
    before { transport.start }

    it "sets running to false" do
      expect { transport.close }.to change { transport.alive? }.from(true).to(false)
    end

    it "closes the server transport" do
      expect(mock_server_transport).to receive(:close)
      transport.close
    end
  end

  describe "#set_protocol_version" do
    it "stores the protocol version" do
      transport.set_protocol_version("2025-06-18")
      expect(transport.instance_variable_get(:@protocol_version)).to eq("2025-06-18")
    end
  end

  describe "#request" do
    before { transport.start }

    context "when transport is not running" do
      before { transport.close }

      it "raises a transport error" do
        expect {
          transport.request({ "method" => "ping" })
        }.to raise_error(RubyLLM::MCP::Errors::TransportError, "Transport not started")
      end
    end

    context "when transport is running" do
      let(:request_body) { { "method" => "ping" } }
      let(:response_json) { '{"jsonrpc":"2.0","id":1,"result":{}}' }
      let(:response_hash) { { "jsonrpc" => "2.0", "id" => 1, "result" => {} } }

      before do
        allow(mock_server).to receive(:handle_json).and_return(response_json)
        allow(coordinator).to receive(:process_result).and_return(nil)
      end

      it "adds an ID to the request when add_id is true" do
        expect(JSON).to receive(:generate).with(hash_including("id" => 1))
        expect(mock_server).to receive(:handle_json)
        
        transport.request(request_body, add_id: true)
      end

      it "does not add an ID when add_id is false" do
        expect(JSON).to receive(:generate).with(request_body)
        expect(mock_server).to receive(:handle_json)
        
        transport.request(request_body, add_id: false)
      end

      it "processes the response through the coordinator" do
        expect(coordinator).to receive(:process_result).with(
          an_instance_of(RubyLLM::MCP::Result)
        )
        
        transport.request(request_body)
      end

      it "returns the processed result" do
        mock_result = instance_double(RubyLLM::MCP::Result)
        allow(coordinator).to receive(:process_result).and_return(mock_result)
        
        result = transport.request(request_body)
        expect(result).to eq(mock_result)
      end

      it "handles JSON parsing errors" do
        allow(mock_server).to receive(:handle_json).and_return("invalid json")
        
        expect {
          transport.request(request_body)
        }.to raise_error(RubyLLM::MCP::Errors::TransportError, /JSON parsing error/)
      end

      it "handles server errors" do
        allow(mock_server).to receive(:handle_json).and_raise(StandardError.new("Server error"))
        
        expect {
          transport.request(request_body)
        }.to raise_error(RubyLLM::MCP::Errors::TransportError, /Error in in-process transport/)
      end

      context "when wait_for_response is false" do
        it "returns without waiting for response" do
          allow(mock_server).to receive(:handle_json).and_return(nil)
          
          result = transport.request(request_body, wait_for_response: false)
          expect(result).to be_nil
        end
      end
    end
  end

  describe "#receive_notification" do
    let(:method_name) { "notifications/tools/list_changed" }
    let(:params) { { "data" => "test" } }

    before { transport.start }

    it "processes the notification through the coordinator" do
      expected_notification = {
        "jsonrpc" => "2.0",
        "method" => method_name,
        "params" => params
      }

      expect(coordinator).to receive(:process_result).with(
        an_instance_of(RubyLLM::MCP::Result)
      )

      transport.receive_notification(method_name, params)
    end

    it "handles notifications without params" do
      expected_notification = {
        "jsonrpc" => "2.0",
        "method" => method_name
      }

      expect(coordinator).to receive(:process_result).with(
        an_instance_of(RubyLLM::MCP::Result)
      )

      transport.receive_notification(method_name)
    end

    it "handles errors gracefully" do
      allow(coordinator).to receive(:process_result).and_raise(StandardError.new("Processing error"))

      expect {
        transport.receive_notification(method_name, params)
      }.not_to raise_error
    end

    context "when transport is not running" do
      before { transport.close }

      it "does not process the notification" do
        expect(coordinator).not_to receive(:process_result)
        transport.receive_notification(method_name, params)
      end
    end
  end
end