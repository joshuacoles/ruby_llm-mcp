# frozen_string_literal: true

require "json"
require "securerandom"

module RubyLLM
  module MCP
    module Transports
      class InProcess
        include Support::Timeout

        attr_reader :server, :coordinator, :request_timeout

        def initialize(server:, coordinator:, request_timeout:)
          @server = server
          @coordinator = coordinator
          @request_timeout = request_timeout
          
          @client_id = SecureRandom.uuid
          @id_counter = 0
          @id_mutex = Mutex.new
          @running = false
          @protocol_version = nil
          
          # Set up bidirectional communication
          setup_server_transport
          
          RubyLLM::MCP.logger.debug "Initialized InProcess transport with client ID #{@client_id}"
        end

        def request(body, add_id: true, wait_for_response: true)
          raise Errors::TransportError.new(message: "Transport not started") unless @running

          if add_id
            @id_mutex.synchronize { @id_counter += 1 }
            request_id = @id_counter
            body["id"] = request_id
          end

          begin
            # Convert the request body to JSON and back to simulate serialization
            json_request = JSON.generate(body)
            RubyLLM::MCP.logger.debug "Sending in-process request: #{json_request}"

            # Handle the request directly through the server
            response_json = @server.handle_json(json_request)
            
            return unless wait_for_response && response_json

            # Parse the response
            response = JSON.parse(response_json)
            result = RubyLLM::MCP::Result.new(response)
            
            RubyLLM::MCP.logger.debug "Received in-process response: #{response_json}"
            
            # Process the result through the coordinator
            processed_result = @coordinator.process_result(result)
            return processed_result || result
            
          rescue JSON::ParserError => e
            error_message = "JSON parsing error in in-process transport: #{e.message}"
            RubyLLM::MCP.logger.error error_message
            raise Errors::TransportError.new(message: error_message, error: e)
          rescue StandardError => e
            error_message = "Error in in-process transport request: #{e.message}"
            RubyLLM::MCP.logger.error "#{error_message}: #{e.backtrace.first}"
            raise Errors::TransportError.new(message: error_message, error: e)
          end
        end

        def alive?
          @running
        end

        def start
          return if @running
          
          @running = true
          RubyLLM::MCP.logger.debug "Started in-process transport"
        end

        def close
          @running = false
          @server_transport&.close if @server_transport&.respond_to?(:close)
          RubyLLM::MCP.logger.debug "Closed in-process transport"
        end

        def set_protocol_version(version)
          @protocol_version = version
          RubyLLM::MCP.logger.debug "Set protocol version to #{version}"
        end

        # Receive notifications from the server transport
        def receive_notification(method, params = nil)
          return unless @running

          notification = {
            "jsonrpc" => "2.0",
            "method" => method
          }
          notification["params"] = params if params

          result = RubyLLM::MCP::Result.new(notification)
          @coordinator.process_result(result)
        rescue StandardError => e
          error_message = "Error processing notification in in-process transport: #{e.message}"
          RubyLLM::MCP.logger.error "#{error_message}: #{e.backtrace.first}"
        end

        private

        def setup_server_transport
          # Import the InProcessTransport from the MCP server SDK
          require "mcp/server/transports/in_process_transport"
          
          @server_transport = ::MCP::Server::Transports::InProcessTransport.new(@server, self)
          @server.transport = @server_transport
        rescue LoadError => e
          raise Errors::TransportError.new(
            message: "Could not load MCP server in-process transport. Ensure the 'mcp' gem is installed and available.",
            error: e
          )
        end
      end
    end
  end
end