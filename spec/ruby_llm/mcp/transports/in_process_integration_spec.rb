# frozen_string_literal: true

# Integration test for in-process transport
# This test requires the MCP server SDK to be available

RSpec.describe "In-Process Transport Integration", :integration do
  before(:all) do
    begin
      require "mcp"
    rescue LoadError
      skip "MCP server SDK not available for integration test"
    end
  end

  let(:server) do
    MCP::Server.new(
      name: "test_server",
      tools: [test_tool_class],
      prompts: [test_prompt_class],
      resources: [test_resource]
    )
  end

  let(:test_tool_class) do
    Class.new(MCP::Tool) do
      description "A test tool for integration testing"
      input_schema(
        properties: {
          message: { type: "string" }
        },
        required: ["message"]
      )

      def self.call(message:, server_context:)
        MCP::Tool::Response.new([{
          type: "text",
          text: "Test response: #{message}"
        }])
      end
    end
  end

  let(:test_prompt_class) do
    Class.new(MCP::Prompt) do
      prompt_name "test_prompt"
      description "A test prompt for integration testing"
      arguments [
        MCP::Prompt::Argument.new(
          name: "name",
          description: "Name to use in prompt",
          required: true
        )
      ]

      def self.template(args, server_context:)
        MCP::Prompt::Result.new(
          description: "Test prompt result",
          messages: [
            MCP::Prompt::Message.new(
              role: "user",
              content: MCP::Content::Text.new("Hello #{args['name']}")
            )
          ]
        )
      end
    end
  end

  let(:test_resource) do
    MCP::Resource.new(
      uri: "test://resource",
      name: "Test Resource",
      description: "A test resource",
      mime_type: "text/plain"
    )
  end

  let(:client) do
    RubyLLM::MCP.client(
      name: "test_client",
      transport_type: :in_process,
      config: {
        server: server,
        request_timeout: 5000
      }
    )
  end

  before do
    # Set up resource read handler
    server.resources_read_handler do |params|
      if params[:uri] == "test://resource"
        [{
          uri: params[:uri],
          mimeType: "text/plain",
          text: "Test resource content"
        }]
      else
        []
      end
    end
  end

  after do
    client&.stop
  end

  describe "transport lifecycle" do
    it "establishes connection successfully" do
      expect { client.start }.not_to raise_error
      expect(client.alive?).to be true
    end

    it "responds to ping" do
      client.start
      expect(client.ping).to be true
    end

    it "closes connection cleanly" do
      client.start
      expect { client.stop }.not_to raise_error
      expect(client.alive?).to be false
    end
  end

  describe "server capabilities" do
    before { client.start }

    it "reports server capabilities" do
      capabilities = client.capabilities
      expect(capabilities).to be_a(RubyLLM::MCP::ServerCapabilities)
      expect(capabilities.tools_list?).to be true
      expect(capabilities.prompt_list?).to be true
      expect(capabilities.resources_list?).to be true
    end
  end

  describe "tool operations" do
    before { client.start }

    it "lists available tools" do
      tools = client.tools
      expect(tools).to be_an(Array)
      expect(tools.length).to eq(1)
      
      tool = tools.first
      expect(tool.name).to eq("test_tool_class")
      expect(tool.description).to eq("A test tool for integration testing")
    end

    it "executes tools successfully" do
      tool = client.tool("test_tool_class")
      expect(tool).not_to be_nil

      result = tool.execute(
        name: "test_tool_class",
        parameters: { message: "integration test" }
      )

      expect(result).to be_a(RubyLLM::MCP::Result)
      expect(result.content).to be_an(Array)
      expect(result.content.first["text"]).to eq("Test response: integration test")
    end
  end

  describe "prompt operations" do
    before { client.start }

    it "lists available prompts" do
      prompts = client.prompts
      expect(prompts).to be_an(Array)
      expect(prompts.length).to eq(1)
      
      prompt = prompts.first
      expect(prompt.name).to eq("test_prompt")
      expect(prompt.description).to eq("A test prompt for integration testing")
    end

    it "executes prompts successfully" do
      prompt = client.prompt("test_prompt")
      expect(prompt).not_to be_nil

      result = prompt.call(arguments: { name: "Integration" })
      expect(result).to be_a(RubyLLM::MCP::Result)
      expect(result.description).to eq("Test prompt result")
      expect(result.messages.first.content.text).to eq("Hello Integration")
    end
  end

  describe "resource operations" do
    before { client.start }

    it "lists available resources" do
      resources = client.resources
      expect(resources).to be_an(Array)
      expect(resources.length).to eq(1)
      
      resource = resources.first
      expect(resource.name).to eq("Test Resource")
      expect(resource.description).to eq("A test resource")
    end

    it "reads resource content" do
      resource = client.resource("Test Resource")
      expect(resource).not_to be_nil

      content = resource.content
      expect(content).to eq("Test resource content")
    end
  end

  describe "error handling" do
    before { client.start }

    it "handles tool execution errors gracefully" do
      # Mock the server to raise an error
      allow(server).to receive(:handle_json).and_raise(StandardError.new("Server error"))

      expect {
        tool = client.tool("test_tool_class")
        tool&.execute(name: "test_tool_class", parameters: { message: "test" })
      }.to raise_error(RubyLLM::MCP::Errors::TransportError, /Error in in-process transport/)
    end

    it "handles requests when transport is not started" do
      expect {
        client.tools
      }.to raise_error(RubyLLM::MCP::Errors::TransportError, "Transport not started")
    end
  end

  describe "protocol compliance" do
    before { client.start }

    it "maintains JSON-RPC 2.0 compliance" do
      # Test that requests and responses follow JSON-RPC 2.0 format
      allow(server).to receive(:handle_json) do |request_json|
        request = JSON.parse(request_json)
        
        # Verify request format
        expect(request["jsonrpc"]).to eq("2.0")
        expect(request["id"]).to be_a(Integer)
        expect(request["method"]).to be_a(String)
        
        # Return compliant response
        JSON.generate({
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => {}
        })
      end

      client.ping
    end
  end
end