#!/usr/bin/env ruby
# frozen_string_literal: true

# Example demonstrating the in-process MCP transport
# This allows direct communication between a RubyLLM client and an MCP server
# without external processes or network communication

require "ruby_llm/mcp"

# Require the MCP server SDK
begin
  require "mcp"
rescue LoadError
  puts "Error: The 'mcp' gem is required for in-process transport."
  puts "Please install it with: gem install mcp"
  puts "Add this line to your Gemfile: gem 'mcp'"
  exit 1
end

# Create a simple MCP tool for demonstration
class ExampleTool < MCP::Tool
  description "A simple example tool that echoes back its arguments with a timestamp"
  input_schema(
    properties: {
      message: { 
        type: "string",
        description: "The message to echo back"
      },
    },
    required: ["message"]
  )

  class << self
    def call(message:, server_context:)
      timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      response_text = "Echo from in-process MCP server at #{timestamp}: #{message}"
      
      MCP::Tool::Response.new([{
        type: "text",
        text: response_text,
      }])
    end
  end
end

# Create a simple MCP resource for demonstration
class ExampleResource < MCP::Resource
  def initialize
    super(
      uri: "memory://example_data",
      name: "Example Data",
      description: "Sample data from in-process MCP server",
      mime_type: "text/plain"
    )
  end
end

# Create a simple MCP prompt for demonstration
class ExamplePrompt < MCP::Prompt
  prompt_name "greeting"
  description "A simple greeting prompt with customizable name"
  arguments [
    MCP::Prompt::Argument.new(
      name: "name",
      description: "Name to greet",
      required: true
    )
  ]

  class << self
    def template(args, server_context:)
      name = args["name"] || args[:name] || "World"
      MCP::Prompt::Result.new(
        description: "A friendly greeting",
        messages: [
          MCP::Prompt::Message.new(
            role: "user",
            content: MCP::Content::Text.new("Please greet #{name} in a friendly way.")
          )
        ]
      )
    end
  end
end

# Set up the MCP server
server = MCP::Server.new(
  name: "in_process_example_server",
  version: "1.0.0",
  instructions: "This is an example in-process MCP server demonstrating tools, resources, and prompts.",
  tools: [ExampleTool],
  prompts: [ExamplePrompt],
  resources: [ExampleResource.new],
  server_context: { example: true }
)

# Configure a custom resource read handler
server.resources_read_handler do |params|
  if params[:uri] == "memory://example_data"
    [{
      uri: params[:uri],
      mimeType: "text/plain",
      text: "This is example data from the in-process MCP server. URI: #{params[:uri]}"
    }]
  else
    []
  end
end

puts "Setting up in-process MCP transport..."

# Create the RubyLLM MCP client with in-process transport
begin
  client = RubyLLM::MCP.client(
    name: "in_process_example",
    transport_type: :in_process,
    config: {
      server: server,  # Pass the server instance directly
      request_timeout: 5000
    }
  )

  # Start the client (this also starts the server transport)
  client.start
  
  puts "✓ In-process transport established"
  puts "✓ Server capabilities: #{client.capabilities.inspect}"
  puts ""

  # Test ping functionality
  puts "Testing ping..."
  if client.ping
    puts "✓ Ping successful"
  else
    puts "✗ Ping failed"
  end
  puts ""

  # List and test tools
  puts "Available tools:"
  tools = client.tools
  tools.each do |tool|
    puts "- #{tool.name}: #{tool.description}"
  end
  puts ""

  if tools.any?
    puts "Testing tool execution..."
    tool = client.tool("example_tool")
    if tool
      result = tool.execute(
        message: "Hello from in-process transport!"
      )
      puts "✓ Tool result: #{result}"
    else
      puts "✗ Tool 'example_tool' not found"
      puts "Available tools: #{tools.map(&:name)}"
    end
  end
  puts ""

  # List and test resources
  puts "Available resources:"
  resources = client.resources
  resources.each do |resource|
    puts "- #{resource.name}: #{resource.description}"
  end
  puts ""

  if resources.any?
    puts "Testing resource access..."
    resource = client.resource("Example Data")
    if resource
      content = resource.content
      puts "✓ Resource content: #{content}"
    end
  end
  puts ""

  # List and test prompts
  puts "Available prompts:"
  prompts = client.prompts
  prompts.each do |prompt|
    puts "- #{prompt.name}: #{prompt.description}"
    prompt.arguments.each do |arg|
      puts "  - #{arg.name}: #{arg.description} (required: #{arg.required})"
    end
  end
  puts ""

  if prompts.any?
    puts "Testing prompt execution..."
    prompt = client.prompt("greeting")
    if prompt
      result = prompt.fetch({ name: "In-Process User" })
      puts "✓ Prompt result: #{result.length} messages"
      result.each do |message|
        puts "  #{message.role}: #{message.content}"
      end
    end
  end
  puts ""

  puts "✓ All in-process MCP operations completed successfully!"

rescue => e
  puts "✗ Error: #{e.message}"
  puts e.backtrace.first(5)
ensure
  # Clean up
  client&.stop
  puts "Cleaned up in-process transport"
end
