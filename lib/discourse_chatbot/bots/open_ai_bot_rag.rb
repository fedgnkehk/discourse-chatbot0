# frozen_string_literal: true
require "openai"

module ::DiscourseChatbot

  class OpenAiBotRag < OpenAIBotBase

    def initialize(opts)
      super
      merge_functions(opts)
    end

    def get_response(prompt, opts)
      private_discussion = opts[:private] || false

      if private_discussion
        system_message = { "role": "system", "content": I18n.t("chatbot.prompt.system.rag.private", current_date_time: DateTime.current) }
      else
        system_message = { "role": "system", "content": I18n.t("chatbot.prompt.system.rag.open", current_date_time: DateTime.current) }
      end

      prompt.unshift(system_message)

      @inner_thoughts = []

      @chat_history += prompt

      res = generate_response(opts)

      {
        reply: res["choices"][0]["message"]["content"],
        inner_thoughts: @inner_thoughts.to_s
      }
    end

    def merge_functions(opts)
      calculator_function = ::DiscourseChatbot::CalculatorFunction.new
      wikipedia_function = ::DiscourseChatbot::WikipediaFunction.new
      news_function = ::DiscourseChatbot::NewsFunction.new
      google_search_function = ::DiscourseChatbot::GoogleSearchFunction.new
      stock_data_function = ::DiscourseChatbot::StockDataFunction.new
      escalate_to_staff_function = ::DiscourseChatbot::EscalateToStaffFunction.new
      forum_search_function = nil
      user_search_from_user_location_function = nil
      user_search_from_location_function = nil
      user_distance_from_location_function = nil
      get_coords_of_location_function = nil
      get_distance_between_locations = nil
      get_user_address = nil

      if SiteSetting.chatbot_embeddings_enabled
        forum_search_function = ::DiscourseChatbot::ForumSearchFunction.new
      end

      if SiteSetting.chatbot_support_vision == "via_function"
        vision_function = ::DiscourseChatbot::VisionFunction.new
      end

      if SiteSetting.chatbot_locations_plugin_support && defined?(Locations) == 'constant' && Locations.class == Module &&
         defined?(::Locations::UserLocation) == 'constant' && ::Locations::UserLocation.class == Class && ::Locations::UserLocation.count > 0
        user_search_from_location_function = ::DiscourseChatbot::ForumUserSearchFromLocationFunction.new
        user_search_from_user_location_function = ::DiscourseChatbot::ForumUserSearchFromUserLocationFunction.new
        get_coords_of_location_function = ::DiscourseChatbot::GetCoordsOfLocationDescriptionFunction.new
        user_distance_from_location_function = ::DiscourseChatbot::ForumUserDistanceFromLocationFunction.new
        get_distance_between_locations = ::DiscourseChatbot::GetDistanceBetweenLocationsFunction.new
        get_user_address = ::DiscourseChatbot::ForumGetUserAddressFunction.new
      end

      functions = [calculator_function, wikipedia_function]

      functions << forum_search_function if forum_search_function
      functions << vision_function if vision_function

      functions << user_search_from_location_function if user_search_from_location_function
      functions << user_search_from_user_location_function if user_search_from_user_location_function
      functions << get_coords_of_location_function if get_coords_of_location_function
      functions << user_distance_from_location_function if user_distance_from_location_function
      functions << get_distance_between_locations if get_distance_between_locations
      functions << get_user_address if get_user_address
      functions << escalate_to_staff_function if SiteSetting.chatbot_escalate_to_staff_function && opts[:private] && opts[:type] == ::DiscourseChatbot::MESSAGE
      functions << news_function if !SiteSetting.chatbot_news_api_token.blank?
      functions << google_search_function if !SiteSetting.chatbot_serp_api_key.blank?
      functions << stock_data_function if !SiteSetting.chatbot_marketstack_key.blank?

      @functions = parse_functions(functions)
      @tools = @functions.map { |func| { "type": "function", "function": func } }
      @func_mapping = create_func_mapping(functions)
      @chat_history = []
    end

    def parse_functions(functions)
      return nil if functions.nil?
      functions.map { |func| ::DiscourseChatbot::Parser.func_to_json(func) }
    end

    def create_func_mapping(functions)
      return {} if functions.nil?
      functions.each_with_object({}) { |func, mapping| mapping[func.name] = func }
    end

    def create_chat_completion(messages, use_functions = true, force_search = false)
      begin
        ::DiscourseChatbot.progress_debug_message <<~EOS
          I called the LLM to help me
          ------------------------------
          value of messages is: #{messages}
          +++++++++++++++++++++++++++++++
        EOS
        parameters = {
          model: @model_name,
          messages: messages,
          max_tokens: SiteSetting.chatbot_max_response_tokens,
          temperature: SiteSetting.chatbot_request_temperature / 100.0,
          top_p: SiteSetting.chatbot_request_top_p / 100.0,
          frequency_penalty: SiteSetting.chatbot_request_frequency_penalty / 100.0,
          presence_penalty: SiteSetting.chatbot_request_presence_penalty / 100.0
        }

        parameters.merge!(tools: @tools) if use_functions && @tools

        parameters.merge!(tool_choice: {"type": "function", "function": {"name": "local_forum_search"}}) if use_functions && @tools && force_search

        res = @client.chat(
          parameters: parameters
        )

        ::DiscourseChatbot.progress_debug_message <<~EOS
          +++++++++++++++++++++++++++++++++++++++
          The llm responded with
          #{res}
          +++++++++++++++++++++++++++++++++++++++
        EOS
        res
      rescue => e
        if e.respond_to?(:response)
          status = e.response[:status]
          message = e.response[:body]["error"]["message"]
          Rails.logger.error("Chatbot: There was a problem with Chat Completion: status: #{status}, message: #{message}")
        end
        raise e
      end
    end

    def generate_response(opts)
      iteration = 1
      ::DiscourseChatbot.progress_debug_message <<~EOS
        ===============================
        # New Query
        -------------------------------
      EOS
      loop do
        ::DiscourseChatbot.progress_debug_message <<~EOS
          # Iteration: #{iteration}
          -------------------------------
        EOS
        res = create_chat_completion(@chat_history + @inner_thoughts, true, iteration == 1 && SiteSetting.chatbot_forum_search_function_force)

        if res.dig("error")
          error_text = "ERROR when trying to perform chat completion: #{res.dig("error", "message")}"

          Rails.logger.error("Chatbot: #{error_text}")
        end

        finish_reason = res["choices"][0]["finish_reason"]

        if (['stop','length'].include?(finish_reason) || @inner_thoughts.length > 7) &&
          !(iteration == 1 && SiteSetting.chatbot_forum_search_function_force)
          return res
        elsif finish_reason == 'tool_calls' || (iteration == 1 && SiteSetting.chatbot_forum_search_function_force)
          handle_function_call(res, opts)
        else
          raise "Unexpected finish reason: #{finish_reason}"
        end
        iteration += 1
      end
    end

    def handle_function_call(res, opts)
      res_msgs = []
      functions_called = res["choices"][0]["message"]

      tools_called =  functions_called["tool_calls"]

      # Convert the semi-JSON string to Ruby objects so we can make tests pass otherwise
      # format of tools_called is generated won't match what is expected in the tests
      # even though without it the code works fine

      ruby_object_array = []

      tools_called.each do |tool_called|
        json_str = tool_called.to_json
        ruby_objects = JSON.parse(json_str, symbolize_names: true)
        ruby_object_array << ruby_objects
      end

      # end of section of code to make tests pass

      tools_thought = {
        "role": "assistant",
        "content": "",
        "tool_calls": ruby_object_array
      }

      @inner_thoughts << tools_thought

      tools_called.each do |function_called|
        func_name = function_called["function"]["name"]
        args_str = function_called["function"]["arguments"]
        tool_call_id = function_called["id"]
        result = call_function(func_name, args_str, opts)
        @inner_thoughts << { role: 'tool', tool_call_id: tool_call_id, content: result.to_s }
      end
    end

    def call_function(func_name, args_str, opts)
      ::DiscourseChatbot.progress_debug_message <<~EOS
        +++++++++++++++++++++++++++++++++++++++
        I used '#{func_name}' to help me
        args_str was '#{args_str}'
        opts was '#{opts}'
        +++++++++++++++++++++++++++++++++++++++
      EOS
      begin
        args = JSON.parse(args_str)
        func = @func_mapping[func_name]
        if ["escalate_to_staff"].include?(func_name)
          res = func.process(args, opts)
        elsif ["vision"].include?(func_name)
          res = func.process(args, opts, @client)
        else
          res = func.process(args)
        end
        res
       rescue
         I18n.t("chatbot.prompt.rag.call_function.error")
      end
    end
  end
end
